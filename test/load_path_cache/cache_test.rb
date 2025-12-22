# frozen_string_literal: true

require "test_helper"

module Bootsnap
  module LoadPathCache
    class CacheTest < Minitest::Test
      include LoadPathCacheHelper

      def setup
        super
        @dir1 = File.realpath(Dir.mktmpdir)
        @dir2 = File.realpath(Dir.mktmpdir)
        FileUtils.touch("#{@dir1}/a.rb")
        FileUtils.mkdir_p("#{@dir1}/foo/bar")
        FileUtils.touch("#{@dir1}/foo/bar/baz.rb")
        FileUtils.touch("#{@dir2}/b.rb")
        FileUtils.touch("#{@dir1}/conflict.rb")
        FileUtils.touch("#{@dir2}/conflict.rb")
        FileUtils.touch("#{@dir1}/dl#{DLEXT}")
        FileUtils.touch("#{@dir1}/both.rb")
        FileUtils.touch("#{@dir1}/both#{DLEXT}")
        FileUtils.touch("#{@dir1}/béé.rb")
      end

      def teardown
        FileUtils.rm_rf(@dir1)
        FileUtils.rm_rf(@dir2)
      end

      # dev.yml specifies 2.3.3 and this test assumes it. Failures on other
      # versions aren't a big deal, but feel free to fix the test.
      def test_builtin_features
        cache = Cache.new(NullCache, [])
        assert_equal false, cache.find("thread")
        assert_equal false, cache.find("thread.rb")
        assert_equal false, cache.find("enumerator")

        if truffleruby?
          assert_equal false, cache.find("enumerator.rb")
        else
          assert_equal false, cache.find("enumerator.so")
          if RUBY_PLATFORM =~ /darwin/
            assert_equal false, cache.find("enumerator.bundle")
          else
            assert_same FALLBACK_SCAN, cache.find("enumerator.bundle")
          end
        end

        bundle = RUBY_PLATFORM =~ /darwin/ ? "bundle" : "so"

        # These are not present in TruffleRuby but that means they will still return falsey.
        refute(cache.find("thread.#{bundle}"))
        refute(cache.find("enumerator.rb"))
        refute(cache.find("encdb.#{bundle}"))
      end

      def test_simple
        po = [@dir1]
        cache = Cache.new(NullCache, po)
        assert_equal("#{@dir1}/a.rb", cache.find("a"))
        cache.push_paths(po, @dir2)
        assert_equal("#{@dir2}/b.rb", cache.find("b"))
      end

      def test_extension_append_for_relative_paths
        po = [@dir1]
        cache = Cache.new(NullCache, po)
        dir1_basename = File.basename(@dir1)
        Dir.chdir(@dir1) do
          assert_equal("#{@dir1}/a.rb",       cache.find("./a"))
          assert_equal("#{@dir1}/a.rb",       cache.find("../#{dir1_basename}/a"))
          assert_equal("#{@dir1}/dl#{DLEXT}", cache.find("./dl"))
          assert_equal("#{@dir1}/enoent",     cache.find("./enoent"))
        end
      end

      def test_unshifted_paths_have_higher_precedence
        po = [@dir1]
        cache = Cache.new(NullCache, po)
        assert_equal("#{@dir1}/conflict.rb", cache.find("conflict"))
        cache.unshift_paths(po, @dir2)
        assert_equal("#{@dir2}/conflict.rb", cache.find("conflict"))
      end

      def test_pushed_paths_have_lower_precedence
        po = [@dir1]
        cache = Cache.new(NullCache, po)
        assert_equal("#{@dir1}/conflict.rb", cache.find("conflict"))
        cache.push_paths(po, @dir2)
        assert_equal("#{@dir1}/conflict.rb", cache.find("conflict"))
      end

      def test_extension_permutations
        cache = Cache.new(NullCache, [@dir1])
        assert_equal("#{@dir1}/dl#{DLEXT}", cache.find("dl"))
        assert_equal("#{@dir1}/dl#{DLEXT}", cache.find("dl#{DLEXT}"))
        assert_equal("#{@dir1}/both.rb", cache.find("both"))
        assert_equal("#{@dir1}/both.rb", cache.find("both.rb"))
        assert_equal("#{@dir1}/both#{DLEXT}", cache.find("both#{DLEXT}"))
      end

      def test_relative_paths_rescanned
        Dir.chdir(@dir2) do
          cache = Cache.new(NullCache, %w(foo))
          refute(cache.find("bar/baz"))
          Dir.chdir(@dir1) do
            # one caveat here is that you get the actual path back when
            # resolving relative paths. On darwin, this means that
            # /var/folders/... comes back as /private/var/folders/... -- In
            # production, this should be fine, but for this test to pass, we
            # have to resolve it.
            assert_equal(File.realpath("#{@dir1}/foo/bar/baz.rb"), cache.find("bar/baz"))
          end
        end
      end

      def test_development_mode
        time = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i

        # without development_mode, no refresh
        dev_no_cache = Cache.new(NullCache, [@dir1], development_mode: false)
        dev_yes_cache = Cache.new(NullCache, [@dir1], development_mode: true)

        FileUtils.touch("#{@dir1}/new.rb")

        dev_no_cache.stubs(:now).returns(time + 31)
        refute(dev_no_cache.find("new"))

        dev_yes_cache.stubs(:now).returns(time + 28)
        assert_same Bootsnap::LoadPathCache::FALLBACK_SCAN, dev_yes_cache.find("new")
        dev_yes_cache.stubs(:now).returns(time + 31)
        assert(dev_yes_cache.find("new"))
      end

      def test_path_obj_equal?
        path_obj = []
        cache = Cache.new(NullCache, path_obj)

        path_obj.unshift(@dir1)

        assert_equal("#{@dir1}/a.rb", cache.find("a"))
      end

      if RbConfig::CONFIG["host_os"] !~ /mswin|mingw|cygwin/
        # https://github.com/ruby/ruby/pull/4061
        # https://bugs.ruby-lang.org/issues/17517
        OS_ASCII_PATH_ENCODING = RUBY_VERSION >= "3.1" ? Encoding::UTF_8 : Encoding::US_ASCII

        def test_path_encoding
          unless Encoding.default_external == Encoding::UTF_8
            # Encoding.default_external != Encoding::UTF_8 is likely a misconfiguration or a barebone system.
            # Supporting this use case would have an overhead for relatively little gain.
            skip "Encoding.default_external == #{Encoding.default_external}, expected Encoding::UTF_8."
          end

          po = [@dir1]
          cache = Cache.new(NullCache, po)

          path = cache.find("a")

          assert_equal("#{@dir1}/a.rb", path)
          require path
          internal_path = $LOADED_FEATURES.last
          assert_equal(OS_ASCII_PATH_ENCODING, internal_path.encoding)
          # TruffleRuby object is a copy and the encoding resets to utf-8.
          assert_equal(OS_ASCII_PATH_ENCODING, path.encoding) unless truffleruby?
          File.write(path, "")

          if truffleruby?
            assert_equal path, internal_path
          else
            assert_same path, internal_path
          end

          utf8_path = cache.find("béé")
          assert_equal("#{@dir1}/béé.rb", utf8_path)
          require utf8_path
          internal_utf8_path = $LOADED_FEATURES.last
          assert_equal(Encoding::UTF_8, internal_utf8_path.encoding)
          assert_equal(Encoding::UTF_8, utf8_path.encoding)
          File.write(utf8_path, "")

          if truffleruby?
            assert_equal utf8_path, internal_utf8_path
          else
            assert_same utf8_path, internal_utf8_path
          end
        end
      end

      private

      def truffleruby?
        RUBY_ENGINE == "truffleruby"
      end
    end
  end
end
