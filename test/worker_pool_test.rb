# frozen_string_literal: true

require "test_helper"
require "bootsnap/cli"

module Bootsnap
  class WorkerPoolTestTest < Minitest::Test
    def test_dispatch
      @pool = CLI::WorkerPool.create(size: 2, jobs: {touch: ->(path) { File.write(path, Process.pid.to_s) }})
      @pool.spawn

      Dir.mktmpdir("bootsnap-test") do |tmpdir|
        10.times do |i|
          @pool.push(:touch, File.join(tmpdir, i.to_s))
        end

        @pool.shutdown
        files = Dir.chdir(tmpdir) { Dir["*"] }.sort
        assert_equal Array.new(10, &:to_s), files
      end
    end
  end
end
