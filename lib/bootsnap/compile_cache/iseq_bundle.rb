# frozen_string_literal: true

require "bootsnap/bootsnap"
require "msgpack"

module Bootsnap
  module CompileCache
    module ISeqBundle
      BUNDLE_FILENAME = "compile-cache-iseq-bundle"

      class << self
        attr_reader :bundle_path

        def install!(cache_dir, skip_validation: false)
          # cache_dir is "…/bootsnap/compile-cache". The bundle sits alongside
          # compile-cache-iseq in the parent dir (…/bootsnap/).
          parent_dir = File.dirname(cache_dir)
          @bundle_path = File.join(parent_dir, BUNDLE_FILENAME)
          @index = nil
          @data = nil
          @skip_validation = skip_validation

          return unless File.exist?(@bundle_path)

          load_bundle
        end

        def hit?(path)
          @index && @index.key?(path)
        end

        def fetch(path)
          return nil unless @index

          entry = @index[path]
          return nil unless entry

          offset = entry["o"]
          size = entry["s"]
          source_size = entry["sz"]
          source_mtime = entry["mt"]

          # Quick validation: check source file still matches what we bundled.
          # Use stat (1 syscall) instead of open+read (2+ syscalls).
          # In production/Docker, skip_validation can bypass this entirely.
          unless @skip_validation
            begin
              stat = File.stat(path)
            rescue Errno::ENOENT
              return nil
            end

            return nil if stat.size != source_size
            return nil if stat.mtime.to_i != source_mtime
          end

          binary = @data.byteslice(offset, size)
          return nil unless binary && binary.bytesize == size

          begin
            iseq = RubyVM::InstructionSequence.load_from_binary(binary)
            return iseq
          rescue RuntimeError
            # broken binary
            return nil
          end
        end

        def loaded?
          !!@index
        end

        # Build the bundle from existing individual cache files + source files.
        # This is meant to be run as a precompile step (e.g., in CI/CD or after deploy).
        def build!(cache_dir, source_paths: nil)
          iseq_cache_dir = cache_dir.end_with?("/") ? "#{cache_dir}iseq" : "#{cache_dir}-iseq"
          parent_dir = File.dirname(cache_dir)
          bundle_path = File.join(parent_dir, BUNDLE_FILENAME)

          # If no specific paths given, find all source files that have cache entries
          unless source_paths
            source_paths = collect_cached_paths(iseq_cache_dir)
          end

          index = {}
          data_parts = []
          current_offset = 0

          source_paths.each do |source_path|
            # Use the existing compile cache to get the ISeq binary
            begin
              binary = compile_to_binary(source_path)
            rescue => e
              # Skip files that can't be compiled
              next
            end
            next unless binary

            begin
              stat = File.stat(source_path)
            rescue Errno::ENOENT
              next
            end

            index[source_path] = {
              "o" => current_offset,
              "s" => binary.bytesize,
              "sz" => stat.size,
              "mt" => stat.mtime.to_i,
            }

            data_parts << binary
            current_offset += binary.bytesize
          end

          # Write bundle: MessagePack header with index, then raw ISeq data blob
          blob = data_parts.join
          header = {
            "version" => bundle_version,
            "index" => index,
            "data_offset" => 0, # data starts right after header in the blob section
            "data_size" => blob.bytesize,
            "entry_count" => index.size,
          }

          header_bytes = MessagePack.pack(header)
          header_size = [header_bytes.bytesize].pack("N") # 4-byte big-endian length prefix

          tmp = "#{bundle_path}.#{Process.pid}.tmp"
          File.open(tmp, "wb") do |f|
            f.write(header_size)
            f.write(header_bytes)
            f.write(blob)
          end
          File.rename(tmp, bundle_path)

          { entries: index.size, data_size: blob.bytesize, path: bundle_path }
        end

        private

        def bundle_version
          "#{Bootsnap::VERSION}-#{RUBY_REVISION}-#{RUBY_PLATFORM}"
        end

        def load_bundle
          File.open(@bundle_path, "rb") do |f|
            # Read 4-byte header size
            header_size_raw = f.read(4)
            return unless header_size_raw && header_size_raw.bytesize == 4

            header_size = header_size_raw.unpack1("N")
            return if header_size > 100_000_000 # sanity check: 100MB max header

            header_bytes = f.read(header_size)
            return unless header_bytes && header_bytes.bytesize == header_size

            header = MessagePack.unpack(header_bytes)
            return unless header.is_a?(Hash)
            return unless header["version"] == bundle_version

            @index = header["index"]
            data_size = header["data_size"]
            return unless data_size

            @data = f.read(data_size)
            return unless @data && @data.bytesize == data_size
          end
        rescue Errno::ENOENT, MessagePack::MalformedFormatError, EOFError
          @index = nil
          @data = nil
        end

        def compile_to_binary(source_path)
          RubyVM::InstructionSequence.compile_file(source_path).to_binary
        rescue SyntaxError, TypeError
          nil
        end

        # Walk the cache dir to find source paths from cache filenames.
        # Cache files are stored as FNV hash of the source path, so we can't
        # reverse them. Instead, read each cache file's header to reconstruct.
        # This is slow but only runs at bundle-build time.
        def collect_cached_paths(iseq_cache_dir)
          # Alternative: just use $LOADED_FEATURES from a previous boot
          # For now, we require source_paths to be passed explicitly
          raise ArgumentError, "source_paths must be provided for build!"
        end
      end
    end
  end
end
