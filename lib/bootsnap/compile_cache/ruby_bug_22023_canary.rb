# rubocop:disable Style/FrozenStringLiteralComment
f = -> {
  case foo
  in [one, "a" | "b" => two]
    puts "#{one} - #{two}"
  end
}
_ = "test"
# rubocop:enable Style/FrozenStringLiteralComment
