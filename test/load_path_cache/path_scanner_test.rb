# frozen_string_literal: true

require "test_helper"

module Bootsnap
  module LoadPathCache
    class PathScannerTest < Minitest::Test
      include LoadPathCacheHelper

      DLEXT = RbConfig::CONFIG["DLEXT"]
      OTHER_DLEXT = DLEXT == "bundle" ? "so" : "bundle"

      def test_scans_requirables_and_dirs
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p("#{dir}/ruby/a")
          FileUtils.mkdir_p("#{dir}/ruby/b/c")
          FileUtils.mkdir_p("#{dir}/support/h/i")
          FileUtils.mkdir_p("#{dir}/ruby/l")
          FileUtils.mkdir_p("#{dir}/support/l/m")
          FileUtils.touch("#{dir}/ruby/d.rb")
          FileUtils.touch("#{dir}/ruby/e.#{DLEXT}")
          FileUtils.touch("#{dir}/ruby/f.#{OTHER_DLEXT}")
          FileUtils.touch("#{dir}/ruby/a/g.rb")
          FileUtils.touch("#{dir}/support/h/j.rb")
          FileUtils.touch("#{dir}/support/h/i/k.rb")
          FileUtils.touch("#{dir}/support/l/m/n.rb")
          FileUtils.ln_s("#{dir}/support/h", "#{dir}/ruby/h")
          FileUtils.ln_s("#{dir}/support/l/m", "#{dir}/ruby/l/m")

          entries = PathScanner.call("#{dir}/ruby")
          assert_equal(["a/g.rb", "d.rb", "e.#{DLEXT}", "h/i/k.rb", "h/j.rb", "l/m/n.rb"], entries.sort)
        end
      end

      def test_scan_broken_symlink
        Dir.mktmpdir do |dir|
          File.symlink("/does/not/exist", "#{dir}/dir_link")
          assert_equal [], PathScanner.call(dir)
          assert_equal [], PathScanner.call("#{dir}/dir_link")
        end
      end

      def test_scan_missing_or_invalid_dir
        Dir.mktmpdir do |dir|
          assert_equal [], PathScanner.call("#{dir}/does/not/exist")
          File.write("#{dir}/file", "")
          assert_equal [], PathScanner.call("#{dir}/file")
        end
      end

      def test_ignores_directories_by_name
        with_ignored_directories(["ignored"]) do
          Dir.mktmpdir do |dir|
            FileUtils.mkdir_p("#{dir}/ignored")
            FileUtils.mkdir_p("#{dir}/included")
            FileUtils.touch("#{dir}/ignored/a.rb")
            FileUtils.touch("#{dir}/included/b.rb")

            entries = PathScanner.call(dir)
            assert_equal ["included/b.rb"], entries.sort
          end
        end
      end

      def test_ignores_directories_by_absolute_path
        Dir.mktmpdir do |dir|
          with_ignored_directories(["#{dir}/ignored"]) do
            FileUtils.mkdir_p("#{dir}/ignored")
            FileUtils.mkdir_p("#{dir}/included")
            FileUtils.touch("#{dir}/ignored/a.rb")
            FileUtils.touch("#{dir}/included/b.rb")

            entries = PathScanner.call(dir)
            assert_equal ["included/b.rb"], entries.sort
          end
        end
      end

      def test_ignores_nested_directories_by_absolute_path
        Dir.mktmpdir do |dir|
          with_ignored_directories(["#{dir}/parent/ignored"]) do
            FileUtils.mkdir_p("#{dir}/parent/ignored")
            FileUtils.mkdir_p("#{dir}/parent/included")
            FileUtils.touch("#{dir}/parent/ignored/a.rb")
            FileUtils.touch("#{dir}/parent/included/b.rb")

            entries = PathScanner.call(dir)
            assert_equal ["parent/included/b.rb"], entries.sort
          end
        end
      end

      def test_excludes_bundle_path_in_nested_directories
        Dir.mktmpdir do |dir|
          stub_const(PathScanner, :BUNDLE_PATH, "#{dir}/vendor/bundle/") do
            FileUtils.mkdir_p("#{dir}/vendor/bundle/ruby/gems")
            FileUtils.mkdir_p("#{dir}/app")
            FileUtils.touch("#{dir}/vendor/bundle/ruby/gems/foo.rb")
            FileUtils.touch("#{dir}/app/bar.rb")

            entries = PathScanner.call(dir)
            assert_equal ["app/bar.rb"], entries.sort
          end
        end
      end

      private

      def with_ignored_directories(directories)
        original = PathScanner.ignored_directories
        PathScanner.ignored_directories = directories
        yield
      ensure
        PathScanner.ignored_directories = original
      end
    end
  end
end
