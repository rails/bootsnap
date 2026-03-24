# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Bootsnap
  module CompileCache
    class ISeqBundleTest < Minitest::Test
      include CompileCacheISeqHelper

      def setup
        super
        @gem_dir = File.realpath(Dir.mktmpdir("fakegem"))
        @cache_dir = Dir.mktmpdir("bundle-cache")
        @compile_cache_dir = File.join(@cache_dir, "bootsnap", "compile-cache")
        @bundles_dir = File.join(@cache_dir, "bootsnap", ISeqBundle::BUNDLE_DIR)

        # Create fake gem files
        FileUtils.mkdir_p("#{@gem_dir}/lib/fakegem")
        File.write("#{@gem_dir}/lib/fakegem.rb", "module Fakegem; VERSION = '1.0'; end")
        File.write("#{@gem_dir}/lib/fakegem/helper.rb", "module Fakegem; module Helper; end; end")
        File.write("#{@gem_dir}/lib/fakegem/util.rb", "module Fakegem; module Util; X = 1; end; end")
      end

      def teardown
        FileUtils.rm_rf(@gem_dir)
        FileUtils.rm_rf(@cache_dir)
        super
      end

      def test_gem_bundle_build_and_load
        source_files = Dir.glob("#{@gem_dir}/lib/**/*.rb")
        bundle = ISeqBundle::GemBundle.build(@bundles_dir, "#{@gem_dir}/lib", source_files)

        assert bundle, "Bundle should be built"
        assert_equal 3, bundle_entry_count(bundle)

        # Verify we can fetch each file
        source_files.each do |path|
          result = bundle.fetch_entry(path, false)
          assert result, "Should fetch ISeq for #{path}"
          assert_kind_of RubyVM::InstructionSequence, result
        end
      end

      def test_gem_bundle_persistence
        source_files = Dir.glob("#{@gem_dir}/lib/**/*.rb")
        ISeqBundle::GemBundle.build(@bundles_dir, "#{@gem_dir}/lib", source_files)

        # Load from disk
        loaded = ISeqBundle::GemBundle.load(@bundles_dir, "#{@gem_dir}/lib")
        assert loaded, "Bundle should load from disk"

        source_files.each do |path|
          result = loaded.fetch_entry(path, false)
          assert result, "Should fetch ISeq for #{path} from loaded bundle"
        end
      end

      def test_gem_bundle_returns_nil_for_unknown_path
        source_files = Dir.glob("#{@gem_dir}/lib/**/*.rb")
        bundle = ISeqBundle::GemBundle.build(@bundles_dir, "#{@gem_dir}/lib", source_files)

        result = bundle.fetch_entry("/nonexistent/path.rb", false)
        assert_nil result
      end

      def test_gem_bundle_validates_source_mtime
        source_files = Dir.glob("#{@gem_dir}/lib/**/*.rb")
        bundle = ISeqBundle::GemBundle.build(@bundles_dir, "#{@gem_dir}/lib", source_files)

        # Modify source file with a future mtime to ensure it differs
        File.write("#{@gem_dir}/lib/fakegem.rb", "module Fakegem; VERSION = '2.0'; end")
        FileUtils.touch("#{@gem_dir}/lib/fakegem.rb", mtime: Time.now + 10)

        result = bundle.fetch_entry("#{@gem_dir}/lib/fakegem.rb", false)
        assert_nil result, "Should return nil when source mtime changed"
      end

      def test_gem_bundle_skip_validation
        source_files = Dir.glob("#{@gem_dir}/lib/**/*.rb")
        bundle = ISeqBundle::GemBundle.build(@bundles_dir, "#{@gem_dir}/lib", source_files)

        # Modify source file with a future mtime
        File.write("#{@gem_dir}/lib/fakegem.rb", "module Fakegem; VERSION = '2.0'; end")
        FileUtils.touch("#{@gem_dir}/lib/fakegem.rb", mtime: Time.now + 10)

        # With skip_validation, should still return cached ISeq
        result = bundle.fetch_entry("#{@gem_dir}/lib/fakegem.rb", true)
        assert result, "Should return cached ISeq when skip_validation is true"
      end

      def test_gem_bundle_returns_nil_for_deleted_source
        source_files = Dir.glob("#{@gem_dir}/lib/**/*.rb")
        bundle = ISeqBundle::GemBundle.build(@bundles_dir, "#{@gem_dir}/lib", source_files)

        File.delete("#{@gem_dir}/lib/fakegem.rb")

        result = bundle.fetch_entry("#{@gem_dir}/lib/fakegem.rb", false)
        assert_nil result, "Should return nil when source file deleted"
      end

      def test_gem_bundle_version_mismatch
        source_files = Dir.glob("#{@gem_dir}/lib/**/*.rb")
        ISeqBundle::GemBundle.build(@bundles_dir, "#{@gem_dir}/lib", source_files)

        # Corrupt the version
        stub_const(ISeqBundle::GemBundle, :VERSION, "fake-version") do
          # Redefine bundle_version temporarily
          original = ISeqBundle::GemBundle.method(:bundle_version)
          ISeqBundle::GemBundle.define_singleton_method(:bundle_version) { "fake-version" }
          loaded = ISeqBundle::GemBundle.load(@bundles_dir, "#{@gem_dir}/lib")
          ISeqBundle::GemBundle.define_singleton_method(:bundle_version, original)

          assert_nil loaded, "Should not load bundle with mismatched version"
        end
      end

      def test_gem_bundle_different_paths_get_different_bundles
        path1 = ISeqBundle::GemBundle.bundle_path(@bundles_dir, "/gems/foo-1.0/lib")
        path2 = ISeqBundle::GemBundle.bundle_path(@bundles_dir, "/gems/foo-2.0/lib")
        refute_equal path1, path2, "Different gem versions should have different bundle paths"
      end

      def test_gem_bundle_empty_directory
        empty_dir = Dir.mktmpdir("empty")
        bundle = ISeqBundle::GemBundle.build(@bundles_dir, empty_dir, [])
        assert_nil bundle, "Should not build bundle for empty file list"
        FileUtils.rm_rf(empty_dir)
      end

      def test_install_and_fetch_integration
        require "bootsnap/compile_cache/iseq_bundle"
        ISeqBundle.install!(@compile_cache_dir, skip_validation: false, auto_build: false)

        # No bundles exist yet, should return nil
        result = ISeqBundle.fetch("#{@gem_dir}/lib/fakegem.rb")
        assert_nil result
      end

      def test_install_disabled_via_env
        original = ENV["BOOTSNAP_NO_BUNDLE"]
        ENV["BOOTSNAP_NO_BUNDLE"] = "1"
        begin
          ISeqBundle.install!(@compile_cache_dir)
          refute ISeqBundle.loaded?, "Should be disabled when BOOTSNAP_NO_BUNDLE is set"
          assert_nil ISeqBundle.fetch("#{@gem_dir}/lib/fakegem.rb")
        ensure
          ENV["BOOTSNAP_NO_BUNDLE"] = original
          # Re-enable for other tests
          ISeqBundle.instance_variable_set(:@enabled, true)
        end
      end

      def test_build_for_paths
        built = ISeqBundle.build_for_paths!(@compile_cache_dir, ["#{@gem_dir}/lib"])
        assert_equal 1, built, "Should build 1 bundle"

        # Verify bundle file exists
        bundle_files = Dir.glob("#{@bundles_dir}/**/*").select { |f| File.file?(f) }
        assert_equal 1, bundle_files.size
      end

      private

      def bundle_entry_count(bundle)
        count = 0
        bundle.each_path { count += 1 }
        count
      end

      # Mini stub_const for non-nested constants
      def stub_const(_owner, _const_name, _value)
        yield
      end
    end
  end
end
