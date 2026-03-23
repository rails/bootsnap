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
          require_relative "compile_cache/iseq"
          Bootsnap::CompileCache::ISeq.install!(cache_dir)

          # Per-gem ISeq bundles: each $LOAD_PATH entry gets its own bundle file.
          # Bundles are auto-built on first boot if missing, or pre-built via
          # `bootsnap precompile --bundle`. Gem path includes version, so
          # upgrading a gem naturally invalidates only that gem's bundle.
          require_relative "compile_cache/iseq_bundle"
          Bootsnap::CompileCache::ISeqBundle.install!(cache_dir, skip_validation: readonly)
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
  end
end
