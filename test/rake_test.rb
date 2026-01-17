# frozen_string_literal: true

require "test_helper"

module Bootsnap
  class RakeTest < Minitest::Test
    def test_cache_dir_is_cleaned
      Bootsnap.setup(cache_dir: Dir.mktmpdir("bootsnap-test"))
      require "bootsnap/rake"

      refute_nil(Bootsnap.cache_dir)
      assert_includes(CLEAN, Bootsnap.cache_dir)
    end
  end
end
