case ENV["CHECK_STRING_LITERALS"]
when "frozen"
  raise "String literal should have been frozen" unless "test".frozen?
when "mutable"
  raise "String literal should NOT have been frozen" if "test".frozen?
when nil
else
  raise "Unexpected value for $CHECK_STRING_LITERALS: #{ENV["CHECK_STRING_LITERALS"].inspect}"
end

def method_a
  1 + 1
end

def method_b
  method_a + 2
end

method_b
