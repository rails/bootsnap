# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

if Warning.respond_to?(:[]=)
  Warning[:deprecated] = true
end

require "bundler/setup"
require "bootsnap"
require "bootsnap/compile_cache/yaml"

require "tmpdir"
require "fileutils"

require "minitest/autorun"
require "mocha/minitest"

cache_dir = File.expand_path("../tmp/bootsnap/compile-cache", __dir__)
Bootsnap::CompileCache.setup(cache_dir: cache_dir, iseq: true, yaml: false)

if GC.respond_to?(:verify_compaction_references)
  # This method was added in Ruby 3.0.0. Calling it this way asks the GC to
  # move objects around, helping to find object movement bugs.
  begin
    GC.verify_compaction_references(expand_heap: true, toward: :empty)
  rescue NotImplementedError, ArgumentError
    # some platforms do not support GC compaction
  end
end

module TestHandler
  def self.input_to_storage(_input, path)
    "neato #{path}"
  end

  def self.storage_to_output(data, _kwargs)
    data.upcase
  end

  def self.input_to_output(_data, _kwargs)
    raise("but why tho")
  end
end

module NullCache
  def self.get(*)
  end

  def self.set(*)
  end

  def self.transaction(*)
    yield
  end

  def self.fetch(*)
    yield
  end
end

module Minitest
  class Test
    def stub_const(owner, const_name, stub_value)
      original_value = owner.const_get(const_name)
      owner.send(:remove_const, const_name)
      owner.const_set(const_name, stub_value)
      begin
        yield
      ensure
        owner.send(:remove_const, const_name)
        owner.const_set(const_name, original_value)
      end
    end

    module Help
      class << self
        def cache_path(dir, file, args_key = nil)
          hash = fnv1a_64(file)
          unless args_key.nil?
            hash ^= fnv1a_64(args_key)
          end

          hex = hash.to_s(16).rjust(16, "0")
          "#{dir}/#{hex[0..1]}/#{hex[2..]}"
        end

        def fnv1a_64(data)
          hash = 0xcbf29ce484222325
          data.bytes.each do |byte|
            hash ^= byte
            hash = (hash * 0x100000001b3) % (2**64)
          end
          hash
        end

        def set_file(path, contents, mtime = nil)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, contents)
          FileUtils.touch(path, mtime: mtime) if mtime
          path
        end
      end
    end
  end
end

module CompileCacheISeqHelper
  def setup
    unless defined?(Bootsnap::CompileCache::ISeq) && Bootsnap::CompileCache::ISeq.supported?
      skip("Unsupported platform")
    end

    super
  end
end

module LoadPathCacheHelper
  def setup
    skip("Unsupported platform") unless Bootsnap::LoadPathCache.supported?

    super
  end
end

module TmpdirHelper
  def setup
    super
    @prev_dir = Dir.pwd
    @tmp_dir = Dir.mktmpdir("bootsnap-test")
    Dir.chdir(@tmp_dir)

    if Bootsnap::CompileCache.supported?
      set_compile_cache_dir(:ISeq, @tmp_dir)
      set_compile_cache_dir(:YAML, @tmp_dir)
    end
  end

  def teardown
    super
    Dir.chdir(@prev_dir)
    FileUtils.remove_entry(@tmp_dir)

    if Bootsnap::CompileCache.supported?
      restore_compile_cache_dir(:ISeq)
      restore_compile_cache_dir(:YAML)
    end
  end

  private

  def restore_compile_cache_dir(mod_name)
    prev = instance_variable_get("@prev_#{mod_name.downcase}")
    # Restore directly to instance var to avoid duplication of suffix logic.
    Bootsnap::CompileCache.const_get(mod_name).instance_variable_set(:@cache_dir, prev) if prev
  end

  def set_compile_cache_dir(mod_name, dir)
    mod = Bootsnap::CompileCache.const_get(mod_name)
    instance_variable_set("@prev_#{mod_name.downcase}", mod.cache_dir)
    # Use setter method when setting to tmp dir.
    mod.cache_dir = dir
  end
end
