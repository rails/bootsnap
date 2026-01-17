# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in bootsnap.gemspec
gemspec

if ENV["PSYCH_4"]
  gem "psych", ">= 4"
end

gem "bundler"
gem "rake"
gem "rake-compiler"
gem "minitest", "~> 5.0"
gem "mocha", "> 3"

group :development do
  gem "rubocop", "~> 1.50.2" # Ruby 2.6 support
  gem "benchmark"
  gem "ostruct"
  gem "base64"
end
