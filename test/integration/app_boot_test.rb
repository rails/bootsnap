# frozen_string_literal: true

require "test_helper"
require "open3"

module Bootsnap
  class AppBootTest < Minitest::Test
    include LoadPathCacheHelper
    include TmpdirHelper

    APP_DIR = File.expand_path("../../fixtures/app/", __FILE__)

    def test_boot_success
      assert_boot("success")
    end

    def test_boot_with_coverage_running
      assert_boot("success", coverage: "started")
    end

    def test_boot_with_coverage_suspended
      skip("Ruby 3.1+ only") if RUBY_VERSION < "3.1" || RUBY_ENGINE == "truffleruby"
      assert_boot("success", coverage: "suspended")
    end

    def test_boot_frozen_string_literal
      skip("MRI only") unless RUBY_ENGINE == "ruby"
      assert_boot("check_frozen_literal", compiler: "fstr")
    end

    def test_boot_frozen_string_literal_and_coverage
      skip("MRI only") unless RUBY_ENGINE == "ruby"
      skip("Need to find a workaround for this...")
      assert_boot("check_frozen_literal", compiler: "fstr", coverage: "started")
    end

    private

    def assert_boot(feature, coverage: nil, compiler: nil)
      env = {
        "BOOTSNAP_CACHE_DIR" => @tmp_dir,
        "FEATURE" => feature,
        "COVERAGE" => coverage,
        "COMPILER" => compiler,
      }
      stdin, stdout_and_stderr, wait_thread = Open3.popen2e(env, RbConfig.ruby, File.join(APP_DIR, "boot.rb"))
      stdin.close
      status = wait_thread.value
      assert_predicate status, :success?, stdout_and_stderr.read
    end
  end
end
