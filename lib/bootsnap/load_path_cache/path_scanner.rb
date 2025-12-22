# frozen_string_literal: true

require_relative "../explicit_require"

module Bootsnap
  module LoadPathCache
    module PathScanner
      REQUIRABLE_EXTENSIONS = [DOT_RB] + DL_EXTENSIONS

      BUNDLE_PATH = if Bootsnap.bundler?
        (Bundler.bundle_path.cleanpath.to_s << LoadPathCache::SLASH).freeze
      else
        ""
      end

      @ignored_directories = %w(node_modules)

      class << self
        attr_accessor :ignored_directories

        def ruby_call(path)
          path = File.expand_path(path.to_s).freeze
          return [] unless File.directory?(path)

          # If the bundle path is a descendent of this path, we do additional
          # checks to prevent recursing into the bundle path as we recurse
          # through this path. We don't want to scan the bundle path because
          # anything useful in it will be present on other load path items.
          #
          # This can happen if, for example, the user adds '.' to the load path,
          # and the bundle path is '.bundle'.
          contains_bundle_path = BUNDLE_PATH.start_with?(path)

          requirables = []
          walk(path, nil) do |relative_path, absolute_path, is_directory|
            if is_directory
              !contains_bundle_path || !absolute_path.start_with?(BUNDLE_PATH)
            elsif relative_path.end_with?(*REQUIRABLE_EXTENSIONS)
              requirables << relative_path.freeze
            end
          end
          requirables
        end

        def walk(absolute_dir_path, relative_dir_path, &block)
          Dir.foreach(absolute_dir_path) do |name|
            next if name.start_with?(".")

            relative_path = relative_dir_path ? File.join(relative_dir_path, name) : name

            absolute_path = "#{absolute_dir_path}/#{name}"
            if File.directory?(absolute_path)
              next if ignored_directories.include?(name) || ignored_directories.include?(absolute_path)

              if yield relative_path, absolute_path, true
                walk(absolute_path, relative_path, &block)
              end
            else
              yield relative_path, absolute_path, false
            end
          end
        end

        if RUBY_ENGINE == "ruby" && RUBY_PLATFORM.match?(/darwin|linux|bsd|mswin|mingw|cygwin/)
          require "bootsnap/bootsnap"
        end

        if defined?(Native.scan_dir)
          def native_call(root_path)
            # NOTE: if https://bugs.ruby-lang.org/issues/21800 is accepted we should be able
            # to have similar performance with pure Ruby

            # If the bundle path is a descendent of this path, we do additional
            # checks to prevent recursing into the bundle path as we recurse
            # through this path. We don't want to scan the bundle path because
            # anything useful in it will be present on other load path items.
            #
            # This can happen if, for example, the user adds '.' to the load path,
            # and the bundle path is '.bundle'.
            contains_bundle_path = BUNDLE_PATH.start_with?(root_path)

            all_requirables, queue = Native.scan_dir(root_path)
            all_requirables.each(&:freeze)

            queue.reject! do |dir|
              ignored_directories.include?(dir) ||
                (contains_bundle_path && dir.start_with?(BUNDLE_PATH))
            end

            while (path = queue.pop)
              requirables, dirs = Native.scan_dir(File.join(root_path, path))
              dirs.reject! { |dir| ignored_directories.include?(dir) }
              dirs.map! { |f| File.join(path, f).freeze }
              requirables.map! { |f| File.join(path, f).freeze }

              if contains_bundle_path
                dirs.reject! { |dir| dir.start_with?(BUNDLE_PATH) }
              end

              all_requirables.concat(requirables)
              queue.concat(dirs)
            end

            all_requirables
          end
          alias_method :call, :native_call
        else
          alias_method :call, :ruby_call
        end
      end
    end
  end
end
