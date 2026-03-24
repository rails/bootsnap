# frozen_string_literal: true

require "bootsnap/bootsnap"
require "msgpack"
require "digest/md5"
require "fileutils"

module Bootsnap
  module CompileCache
    module ISeqBundle
      BUNDLE_DIR = "iseq-bundles"

      class << self
        def install!(cache_dir, skip_validation: false, auto_build: true)
          # Disable entirely via env var (useful for tests/debugging)
          if ENV["BOOTSNAP_NO_BUNDLE"]
            @enabled = false
            return
          end

          # cache_dir is "…/bootsnap/compile-cache". Bundles live alongside
          # compile-cache-iseq in the parent dir: …/bootsnap/iseq-bundles/
          parent_dir = File.dirname(cache_dir)
          @bundles_dir = File.join(parent_dir, BUNDLE_DIR)
          @skip_validation = skip_validation
          @auto_build = auto_build
          @loaded_bundles = {} # load_path_entry => GemBundle or :miss
          @path_to_bundle = {} # resolved absolute path => GemBundle (populated lazily)
          @enabled = true
        end

        def fetch(path)
          return nil unless @enabled

          bundle = @path_to_bundle[path]

          if bundle
            return bundle.fetch_entry(path, @skip_validation)
          end

          # We haven't seen this path yet. Find which load path entry owns it,
          # then check/load/build the bundle for that entry.
          load_path_entry = find_load_path_entry(path)
          return nil unless load_path_entry

          bundle = load_or_build_bundle(load_path_entry)
          return nil unless bundle

          # Register this path for future fast lookup
          @path_to_bundle[path] = bundle
          bundle.fetch_entry(path, @skip_validation)
        end

        def loaded?
          @enabled
        end

        # Build bundles for specific load path entries. Used by CLI.
        def build_for_paths!(cache_dir, load_path_entries)
          parent_dir = File.dirname(cache_dir)
          bundles_dir = File.join(parent_dir, BUNDLE_DIR)

          built = 0
          load_path_entries.each do |entry|
            begin
              entry = File.realpath(entry)
            rescue StandardError
              next
            end
            next unless File.directory?(entry)

            source_files = Dir.glob(File.join(entry, "**/*.rb"))
            next if source_files.empty?

            bundle = GemBundle.build(bundles_dir, entry, source_files)
            built += 1 if bundle
          end
          built
        end

        private

        def find_load_path_entry(absolute_path)
          # The load path cache's @index maps feature → directory.
          # We can derive the load path entry from the absolute path by checking
          # which $LOAD_PATH entry is a prefix.
          $LOAD_PATH.each do |lp|
            lp_real = lp.to_s
            if absolute_path.start_with?(lp_real) &&
               absolute_path.getbyte(lp_real.bytesize) == 47 # "/"
              return lp_real
            end
          end
          nil
        end

        def load_or_build_bundle(load_path_entry)
          cached = @loaded_bundles[load_path_entry]
          return cached if cached.is_a?(GemBundle)
          return nil if cached == :miss

          bundle = GemBundle.load(@bundles_dir, load_path_entry)

          if !bundle && @auto_build
            # Auto-build on first encounter. This makes the precompile step
            # optional — bundles are created lazily on first boot.
            source_files = Dir.glob(File.join(load_path_entry, "**/*.rb"))
            unless source_files.empty?
              bundle = GemBundle.build(@bundles_dir, load_path_entry, source_files)
            end
          end

          if bundle
            @loaded_bundles[load_path_entry] = bundle
            # Pre-register all paths in this bundle for direct lookup
            bundle.each_path { |p| @path_to_bundle[p] = bundle }
            bundle
          else
            @loaded_bundles[load_path_entry] = :miss
            nil
          end
        end
      end

      # Represents a single gem's compiled ISeq bundle.
      class GemBundle
        attr_reader :load_path_entry

        def initialize(load_path_entry, index, data)
          @load_path_entry = load_path_entry
          @index = index # { absolute_path => { "o" => offset, "s" => size, "sz" => src_size, "mt" => src_mtime } }
          @data = data   # binary blob of concatenated ISeq binaries
        end

        def fetch_entry(path, skip_validation)
          entry = @index[path]
          return nil unless entry

          unless skip_validation
            begin
              stat = File.stat(path)
            rescue Errno::ENOENT
              return nil
            end
            return nil if stat.size != entry["sz"]
            return nil if stat.mtime.to_i != entry["mt"]
          end

          binary = @data.byteslice(entry["o"], entry["s"])
          return nil unless binary && binary.bytesize == entry["s"]

          RubyVM::InstructionSequence.load_from_binary(binary)
        rescue RuntimeError
          nil # broken binary
        end

        def each_path(&block)
          @index.each_key(&block)
        end

        # Load an existing bundle for a load path entry.
        def self.load(bundles_dir, load_path_entry)
          path = bundle_path(bundles_dir, load_path_entry)
          return nil unless File.exist?(path)

          File.open(path, "rb") do |f|
            header_size_raw = f.read(4)
            return nil unless header_size_raw && header_size_raw.bytesize == 4

            header_size = header_size_raw.unpack1("N")
            return nil if header_size > 50_000_000 # 50MB sanity check

            header_bytes = f.read(header_size)
            return nil unless header_bytes && header_bytes.bytesize == header_size

            header = MessagePack.unpack(header_bytes)
            return nil unless header.is_a?(Hash)
            return nil unless header["version"] == bundle_version
            return nil unless header["load_path"] == load_path_entry

            data_size = header["data_size"]
            return nil unless data_size
            return nil if data_size > 500_000_000 # 500MB sanity limit

            data = f.read(data_size)
            return nil unless data && data.bytesize == data_size

            new(load_path_entry, header["index"], data)
          end
        rescue Errno::ENOENT, MessagePack::MalformedFormatError, EOFError
          nil
        end

        # Build a bundle for a load path entry from its source files.
        def self.build(bundles_dir, load_path_entry, source_files)
          index = {}
          data_parts = []
          current_offset = 0

          source_files.each do |source_path|
            binary = begin
              RubyVM::InstructionSequence.compile_file(source_path).to_binary
            rescue SyntaxError, TypeError
              next
            end
            next unless binary

            stat = File.stat(source_path)

            index[source_path] = {
              "o" => current_offset,
              "s" => binary.bytesize,
              "sz" => stat.size,
              "mt" => stat.mtime.to_i,
            }

            data_parts << binary
            current_offset += binary.bytesize
          rescue Errno::ENOENT
            next
          end

          return nil if index.empty?

          blob = data_parts.join
          header = {
            "version" => bundle_version,
            "load_path" => load_path_entry,
            "index" => index,
            "data_size" => blob.bytesize,
            "entry_count" => index.size,
          }

          header_bytes = MessagePack.pack(header)
          header_size = [header_bytes.bytesize].pack("N")

          path = bundle_path(bundles_dir, load_path_entry)
          FileUtils.mkdir_p(File.dirname(path))

          tmp = "#{path}.#{Process.pid}.#{rand(100_000)}.tmp"
          File.open(tmp, "wb") do |f|
            f.write(header_size)
            f.write(header_bytes)
            f.write(blob)
          end
          File.rename(tmp, path)

          new(load_path_entry, index, blob)
        rescue Errno::EEXIST
          retry
        rescue SystemCallError
          nil
        end

        def self.bundle_path(bundles_dir, load_path_entry)
          # Use MD5 of load path entry as filename. The load path includes
          # gem name + version, so upgrading a gem = different hash = new bundle.
          hash = Digest::MD5.hexdigest(load_path_entry)
          File.join(bundles_dir, hash[0..1], hash[2..])
        end

        def self.bundle_version
          "#{Bootsnap::VERSION}-#{RUBY_REVISION}-#{RUBY_PLATFORM}"
        end
      end
    end
  end
end
