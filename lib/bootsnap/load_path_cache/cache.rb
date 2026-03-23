# frozen_string_literal: true

require_relative "../explicit_require"
require "digest/md5"

module Bootsnap
  module LoadPathCache
    class Cache
      AGE_THRESHOLD = 30 # seconds

      def initialize(store, path_obj, development_mode: false)
        @development_mode = development_mode
        @store = store
        @mutex = Mutex.new
        @has_relative_paths = nil
        @index_dirty = false

        # Fast path: check if we have a pre-built index matching the current
        # raw $LOAD_PATH BEFORE doing expensive File.realpath calls.
        raw_fingerprint = self.class.load_path_fingerprint(path_obj)
        cached = store.load_index(raw_fingerprint)

        if cached && cached["resolved_paths"]
          # Index hit — restore resolved paths and index without any syscalls
          resolved = cached["resolved_paths"]
          path_obj.map!.with_index { |f, i| resolved[i] || f.to_s.freeze }
          @path_obj = path_obj
          @index = cached["index"].dup
          @generated_at = now
          @path_obj.each { |p| @has_relative_paths = true unless p.start_with?(SLASH) }
          ChangeObserver.register(@path_obj, self)
        else
          # Cache miss — resolve realpaths (expensive) and build index
          @path_obj = path_obj.map! do |f|
            if File.exist?(f)
              File.realpath(f).freeze
            elsif f.frozen?
              f
            else
              f.dup.freeze
            end
          end
          reinitialize(save_fingerprint: raw_fingerprint)
        end
      end

      def self.load_path_fingerprint(path_obj)
        # Digest of the ordered load path entries. In production mode this is
        # sufficient — gem paths don't change without a deploy/bundle install.
        # For development mode, volatile paths get mtime-checked separately via
        # the existing stale?/AGE_THRESHOLD mechanism.
        Digest::MD5.hexdigest(path_obj.join("\0")).freeze
      end

      TRUFFLERUBY_LIB_DIR_PREFIX = if RUBY_ENGINE == "truffleruby"
        "#{File.join(RbConfig::CONFIG['libdir'], 'truffle')}#{File::SEPARATOR}"
      end

      # { 'enumerator' => nil, 'enumerator.so' => nil, ... }
      BUILTIN_FEATURES = $LOADED_FEATURES.each_with_object({}) do |feat, features|
        if TRUFFLERUBY_LIB_DIR_PREFIX && feat.start_with?(TRUFFLERUBY_LIB_DIR_PREFIX)
          feat = feat.byteslice(TRUFFLERUBY_LIB_DIR_PREFIX.bytesize..-1)
        end

        # Builtin features are of the form 'enumerator.so'.
        # All others include paths.
        next unless feat.size < 20 && !feat.include?("/")

        base = File.basename(feat, ".*") # enumerator.so -> enumerator
        ext  = File.extname(feat) # .so

        features[feat] = nil # enumerator.so
        features[base] = nil # enumerator

        next unless [DOT_SO, *DL_EXTENSIONS].include?(ext)

        DL_EXTENSIONS.each do |dl_ext|
          features["#{base}#{dl_ext}"] = nil # enumerator.bundle
        end
      end.freeze

      # Try to resolve this feature to an absolute path without traversing the
      # loadpath.
      def find(feature)
        reinitialize if (@has_relative_paths && dir_changed?) || stale?
        if @index_dirty
          @index_dirty = false
          save_index_locked
        end
        feature = feature.to_s.freeze

        return feature if Bootsnap.absolute_path?(feature)

        if feature.start_with?("./", "../")
          return expand_path(feature)
        end

        @mutex.synchronize do
          x = search_index(feature)
          return x if x

          # Ruby has some built-in features that require lies about.
          # For example, 'enumerator' is built in. If you require it, ruby
          # returns false as if it were already loaded; however, there is no
          # file to find on disk. We've pre-built a list of these, and we
          # return false if any of them is loaded.
          return false if BUILTIN_FEATURES.key?(feature)

          # The feature wasn't found on our preliminary search through the index.
          # We resolve this differently depending on what the extension was.
          case File.extname(feature)
          # If the extension was one of the ones we explicitly cache (.rb and the
          # native dynamic extension, e.g. .bundle or .so), we know it was a
          # failure and there's nothing more we can do to find the file.
          # no extension, .rb, (.bundle or .so)
          when "", *CACHED_EXTENSIONS
            nil
          # Ruby allows specifying native extensions as '.so' even when DLEXT
          # is '.bundle'. This is where we handle that case.
          when DOT_SO
            x = search_index(feature[0..-4] + DLEXT)
            return x if x

            if DLEXT2
              x = search_index(feature[0..-4] + DLEXT2)
              return x if x
            end
          else
            # other, unknown extension. For example, `.rake`. Since we haven't
            # cached these, we legitimately need to run the load path search.
            return FALLBACK_SCAN
          end
        end

        # In development mode, we don't want to confidently return failures for
        # cases where the file doesn't appear to be on the load path. We should
        # be able to detect newly-created files without rebooting the
        # application.
        return FALLBACK_SCAN if @development_mode
      end

      def unshift_paths(sender, *paths)
        return unless sender == @path_obj

        @mutex.synchronize do
          unshift_paths_locked(*paths)
          @index_dirty = true
        end
      end

      def push_paths(sender, *paths)
        return unless sender == @path_obj

        @mutex.synchronize do
          push_paths_locked(*paths)
          @index_dirty = true
        end
      end

      def reinitialize(path_obj = @path_obj, save_fingerprint: nil)
        @mutex.synchronize do
          @path_obj = path_obj
          ChangeObserver.register(@path_obj, self)
          @index = {}
          @generated_at = now
          push_paths_locked(*@path_obj)

          # Save the pre-built index for fast loading on next boot.
          # Includes resolved paths so we can skip File.realpath too.
          if save_fingerprint
            @store.save_index(save_fingerprint, {
              "index" => @index,
              "resolved_paths" => @path_obj.to_a,
            })
          end
        end
      end

      private

      def save_index_locked
        fingerprint = self.class.load_path_fingerprint(@path_obj)
        @store.save_index(fingerprint, {
          "index" => @index,
          "resolved_paths" => @path_obj.to_a,
        })
      end

      def dir_changed?
        @prev_dir ||= Dir.pwd
        if @prev_dir == Dir.pwd
          false
        else
          @prev_dir = Dir.pwd
          true
        end
      end

      def push_paths_locked(*paths)
        @store.transaction do
          paths.map(&:to_s).each do |path|
            p = Path.new(path)
            @has_relative_paths = true if p.relative?
            next if p.non_directory?

            p = p.to_realpath

            expanded_path = p.expanded_path
            entries = p.entries(@store)
            # push -> low precedence -> set only if unset
            entries.each { |rel| @index[rel] ||= expanded_path }
          end
        end
      end

      def unshift_paths_locked(*paths)
        @store.transaction do
          paths.map(&:to_s).reverse_each do |path|
            p = Path.new(path)
            next if p.non_directory?

            p = p.to_realpath

            expanded_path = p.expanded_path
            entries = p.entries(@store)
            # unshift -> high precedence -> unconditional set
            entries.each { |rel| @index[rel] = expanded_path }
          end
        end
      end

      def expand_path(feature)
        maybe_append_extension(File.expand_path(feature))
      end

      def stale?
        @development_mode && @generated_at + AGE_THRESHOLD < now
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i
      end

      if DLEXT2
        def search_index(feature)
          try_index(feature + DOT_RB) ||
            try_index(feature + DLEXT) ||
            try_index(feature + DLEXT2) ||
            try_index(feature)
        end

        def maybe_append_extension(feature)
          try_ext(feature + DOT_RB) ||
            try_ext(feature + DLEXT) ||
            try_ext(feature + DLEXT2) ||
            feature
        end
      else
        def search_index(feature)
          try_index(feature + DOT_RB) || try_index(feature + DLEXT) || try_index(feature)
        end

        def maybe_append_extension(feature)
          try_ext(feature + DOT_RB) || try_ext(feature + DLEXT) || feature
        end
      end

      s = rand.to_s.force_encoding(Encoding::US_ASCII).freeze
      if s.respond_to?(:-@)
        if ((-s).equal?(s) && (-s.dup).equal?(s)) || RUBY_VERSION >= "2.7"
          def try_index(feature)
            if (path = @index[feature])
              -File.join(path, feature).freeze
            end
          end
        else
          def try_index(feature)
            if (path = @index[feature])
              -File.join(path, feature).untaint
            end
          end
        end
      else
        def try_index(feature)
          if (path = @index[feature])
            File.join(path, feature)
          end
        end
      end

      def try_ext(feature)
        feature if File.exist?(feature)
      end
    end
  end
end
