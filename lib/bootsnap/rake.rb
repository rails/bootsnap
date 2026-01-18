# frozen_string_literal: true

require "bootsnap"
require "rake/clean"

CLEAN.include Bootsnap.cache_dir if Bootsnap.cache_dir
