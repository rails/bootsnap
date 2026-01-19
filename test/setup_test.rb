# frozen_string_literal: true

require "test_helper"

module Bootsnap
  class SetupTest < Minitest::Test
    def setup
      @_old_env = ENV.to_h
      @tmp_dir = Dir.mktmpdir("bootsnap-test")
      ENV["BOOTSNAP_CACHE_DIR"] = @tmp_dir
    end

    def teardown
      ENV.replace(@_old_env)
    end

    def test_default_setup
      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: true,
        load_path_cache: true,
        compile_cache_iseq: true,
        compile_cache_yaml: true,
        ignore_directories: nil,
        readonly: false,
        revalidation: false,
      )

      Bootsnap.default_setup
    end

    def test_default_setup_with_ENV_not_dev
      ENV["ENV"] = "something"

      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: false,
        load_path_cache: true,
        compile_cache_iseq: true,
        compile_cache_yaml: true,
        ignore_directories: nil,
        readonly: false,
        revalidation: false,
      )

      Bootsnap.default_setup
    end

    def test_default_setup_with_DISABLE_BOOTSNAP_LOAD_PATH_CACHE
      ENV["DISABLE_BOOTSNAP_LOAD_PATH_CACHE"] = "something"

      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: true,
        load_path_cache: false,
        compile_cache_iseq: true,
        compile_cache_yaml: true,
        ignore_directories: nil,
        readonly: false,
        revalidation: false,
      )

      Bootsnap.default_setup
    end

    def test_default_setup_with_DISABLE_BOOTSNAP_COMPILE_CACHE
      ENV["DISABLE_BOOTSNAP_COMPILE_CACHE"] = "something"

      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: true,
        load_path_cache: true,
        compile_cache_iseq: false,
        compile_cache_yaml: false,
        ignore_directories: nil,
        readonly: false,
        revalidation: false,
      )

      Bootsnap.default_setup
    end

    def test_default_setup_with_DISABLE_BOOTSNAP
      ENV["DISABLE_BOOTSNAP"] = "something"

      Bootsnap.expects(:setup).never
      Bootsnap.default_setup
    end

    def test_default_setup_with_BOOTSNAP_LOG
      ENV["BOOTSNAP_LOG"] = "something"

      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: true,
        load_path_cache: true,
        compile_cache_iseq: true,
        compile_cache_yaml: true,
        ignore_directories: nil,
        readonly: false,
        revalidation: false,
      )
      Bootsnap.expects(:logger=).with($stderr.method(:puts))

      Bootsnap.default_setup
    end

    def test_default_setup_with_BOOTSNAP_IGNORE_DIRECTORIES
      ENV["BOOTSNAP_IGNORE_DIRECTORIES"] = "foo,bar"

      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: true,
        load_path_cache: true,
        compile_cache_iseq: true,
        compile_cache_yaml: true,
        ignore_directories: %w[foo bar],
        readonly: false,
        revalidation: false,
      )

      Bootsnap.default_setup
    end

    def test_default_setup_with_BOOTSNAP_READONLY
      ENV["BOOTSNAP_READONLY"] = "something"

      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: true,
        load_path_cache: true,
        compile_cache_iseq: true,
        compile_cache_yaml: true,
        ignore_directories: nil,
        readonly: true,
        revalidation: false,
      )

      Bootsnap.default_setup

      ENV["BOOTSNAP_READONLY"] = "false"

      Bootsnap.expects(:setup).with(
        cache_dir: @tmp_dir,
        development_mode: true,
        load_path_cache: true,
        compile_cache_iseq: true,
        compile_cache_yaml: true,
        ignore_directories: nil,
        readonly: false,
        revalidation: false,
      )

      Bootsnap.default_setup
    end

    def test_setup_appends_bootsnap_to_cache_dir
      skip("Need a working Process.fork to test in isolation") unless Process.respond_to?(:fork)

      pid = fork do
        Bootsnap.setup(cache_dir: @tmp_dir)

        assert_equal("#{@tmp_dir}/bootsnap", Bootsnap.cache_dir)
      end
      _, status = Process.waitpid2(pid)
      assert_predicate status, :success?
    ensure
      Bootsnap.unload_cache!
    end

    def test_unload_cache
      Bootsnap.unload_cache!
    end
  end
end
