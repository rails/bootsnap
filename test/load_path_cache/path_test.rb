# frozen_string_literal: true

require "test_helper"
require "bootsnap/load_path_cache"

module Bootsnap
  module LoadPathCache
    class PathTest < Minitest::Test
      include LoadPathCacheHelper

      def setup
        super
        @cache = Object.new
      end

      def test_stability
        require "time"

        time_file       = Time.method(:rfc2822).source_location[0]
        volatile        = Path.new(__FILE__)
        stable          = Path.new(time_file)
        unknown         = Path.new("/who/knows")
        lib             = Path.new("#{RbConfig::CONFIG['rubylibdir']}/a")
        site            = Path.new("#{RbConfig::CONFIG['sitedir']}/b")
        absolute_prefix = RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/ ? ENV["SystemDrive"] : ""
        bundler         = Path.new("#{absolute_prefix}/bp/3")

        Bundler.stubs(:bundle_path).returns("#{absolute_prefix}/bp")

        assert(stable.stable?, "The stable path #{stable.path.inspect} was unexpectedly not stable.")
        refute(stable.volatile?, "The stable path #{stable.path.inspect} was unexpectedly volatile.")
        assert(volatile.volatile?, "The volatile path #{volatile.path.inspect} was unexpectedly not volatile.")
        refute(volatile.stable?, "The volatile path #{volatile.path.inspect} was unexpectedly stable.")
        assert(unknown.volatile?, "The unknown path #{unknown.path.inspect} was unexpectedly not volatile.")
        refute(unknown.stable?, "The unknown path #{unknown.path.inspect} was unexpectedly stable.")

        assert(lib.stable?, "The lib path #{lib.path.inspect} was unexpectedly not stable.")
        refute(site.stable?, "The site path #{site.path.inspect} was unexpectedly stable.")
        assert(bundler.stable?, "The bundler path #{bundler.path.inspect} was unexpectedly not stable.")
      end

      def test_non_directory?
        if RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/
          refute(Path.new("c:/dev").non_directory?)
          refute(Path.new("c:/nope").non_directory?)
          # there isn't a direct analog i could think of
          # assert(Path.new('/dev/null').non_directory?)
          assert(Path.new("#{ENV['WinDir']}/System32/Drivers/Etc/hosts").non_directory?)
        else
          refute(Path.new("/dev").non_directory?)
          refute(Path.new("/nope").non_directory?)
          assert(Path.new("/dev/null").non_directory?)
          assert(Path.new("/etc/hosts").non_directory?)
        end
      end

      def test_volatile_cache_valid_when_mtime_has_not_changed
        with_caching_fixtures do |dir, _a, _a_b, _a_b_c|
          entries = PathScanner.call(dir)
          path = Path.new(dir) # volatile, since it'll be in /tmp

          @cache.expects(:get).with(path.expanded_path).returns([100, entries])

          path.entries(@cache)
        end
      end

      def test_volatile_cache_invalid_when_mtime_changed
        with_caching_fixtures do |dir, _a, a_b, _a_b_c|
          entries = PathScanner.call(dir)
          path = Path.new(dir) # volatile, since it'll be in /tmp

          FileUtils.touch(a_b, mtime: Time.at(101))

          @cache.expects(:get).with(path.expanded_path).returns([100, entries])
          @cache.expects(:set).with(path.expanded_path, [101, entries])

          # next read doesn't regen
          @cache.expects(:get).with(path.expanded_path).returns([101, entries])

          path.entries(@cache)
          path.entries(@cache)
        end
      end

      def test_volatile_cache_generated_when_missing
        with_caching_fixtures do |dir, _a, _a_b, _a_b_c|
          entries = PathScanner.call(dir)
          path = Path.new(dir) # volatile, since it'll be in /tmp

          @cache.expects(:get).with(path.expanded_path).returns(nil)
          @cache.expects(:set).with(path.expanded_path, [100, entries])

          path.entries(@cache)
        end
      end

      def test_stable_cache_does_not_notice_when_mtime_changes
        with_caching_fixtures do |dir, _a, a_b, _a_b_c|
          entries = PathScanner.call(dir)
          path = Path.new(dir) # volatile, since it'll be in /tmp
          path.expects(:stable?).returns(true)

          FileUtils.touch(a_b, mtime: Time.at(101))

          # It's unfortunate that we're stubbing the impl of #fetch here.
          PathScanner.expects(:call).never
          @cache.expects(:get).with(path.expanded_path).returns([100, entries])

          path.entries(@cache)
        end
      end

      private

      def with_caching_fixtures
        Dir.mktmpdir do |dir|
          a     = "#{dir}/a"
          a_b   = "#{dir}/a/b"
          a_b_c = "#{dir}/a/b/c.rb"
          FileUtils.mkdir_p(a_b)
          [a_b_c, a_b, a, dir].each { |f| FileUtils.touch(f, mtime: Time.at(100)) }

          yield(dir, a, a_b, a_b_c)
        end
      end
    end
  end
end
