# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Bootsnap
  module LoadPathCache
    class PrebuiltIndexTest < Minitest::Test
      include LoadPathCacheHelper

      def setup
        super
        @dir1 = File.realpath(Dir.mktmpdir)
        @dir2 = File.realpath(Dir.mktmpdir)
        @cache_dir = Dir.mktmpdir
        @store_path = "#{@cache_dir}/load-path-cache"
        FileUtils.touch("#{@dir1}/a.rb")
        FileUtils.touch("#{@dir1}/b.rb")
        FileUtils.touch("#{@dir2}/c.rb")
      end

      def teardown
        FileUtils.rm_rf(@dir1)
        FileUtils.rm_rf(@dir2)
        FileUtils.rm_rf(@cache_dir)
      end

      def test_index_cache_saved_on_first_boot
        store = Store.new(@store_path)
        po = [@dir1, @dir2]
        cache = Cache.new(store, po)

        assert_equal "#{@dir1}/a.rb", cache.find("a")
        assert_equal "#{@dir2}/c.rb", cache.find("c")

        # Index file should exist
        assert File.exist?("#{@store_path}-index"), "Index cache file should be created"
      end

      def test_index_cache_loaded_on_second_boot
        # First boot: populates cache
        store1 = Store.new(@store_path)
        po1 = [@dir1, @dir2]
        Cache.new(store1, po1)

        # Second boot: should load from index, not scan directories
        store2 = Store.new(@store_path)
        po2 = [@dir1, @dir2]
        cache2 = Cache.new(store2, po2)

        assert_equal "#{@dir1}/a.rb", cache2.find("a")
        assert_equal "#{@dir2}/c.rb", cache2.find("c")
      end

      def test_index_cache_invalidated_on_path_change
        # First boot
        store1 = Store.new(@store_path)
        Cache.new(store1, [@dir1])

        # Second boot with different paths
        store2 = Store.new(@store_path)
        cache2 = Cache.new(store2, [@dir1, @dir2])

        # Should find files from both dirs (rebuilt index)
        assert_equal "#{@dir1}/a.rb", cache2.find("a")
        assert_equal "#{@dir2}/c.rb", cache2.find("c")
      end

      def test_fingerprint_deterministic
        paths = ["/a/b/c", "/d/e/f"]
        fp1 = Cache.load_path_fingerprint(paths)
        fp2 = Cache.load_path_fingerprint(paths)
        assert_equal fp1, fp2
      end

      def test_fingerprint_changes_with_path_order
        fp1 = Cache.load_path_fingerprint(["/a", "/b"])
        fp2 = Cache.load_path_fingerprint(["/b", "/a"])
        refute_equal fp1, fp2
      end

      def test_fingerprint_changes_with_path_content
        fp1 = Cache.load_path_fingerprint(["/a", "/b"])
        fp2 = Cache.load_path_fingerprint(["/a", "/c"])
        refute_equal fp1, fp2
      end
    end
  end
end
