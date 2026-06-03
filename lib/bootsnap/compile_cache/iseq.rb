# frozen_string_literal: true

require "bootsnap/bootsnap"
require "zlib"

module Bootsnap
  module CompileCache
    module ISeq
      class << self
        attr_reader :cache_dir
        attr_accessor :compiler_selector, :default_compiler

        def cache_dir=(cache_dir)
          @cache_dir = cache_dir.end_with?("/") ? "#{cache_dir}iseq" : "#{cache_dir}-iseq"
        end

        def supported?
          CompileCache.supported? && defined?(RubyVM)
        end
      end

      if supported?
        class Compiler
          attr_reader :namespace

          def initialize(namespace = nil, compile_options = nil)
            @namespace = namespace
            @options = compile_options.freeze
            update_options
          end

          def update_options
            @compile_options = if @options.nil? || @options < RubyVM::InstructionSequence.compile_option
              nil
            else
              RubyVM::InstructionSequence.compile_option.merge(@options).freeze
            end
          end

          has_ruby_bug_18250 = RUBY_VERSION.start_with?("3.0.") && begin # https://bugs.ruby-lang.org/issues/18250
            if defined? RubyVM::InstructionSequence
              RubyVM::InstructionSequence.compile(<<~RUBY).to_binary
                def foo(*); ->{ super }; end; def foo(**); ->{ super }; end
              RUBY
            end
            false
          rescue TypeError
            true
          end

          has_ruby_bug_22023 = case RUBY_VERSION
          when /^3\.3\./
            true
          when /^3\.4\.(\d+)/
            $1.to_i < 10
          when /^4\.0\.(\d+)/
            $1.to_i < 4
          else
            false
          end

          if has_ruby_bug_22023 && RUBY_DESCRIPTION.include?("+PRISM")
            module PatchRubyBug22023
              def compile_file(path, options = nil)
                compile_file_prism(path, options)
              end

              has_ruby_bug_22023_bis = !RubyVM::InstructionSequence.compile_file_prism(
                File.expand_path("../ruby_bug_22023_canary.rb", __FILE__),
                {frozen_string_literal: true},
              ).eval.frozen?

              if has_ruby_bug_22023_bis
                def compile_file_prism(path, options = nil)
                  compile_prism(::File.read(path, encoding: Encoding::UTF_8), path, path, nil, options)
                end
              end
            end
            RubyVM::InstructionSequence.singleton_class.prepend(PatchRubyBug22023)
          end

          if has_ruby_bug_18250
            def input_to_storage(_, path)
              iseq = RubyVM::InstructionSequence.compile_file(path, @compile_options)
              iseq.to_binary
            rescue TypeError, SyntaxError # Ruby [Bug #18250] & [Bug #22023]
              UNCOMPILABLE
            end
          else
            def input_to_storage(_, path)
              RubyVM::InstructionSequence.compile_file(path, @compile_options).to_binary
            rescue SyntaxError # Ruby [Bug #22023]
              UNCOMPILABLE
            end
          end

          def storage_to_output(binary, _args)
            iseq = RubyVM::InstructionSequence.load_from_binary(binary)
            binary.clear
            iseq
          rescue RuntimeError => error
            if error.message == "broken binary format"
              $stderr.puts("[Bootsnap::CompileCache] warning: rejecting broken binary")
              nil
            else
              raise
            end
          end

          def input_to_output(source, path, _kwargs)
            if @compile_options
              if source
                RubyVM::InstructionSequence.compile(
                  source.force_encoding(Encoding.default_external),
                  path,
                  path,
                  nil,
                  @compile_options,
                )
              else
                RubyVM::InstructionSequence.compile_file(path, @compile_options)
              end
            end
          end
        end

        DEFAULT = Compiler.new
        FROZEN_STRING_LITERAL = Compiler.new("-fstr", {frozen_string_literal: true}.freeze)
        COVERAGE_SUPPORTED = RUBY_VERSION >= "4.0.4"

        @default_compiler = DEFAULT
        @coverage_support_warning_emitted = false

        def self.fetch(path, cache_dir: ISeq.cache_dir)
          compiler = compiler_selector&.call(path) || default_compiler

          # Having coverage enabled prevents iseq dumping/loading.
          if coverage_on?
            return nil if compiler.equal?(DEFAULT)

            if COVERAGE_SUPPORTED
              return compiler.input_to_output(nil, path.to_s, nil)
            elsif !@coverage_support_warning_emitted
              @coverage_support_warning_emitted = true
              warn(<<~MSG)
                Using `Bootsnap.enable_frozen_string_literal` with code coverage enabled is only supported on Ruby 4.0.4+.
                Files loaded while coverage is on, will have mutable string literals.
              MSG
            end

            return nil
          end

          Bootsnap::CompileCache::Native.fetch(
            cache_dir,
            compiler.namespace,
            path.to_s,
            compiler,
            nil,
          )
        end

        def self.precompile(path)
          compiler = compiler_selector&.call(path) || default_compiler
          Bootsnap::CompileCache::Native.precompile(
            cache_dir,
            compiler.namespace,
            path.to_s,
            compiler,
          )
        end

        if RUBY_VERSION < "3.1."
          def self.coverage_on?
            defined?(Coverage) && Coverage.running?
          end
        else
          def self.coverage_on?
            defined?(Coverage) && Coverage.state != :idle
          end
        end

        module InstructionSequenceMixin
          def load_iseq(path)
            Bootsnap::CompileCache::ISeq.fetch(path.to_s)
          rescue RuntimeError => error
            if error.message.include?("unmatched platform")
              puts("unmatched platform for file #{path}")
            end
            raise
          end

          def compile_option=(hash)
            super
            Bootsnap::CompileCache::ISeq.compile_option_updated
          end
        end

        def self.compile_option_updated
          option = RubyVM::InstructionSequence.compile_option
          crc = Zlib.crc32(option.inspect)
          Bootsnap::CompileCache::Native.compile_option_crc32 = crc
          FROZEN_STRING_LITERAL.update_options
        end
        compile_option_updated if supported?

        def self.install!(cache_dir)
          Bootsnap::CompileCache::ISeq.cache_dir = cache_dir

          return unless supported?

          Bootsnap::CompileCache::ISeq.compile_option_updated

          class << RubyVM::InstructionSequence
            prepend(InstructionSequenceMixin)
          end
        end
      else
        def self.install!(...)
          # noop
        end

        def self.precompile(...)
          # noop
        end
      end
    end
  end
end
