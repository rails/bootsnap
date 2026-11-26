# frozen_string_literal: true

module Bootsnap
  module CompileCache
    UNCOMPILABLE = BasicObject.new
    def UNCOMPILABLE.inspect
      "<Bootsnap::UNCOMPILABLE>"
    end

    Error = Class.new(StandardError)

    def self.setup(cache_dir:, iseq:, yaml:, json: (json_unset = true), readonly: false, revalidation: false)
      unless json_unset
        warn("Bootsnap::CompileCache.setup `json` argument is deprecated and has no effect")
      end

      if iseq
        if supported?
          Bootsnap::CompileCache::ISeq.install!(cache_dir)
        elsif $VERBOSE
          warn("[bootsnap/setup] bytecode caching is not supported on this implementation of Ruby")
        end
      end

      if yaml
        if supported?
          require_relative "compile_cache/yaml"
          Bootsnap::CompileCache::YAML.install!(cache_dir)
        elsif $VERBOSE
          warn("[bootsnap/setup] YAML parsing caching is not supported on this implementation of Ruby")
        end
      end

      if supported? && defined?(Bootsnap::CompileCache::Native)
        Bootsnap::CompileCache::Native.readonly = readonly
        Bootsnap::CompileCache::Native.revalidation = revalidation
      end
    end

    def self.supported?
      # only enable on 'ruby' (MRI) and TruffleRuby for POSIX (darwin, linux, *bsd), Windows (RubyInstaller2)
      %w[ruby truffleruby].include?(RUBY_ENGINE) &&
        RUBY_PLATFORM.match?(/darwin|linux|bsd|mswin|mingw|cygwin/)
    end

    RUBY_LIBDIR  = -RbConfig::CONFIG["rubylibdir"]
    BUNDLER_PATH = Bootsnap.bundler? && -Bundler.bundle_path.to_s
    APP_ROOT = -Dir.pwd
    other_paths = [*Gem.path, -RbConfig::CONFIG["sitedir"]] - [RUBY_LIBDIR, BUNDLER_PATH, APP_ROOT]

    OTHER_PATHS = other_paths.empty? ? nil : other_paths.freeze

    def self.normalize(abspath)
      # TODO: Can we even support `Dir.chdir`?
      if abspath.start_with?(BUNDLER_PATH)
        return "{BUNDLE}#{abspath.byteslice(BUNDLER_PATH.bytesize, abspath.bytesize)}"
      end

      OTHER_PATHS&.each do |path|
        if abspath.start_with?(path)
          return abspath.sub(path, "{OTHER}")
        end
      end

      if abspath.start_with?(APP_ROOT)
        return "{APP}#{abspath.byteslice(APP_ROOT.bytesize, abspath.bytesize)}"
      end

      abspath
    end
  end
end

if RUBY_ENGINE != "jruby"
  require_relative "compile_cache/iseq"
  Bootsnap::CompileCache::ISeq.install!(nil)
end
