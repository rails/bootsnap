if ENV["COVERAGE"]
  require "coverage"
  case ENV["COVERAGE"]
  when "started"
    Coverage.start
  when "suspended"
    Coverage.start
    Coverage.suspend
  when "stopped"
    Coverage.start
    Coverage.result(stop: true)
  when nil
  else
    raise "Unkown $COVERAGE value: #{ENV["COVERAGE"].inspect}"
  end
end

$LOAD_PATH.unshift(File.expand_path("../lib/", __FILE__))

require "bootsnap/setup"

case ENV["COMPILER"]
when "fstr"
  Bootsnap.enable_frozen_string_literal(app_only: true)
when nil
else
  raise "Unkown $COMPILER value: #{ENV["COMPILER"].inspect}"
end

require ENV.fetch("FEATURE")
