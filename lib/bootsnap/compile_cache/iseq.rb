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

      class Compiler
        attr_reader :namespace, :compile_options

        def initialize(namespace = nil, compile_options = nil)
          @namespace = namespace
          @compile_options = compile_options
        end

        has_ruby_bug_18250 = begin # https://bugs.ruby-lang.org/issues/18250
          if defined? RubyVM::InstructionSequence
            RubyVM::InstructionSequence.compile("def foo(*); ->{ super }; end; def foo(**); ->{ super }; end").to_binary
          end
          false
        rescue TypeError
          true
        end

        if has_ruby_bug_18250
          def input_to_storage(_, path)
            iseq = RubyVM::InstructionSequence.compile_file(path, @compile_options)

            begin
              iseq.to_binary
            rescue TypeError
              UNCOMPILABLE # ruby bug #18250
            end
          end
        else
          def input_to_storage(_, path)
            RubyVM::InstructionSequence.compile_file(path, @compile_options).to_binary
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
          RubyVM::InstructionSequence.compile(
            source.force_encoding(Encoding.default_external),
            path,
            path,
            nil,
            @compile_options,
          )
        end
      end

      DEFAULT = Compiler.new
      FROZEN_STRING_LITERAL = Compiler.new("-fstr", {frozen_string_literal: true}.freeze)
      MUTABLE_STRING_LITERAL = Compiler.new("-no-fstr", {frozen_string_literal: false}.freeze)
      @default_compiler = DEFAULT

      def self.fetch(path, cache_dir: ISeq.cache_dir)
        compiler = compiler_selector&.call(path) || default_compiler
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

      module InstructionSequenceMixin
        def load_iseq(path)
          # Having coverage enabled prevents iseq dumping/loading.
          return nil if defined?(Coverage) && Coverage.running?

          Bootsnap::CompileCache::ISeq.fetch(path.to_s)
        rescue RuntimeError => error
          if error.message =~ /unmatched platform/
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
    end
  end
end
