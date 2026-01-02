# frozen_string_literal: true

require "test_helper"
require "bootsnap/load_path_cache"

module Bootsnap
  module LoadPathCache
    class NativeScanDirTest < Minitest::Test
      include LoadPathCacheHelper

      def test_sys_fail_with_zero_errno
        unless Native.respond_to?(:__test_sys_fail_zero_errno)
          skip("Native test helper not available")
        end

        error = assert_raises(SystemCallError) do
          Native.__test_sys_fail_zero_errno
        end

        assert_kind_of(Errno::EIO, error)
      end
    end
  end
end
