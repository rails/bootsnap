# frozen_string_literal: true

require "test_helper"

module Bootsnap
  class RakeTest < Minitest::Test
    def setup
      @_old_cache_dir = Bootsnap.cache_dir
      Bootsnap.instance_variable_set(:@cache_dir, Dir.mktmpdir("bootsnap-test"))
    end

    def teardown
      Bootsnap.instance_variable_set(:@cache_dir, @_old_cache_dir)
    end

    def test_cache_dir_is_cleaned
      require "bootsnap/rake"

      assert_includes(CLEAN, Bootsnap.cache_dir)
    end
  end
end
