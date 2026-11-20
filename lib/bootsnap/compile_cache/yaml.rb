# frozen_string_literal: true

require "bootsnap/bootsnap"

module Bootsnap
  module CompileCache
    module YAML
      Uncompilable = Class.new(StandardError)
      UnsupportedTags = Class.new(Uncompilable)

      SUPPORTED_INTERNAL_ENCODINGS = [
        nil, # UTF-8
        Encoding::UTF_8,
        Encoding::ASCII,
        Encoding::BINARY,
      ].freeze

      class << self
        attr_accessor(:msgpack_factory, :supported_options)
        attr_reader(:implementation, :cache_dir)

        def cache_dir=(cache_dir)
          @cache_dir = cache_dir.end_with?("/") ? "#{cache_dir}yaml" : "#{cache_dir}-yaml"
        end

        def precompile(path)
          return false unless CompileCache::YAML.supported_internal_encoding?

          CompileCache::Native.precompile(
            cache_dir,
            nil,
            path.to_s,
            @implementation,
          )
        end

        def install!(cache_dir)
          self.cache_dir = cache_dir
          init!
          ::YAML.singleton_class.prepend(@implementation::Patch)
        end

        # Psych coerce strings to `Encoding.default_internal` but Message Pack only support
        # UTF-8, US-ASCII and BINARY. So if Encoding.default_internal is set to anything else
        # we can't safely use the cache
        def supported_internal_encoding?
          SUPPORTED_INTERNAL_ENCODINGS.include?(Encoding.default_internal)
        end

        def init!
          require "yaml"
          require "msgpack"
          require "date"

          @implementation = ::YAML::VERSION >= "4" ? Psych4 : Psych3
          if @implementation::Patch.method_defined?(:unsafe_load_file) && !::YAML.respond_to?(:unsafe_load_file)
            @implementation::Patch.send(:remove_method, :unsafe_load_file)
          end

          unless const_defined?(:NoTagsVisitor)
            visitor = Class.new(Psych::Visitors::NoAliasRuby) do
              def visit(target)
                if target.tag
                  raise UnsupportedTags, "YAML tags are not supported: #{target.tag}"
                end

                super
              end
            end
            const_set(:NoTagsVisitor, visitor)
          end

          # MessagePack serializes symbols as strings by default.
          # We want them to roundtrip cleanly, so we use a custom factory.
          # see: https://github.com/msgpack/msgpack-ruby/pull/122
          factory = MessagePack::Factory.new
          factory.register_type(
            0x00,
            Symbol,
            packer: :to_msgpack_ext,
            unpacker: :from_msgpack_ext,
            optimized_symbol_parsing: true,
          )

          factory.register_type(
            MessagePack::Timestamp::TYPE, # or just -1
            Time,
            packer: MessagePack::Time::Packer,
            unpacker: MessagePack::Time::Unpacker,
          )

          factory.register_type(
            0x01,
            Date,
            packer: lambda { |date, packer|
              packer.write(date.year)
              packer.write(date.month)
              packer.write(date.day)
            },
            unpacker: lambda { |unpacker|
              ::Date.new(unpacker.read, unpacker.read, unpacker.read)
            },
            recursive: true,
          )

          factory.register_type(
            0x02,
            Regexp,
            packer: ->(value) { Marshal.dump(value) },
            unpacker: ->(payload) { Marshal.load(payload) },
          )

          factory.register_type(
            0x03,
            DateTime,
            packer: lambda { |dt, packer|
              packer.write(dt.year)
              packer.write(dt.month)
              packer.write(dt.day)
              packer.write(dt.hour)
              packer.write(dt.minute)

              sec = dt.sec + dt.sec_fraction
              packer.write(sec.numerator)
              packer.write(sec.denominator)

              offset = dt.offset
              packer.write(offset.numerator)
              packer.write(offset.denominator)
            },
            unpacker: lambda { |unpacker|
              ::DateTime.new(
                unpacker.read, # year
                unpacker.read, # month
                unpacker.read, # day
                unpacker.read, # hour
                unpacker.read, # minute
                Rational(unpacker.read, unpacker.read), # sec fraction
                Rational(unpacker.read, unpacker.read), # offset fraction
              )
            },
            recursive: true,
          )

          require "msgpack/bigint"
          factory.register_type(
            0x04,
            Integer,
            packer: MessagePack::Bigint.method(:to_msgpack_ext),
            unpacker: MessagePack::Bigint.method(:from_msgpack_ext),
            oversized_integer_extension: true,
          )

          self.msgpack_factory = factory

          self.supported_options = []
          params = ::YAML.method(:load).parameters
          if params.include?([:key, :symbolize_names])
            supported_options << :symbolize_names
          end
          if params.include?([:key, :freeze])
            supported_options << :freeze
          end
          supported_options.freeze
        end

        def patch
          @implementation::Patch
        end

        def strict_load(payload)
          ast = ::YAML.parse(payload)
          return ast unless ast

          loader = ::Psych::ClassLoader::Restricted.new(["Symbol"], [])
          scanner = ::Psych::ScalarScanner.new(loader)

          NoTagsVisitor.new(scanner, loader).visit(ast)
        end

        def msgpack_unpacker_options(kwargs)
          return kwargs unless kwargs&.key?(:symbolize_names)

          kwargs = kwargs.dup
          kwargs[:symbolize_keys] = kwargs.delete(:symbolize_names)
          kwargs
        end
      end

      module Psych4
        extend self

        def input_to_storage(contents, _)
          obj = SafeLoad.input_to_storage(contents, nil)
          if UNCOMPILABLE.equal?(obj)
            obj = UnsafeLoad.input_to_storage(contents, nil)
          end
          obj
        end

        module UnsafeLoad
          extend self

          def input_to_storage(contents, _)
            obj = ::YAML.unsafe_load(contents)
            packer = CompileCache::YAML.msgpack_factory.packer
            packer.pack(false) # not safe loaded
            begin
              packer.pack(obj)
            rescue NoMethodError, RangeError
              return UNCOMPILABLE # The object included things that we can't serialize
            end
            packer.to_s
          end

          def storage_to_output(data, kwargs)
            unpacker = CompileCache::YAML.msgpack_factory.unpacker(
              CompileCache::YAML.msgpack_unpacker_options(kwargs),
            )
            unpacker.feed(data)
            _safe_loaded = unpacker.unpack
            result = unpacker.unpack
            data.clear
            result
          end

          def input_to_output(data, _path, kwargs)
            ::YAML.unsafe_load(data, **(kwargs || {}))
          end
        end

        module SafeLoad
          extend self

          def input_to_storage(contents, _)
            obj = begin
              CompileCache::YAML.strict_load(contents)
            rescue Psych::DisallowedClass, Psych::BadAlias, Uncompilable
              return UNCOMPILABLE
            end

            packer = CompileCache::YAML.msgpack_factory.packer
            packer.pack(true) # safe loaded
            begin
              packer.pack(obj)
            rescue NoMethodError, RangeError
              return UNCOMPILABLE
            end
            packer.to_s
          end

          def storage_to_output(data, kwargs)
            unpacker = CompileCache::YAML.msgpack_factory.unpacker(
              CompileCache::YAML.msgpack_unpacker_options(kwargs),
            )
            unpacker.feed(data)
            safe_loaded = unpacker.unpack
            if safe_loaded
              unpacker.unpack
            else
              UNCOMPILABLE
            end
          end

          def input_to_output(data, _path, kwargs)
            ::YAML.load(data, **(kwargs || {}))
          end
        end

        module Patch
          def load_file(path, *unknown_args, **kwargs)
            return super unless CompileCache::YAML.supported_internal_encoding?

            return super if unknown_args.size > 1
            return super unless (kwargs.keys - CompileCache::YAML.supported_options).empty?

            CompileCache::Native.fetch(
              CompileCache::YAML.cache_dir,
              nil,
              File.realpath(path),
              CompileCache::YAML::Psych4::SafeLoad,
              kwargs,
            )
          end

          def unsafe_load_file(path, *unknown_args, **kwargs)
            return super unless CompileCache::YAML.supported_internal_encoding?

            return super if unknown_args.size > 1
            return super unless (kwargs.keys - CompileCache::YAML.supported_options).empty?

            CompileCache::Native.fetch(
              CompileCache::YAML.cache_dir,
              nil,
              File.realpath(path),
              CompileCache::YAML::Psych4::UnsafeLoad,
              kwargs,
            )
          end
        end
      end

      module Psych3
        extend self

        def input_to_storage(contents, _)
          obj = ::YAML.load(contents)
          packer = CompileCache::YAML.msgpack_factory.packer
          packer.pack(false) # not safe loaded
          begin
            packer.pack(obj)
          rescue NoMethodError, RangeError
            return UNCOMPILABLE # The object included things that we can't serialize
          end
          packer.to_s
        end

        def storage_to_output(data, kwargs)
          unpacker = CompileCache::YAML.msgpack_factory.unpacker(
            CompileCache::YAML.msgpack_unpacker_options(kwargs),
          )
          unpacker.feed(data)
          _safe_loaded = unpacker.unpack
          unpacker.unpack
        end

        def input_to_output(data, _path, kwargs)
          ::YAML.load(data, **(kwargs || {}))
        end

        module Patch
          def load_file(path, *unknown_args, **kwargs)
            return super unless CompileCache::YAML.supported_internal_encoding?

            return super if unknown_args.size > 1
            return super unless (kwargs.keys - CompileCache::YAML.supported_options).empty?

            CompileCache::Native.fetch(
              CompileCache::YAML.cache_dir,
              nil,
              File.realpath(path),
              CompileCache::YAML::Psych3,
              kwargs,
            )
          end

          def unsafe_load_file(path, *unknown_args, **kwargs)
            return super unless CompileCache::YAML.supported_internal_encoding?

            return super if unknown_args.size > 1
            return super unless (kwargs.keys - CompileCache::YAML.supported_options).empty?

            CompileCache::Native.fetch(
              CompileCache::YAML.cache_dir,
              nil,
              File.realpath(path),
              CompileCache::YAML::Psych3,
              kwargs,
            )
          end
        end
      end
    end
  end
end
