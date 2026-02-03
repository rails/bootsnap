# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Bootsnap
  module LoadPathCache
    class StoreTest < Minitest::Test
      include LoadPathCacheHelper

      def setup
        super
        @dir = Dir.mktmpdir
        @path = "#{@dir}/store"
        @store = Store.new(@path)
      end

      def teardown
        FileUtils.rm_rf(@dir)
      end

      attr_reader(:store)

      def test_persistence
        store.transaction { store.set("a", "b") }

        store2 = Store.new(@path)
        assert_equal("b", store2.get("a"))
      end

      def test_modification
        store.transaction { store.set("a", "b") }

        store2 = Store.new(@path)
        assert_equal("b", store2.get("a"))
        store.transaction { store.set("a", "c") }

        store3 = Store.new(@path)
        assert_equal("c", store3.get("a"))
      end

      def test_modification_of_loaded_store
        store.transaction { store.set("a", "b") }
        store = Store.new(@path)
        store.transaction { store.set("c", "d") }
      end

      def test_stores_arrays
        store.transaction { store.set("a", [1234, %w(a b)]) }

        store2 = Store.new(@path)
        assert_equal([1234, %w(a b)], store2.get("a"))
      end

      def test_transaction_required_to_set
        assert_raises(Store::SetOutsideTransactionNotAllowed) do
          store.set("a", "b")
        end
        assert_raises(Store::SetOutsideTransactionNotAllowed) do
          store.fetch("a") { 1 + 1 }
        end
      end

      def test_nested_transaction_fails
        assert_raises(Store::NestedTransactionError) do
          store.transaction { store.transaction }
        end
      end

      def test_no_commit_unless_dirty
        store.transaction { store.set("a", nil) }
        refute(File.exist?(@path))
        store.transaction { store.set("a", 1) }
        assert(File.exist?(@path))
      end

      def test_retry_on_collision
        retries = sequence("retries")

        MessagePack.expects(:dump).in_sequence(retries).raises(Errno::EEXIST.new("File exists @ rb_sysopen"))
        MessagePack.expects(:dump).in_sequence(retries).returns(1)
        File.expects(:rename).in_sequence(retries)

        store.transaction { store.set("a", 1) }
      end

      def test_with_broken_symlink
        FileUtils.ln_s(@path, "#{@dir}/store_broken")
        store = Store.new("#{@dir}/store_broken/store")

        store.transaction { store.set("a", "b") }
      end

      def test_ignore_read_only_filesystem
        MessagePack.expects(:dump).raises(Errno::EROFS.new("Read-only file system @ rb_sysopen"))
        store.transaction { store.set("a", 1) }
        refute(File.exist?(@path))
      end

      def test_bust_cache_on_ruby_change
        store.transaction { store.set("a", "b") }

        assert_equal "b", Store.new(@path).get("a")

        stub_const(Store, :CURRENT_VERSION, "foobar") do
          assert_nil Store.new(@path).get("a")
        end
      end
    end
  end
end
