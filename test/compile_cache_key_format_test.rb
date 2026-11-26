# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "tmpdir"
require "fileutils"
require "pathname"

class CompileCacheKeyFormatTest < Minitest::Test
  FILE = File.expand_path(__FILE__)
  include CompileCacheISeqHelper
  include TmpdirHelper

  R = {
    ruby_version_digest: 0...8,
    mtime: 8...16,
    digest: 16...24,
    size: 24...28,
    data_size: 28...32,
  }.freeze
  CACHE_KEY_SIZE = 32

  def teardown
    Bootsnap::CompileCache::Native.revalidation = false
    super
  end

  def test_key_compile_option_stable
    k1 = cache_key_for_file(FILE)
    k2 = cache_key_for_file(FILE)
    RubyVM::InstructionSequence.compile_option = {tailcall_optimization: true}
    k3 = cache_key_for_file(FILE)
    assert_equal(k1[R[:ruby_version_digest]], k2[R[:ruby_version_digest]])
    refute_equal(k1[R[:ruby_version_digest]], k3[R[:ruby_version_digest]])
  ensure
    RubyVM::InstructionSequence.compile_option = {tailcall_optimization: false}
  end

  def test_key_compile_option_custom_compiler
    Bootsnap::CompileCache::ISeq.default_compiler = Bootsnap::CompileCache::ISeq::FROZEN_STRING_LITERAL
    k1 = cache_key_for_file(FILE)
    k2 = cache_key_for_file(FILE)
    RubyVM::InstructionSequence.compile_option = {tailcall_optimization: true}
    k3 = cache_key_for_file(FILE)
    assert_equal(k1[R[:ruby_version_digest]], k2[R[:ruby_version_digest]])
    refute_equal(k1[R[:ruby_version_digest]], k3[R[:ruby_version_digest]])
  ensure
    Bootsnap::CompileCache::ISeq.default_compiler = Bootsnap::CompileCache::ISeq::DEFAULT
    RubyVM::InstructionSequence.compile_option = {tailcall_optimization: false}
  end

  def test_key_ruby_version_digest
    Bootsnap::CompileCache::ISeq.compile_option_updated

    key = cache_key_for_file(FILE)
    hash = Help.fnv1a_64(Bootsnap::RUBY_CACHE_KEY)
    hash = Help.fnv1a_64_iter(hash, [8].pack("L"))
    hash = Help.fnv1a_64_iter(hash, [Zlib.crc32(RubyVM::InstructionSequence.compile_option.inspect)].pack("L"))
    assert_equal([hash].pack("Q"), key[R[:ruby_version_digest]])
  end

  def test_key_size
    key = cache_key_for_file(FILE)
    exp = File.size(FILE)
    act = key[R[:size]].unpack1("L")
    assert_equal(exp, act)
  end

  def test_key_mtime
    key = cache_key_for_file(FILE)
    exp = File.mtime(FILE).to_i
    act = key[R[:mtime]].unpack1("Q")
    assert_equal(exp, act)
  end

  def test_fetch
    target = Help.set_file("a.rb", "foo = 1")

    cache_dir = File.join(@tmp_dir, "compile_cache")
    actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, target, target, TestHandler, nil)
    assert_equal("NEATO #{target.upcase}", actual)

    entries = Dir["#{cache_dir}/**/*"].select { |f| File.file?(f) }
    assert_equal 1, entries.size
    cache_file = entries.first

    data = File.read(cache_file)
    assert_equal("neato #{target}", data.b[CACHE_KEY_SIZE..])

    actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, target, target, TestHandler, nil)
    assert_equal("NEATO #{target.upcase}", actual)
  end

  def test_fetch_pathname
    target = Help.set_file("a.rb", "foo = 1")

    cache_dir = File.join(@tmp_dir, "compile_cache")
    actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, Pathname.new(target), Pathname.new(target), TestHandler, nil)
    assert_equal("NEATO #{target.upcase}", actual)

    # Same cache entry as the String form: the path is converted before it is
    # hashed and before it is read back with RSTRING_PTR.
    Bootsnap::CompileCache::Native.fetch(cache_dir, nil, target, target, TestHandler, nil)
    entries = Dir["#{cache_dir}/**/*"].select { |f| File.file?(f) }
    assert_equal(1, entries.size)
  end

  def test_precompile_pathname
    target = Help.set_file("a.rb", "foo = 1")

    cache_dir = File.join(@tmp_dir, "compile_cache")
    assert(Bootsnap::CompileCache::Native.precompile(cache_dir, nil, Pathname.new(target), Pathname.new(target), TestHandler))

    entries = Dir["#{cache_dir}/**/*"].select { |f| File.file?(f) }
    assert_equal(1, entries.size)
    assert_equal("neato #{target}", File.read(entries.first).b[CACHE_KEY_SIZE..])
  end

  def test_revalidation
    Bootsnap::CompileCache::Native.revalidation = true
    cache_dir = File.join(@tmp_dir, "compile_cache")

    target = Help.set_file("a.rb", "foo = 1")

    actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, target, target, TestHandler, nil)
    assert_equal("NEATO #{target.upcase}", actual)

    10.times do
      FileUtils.touch(target, mtime: File.mtime(target) + 42)
      actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, target, target, TestHandler, nil)
      assert_equal("NEATO #{target.upcase}", actual)
    end
  end

  def test_shared_cache_key
    target = Help.set_file("a.rb", "foo = 1")
    different_target = Help.set_file("b.rb", "foo = 1")

    cache_dir = File.join(@tmp_dir, "compile_cache")
    actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, target, "cache_key", TestHandler, nil)
    assert_equal("NEATO A.RB", actual)

    actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, different_target, "cache_key", TestHandler, nil)
    assert_equal("NEATO A.RB", actual)

    actual = Bootsnap::CompileCache::Native.fetch(cache_dir, nil, different_target, "different_cache_key", TestHandler, nil)
    assert_equal("NEATO B.RB", actual)
  end

  def test_unexistent_fetch
    assert_raises(Errno::ENOENT) do
      Bootsnap::CompileCache::Native.fetch(@tmp_dir, nil, "123", "123", Bootsnap::CompileCache::ISeq, nil)
    end
  end

  private

  def cache_key_for_file(file, cache_key = file)
    Bootsnap::CompileCache::Native.fetch(@tmp_dir, nil, file, cache_key, TestHandler, nil)
    data = File.binread(Help.cache_path(@tmp_dir, cache_key))
    data.byteslice(0...CACHE_KEY_SIZE)
  end
end
