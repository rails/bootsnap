# frozen_string_literal: true

require "test_helper"

class CompileCacheISeqTest < Minitest::Test
  include CompileCacheISeqHelper
  include TmpdirHelper

  def test_ruby_bug_18250
    Help.set_file("a.rb", "def foo(*); ->{ super }; end; def foo(**); ->{ super }; end", 100)
    Bootsnap::CompileCache::ISeq.fetch("a.rb")
  end

  def test_compiler_selector
    compiler_selector = Bootsnap::CompileCache::ISeq.compiler_selector

    target = Help.set_file("a.rb", "p(frozen: 'test'.frozen?)")
    out, _err = capture_io do
      load(target)
    end
    assert_equal({frozen: false}.inspect, out.strip)

    Bootsnap::CompileCache::ISeq.compiler_selector = lambda { |path|
      if path.end_with?("a.rb")
        Bootsnap::CompileCache::ISeq::FROZEN_STRING_LITERAL
      else
        Bootsnap::CompileCache::ISeq::MUTABLE_STRING_LITERAL
      end
    }

    target = Help.set_file("a.rb", "p(frozen: 'test'.frozen?)")
    out, _err = capture_io do
      load(target)
    end
    assert_equal({frozen: true}.inspect, out.strip)

    target = Help.set_file("b.rb", "p(frozen: 'test'.frozen?)")
    out, _err = capture_io do
      load(target)
    end
    assert_equal({frozen: false}.inspect, out.strip)
  ensure
    Bootsnap::CompileCache::ISeq.compiler_selector = compiler_selector
  end
end
