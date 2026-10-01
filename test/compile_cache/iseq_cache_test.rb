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
        Bootsnap::CompileCache::ISeq::DEFAULT
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

  def test_input_to_output_encoding
    compiler = Bootsnap::CompileCache::ISeq::FROZEN_STRING_LITERAL
    source = "_a = 'fée'.encoding".b
    iseq = compiler.input_to_output(source, "a.rb", nil)
    assert_equal Encoding.default_external, iseq.eval
  end

  def test_source_encoding_does_not_depend_on_default_internal
    previous_external = Encoding.default_external
    previous_internal = Encoding.default_internal
    fixtures = {
      "utf8" => ["# encoding: UTF-8\n# frozen_string_literal: true\n'fée'\n", Encoding::UTF_8],
      "latin1" => ["# encoding: ISO-8859-1\n# frozen_string_literal: true\n'caf\xE9'\n".b, Encoding::ISO_8859_1],
    }

    fixtures.each do |name, (source, encoding)|
      [nil, Encoding::UTF_8, Encoding::ASCII_8BIT, Encoding::ISO_8859_1].each_with_index do |internal, index|
        path = "#{name}-#{index}.rb"
        File.binwrite(path, source)
        Encoding.default_external = Encoding::ASCII_8BIT
        Encoding.default_internal = internal

        2.times do
          result = Bootsnap::CompileCache::ISeq.fetch(path).eval
          assert_equal encoding, result.encoding
          assert_equal source.b.lines.last.strip[1...-1], result.b
          assert_predicate result, :frozen?
        end
      end
    end
  ensure
    Encoding.default_external = previous_external
    Encoding.default_internal = previous_internal
  end
end
