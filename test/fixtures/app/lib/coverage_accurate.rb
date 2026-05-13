require "coverage"
Coverage.start
require "coverage_test"

actual = Coverage.result
fstr_check = 0
mstr_check = 0

case ENV["CHECK_STRING_LITERALS"]
when "frozen"
  fstr_check = 1
when "mutable"
  mstr_check = 1
end

coverage = [1, nil, fstr_check, nil, mstr_check, nil, nil, 0, nil, nil, 1, 1, nil, nil, 1, 1, nil, nil, 1]
expected = {
  File.expand_path("../coverage_test.rb", __FILE__) => coverage,
}

if actual == expected
  puts "OK: #{actual.inspect}"
else
  puts <<~EOS
    Expected: #{expected.inspect}
    Actual:   #{actual.inspect}
  EOS
  exit 1
end
