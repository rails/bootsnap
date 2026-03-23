# frozen_string_literal: true

require "bootsnap/bootsnap"
require "msgpack"
require "digest/md5"

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

        def fetch(path)
          return nil unless @index

          entry = @index[path]
          return nil unless entry

          offset = entry["o"]
          size = entry["s"]

          # Skip per-file stat when either:
          # 1. Explicitly told to (readonly/production mode), OR
          # 2. The Gemfile.lock fingerprint matches (gems haven't changed)
          unless @skip_validation
            source_size = entry["sz"]
            source_mtime = entry["mt"]
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

          RubyVM::InstructionSequence.load_from_binary(binary)
        rescue RuntimeError
          nil # broken binary format
        end

        def loaded?
          !!@index
        end

        # Build the bundle from source files by compiling each to ISeq binary.
        # Run as a precompile step: `bootsnap precompile --bundle` or from Ruby.
        def build!(cache_dir, source_paths: nil)
          parent_dir = File.dirname(cache_dir)
          bundle_path = File.join(parent_dir, BUNDLE_FILENAME)

          raise ArgumentError, "source_paths must be provided for build!" unless source_paths

          index = {}
          data_parts = []
          current_offset = 0

          source_paths.each do |source_path|
            binary = compile_to_binary(source_path)
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
          rescue Errno::ENOENT, SyntaxError, TypeError
            next
          end

          blob = data_parts.join

          header = {
            "version" => bundle_version,
            "gemfile_lock_fingerprint" => gemfile_lock_fingerprint,
            "index" => index,
            "data_size" => blob.bytesize,
            "entry_count" => index.size,
          }

          header_bytes = MessagePack.pack(header)
          header_size = [header_bytes.bytesize].pack("N") # 4-byte length prefix

          tmp = "#{bundle_path}.#{Process.pid}.tmp"
          File.open(tmp, "wb") do |f|
            f.write(header_size)
            f.write(header_bytes)
            f.write(blob)
          end
          File.rename(tmp, bundle_path)

          { entries: index.size, data_size: blob.bytesize, path: bundle_path }
        rescue Errno::EEXIST
          retry
        rescue SystemCallError
          { entries: 0, data_size: 0, path: bundle_path }
        end

        private

        def bundle_version
          "#{Bootsnap::VERSION}-#{RUBY_REVISION}-#{RUBY_PLATFORM}"
        end

        def gemfile_lock_fingerprint
          lockfile = ENV["BUNDLE_GEMFILE"] ? "#{ENV['BUNDLE_GEMFILE']}.lock" : "Gemfile.lock"
          if File.exist?(lockfile)
            Digest::MD5.hexdigest(File.read(lockfile))
          end
        end

        def load_bundle
          File.open(@bundle_path, "rb") do |f|
            header_size_raw = f.read(4)
            return unless header_size_raw && header_size_raw.bytesize == 4

            header_size = header_size_raw.unpack1("N")
            return if header_size > 100_000_000 # sanity: 100MB max header

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

            # If the Gemfile.lock matches what was bundled, skip per-file
            # validation automatically. Gems don't change without a bundle
            # install, so the lock fingerprint proves freshness.
            stored_fingerprint = header["gemfile_lock_fingerprint"]
            if stored_fingerprint && stored_fingerprint == gemfile_lock_fingerprint
              @skip_validation = true
            end
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
      end
    end
  end
end
