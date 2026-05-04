# rubocop:disable Style/FrozenStringLiteralComment
def foo(bars)
  case bars
  in [one, "a" | "b" => two]
    puts "#{one} - #{two}"
  end
end

_ = "test"
# rubocop:enable Style/FrozenStringLiteralComment
