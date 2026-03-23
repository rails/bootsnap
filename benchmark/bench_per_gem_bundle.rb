#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmarks per-gem ISeq bundles vs individual cache files.
# Compares: individual cache, per-gem bundles (cold build), per-gem bundles (warm).

require "fileutils"
require "json"

NUM_GEMS      = Integer(ARGV[0] || ENV.fetch("NUM_GEMS", 300))
FILES_PER_GEM = Integer(ARGV[1] || ENV.fetch("FILES_PER_GEM", 20))
RUNS          = Integer(ENV.fetch("BOOTSNAP_BENCH_RUNS", 3))

ROOT      = File.expand_path("..", __dir__)
BENCH_DIR = File.expand_path("tmp/fake_gems_#{NUM_GEMS}_#{FILES_PER_GEM}", ROOT)
CACHE_DIR = File.expand_path("tmp/bench_cache_#{NUM_GEMS}_#{FILES_PER_GEM}", ROOT)

$LOAD_PATH.unshift(File.join(ROOT, "lib"))

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def fmt(seconds)
  if seconds < 0.001
    "%.1fµs" % (seconds * 1_000_000)
  elsif seconds < 1
    "%.2fms" % (seconds * 1000)
  else
    "%.3fs" % seconds
  end
end

def median(arr)
  sorted = arr.sort
  sorted[sorted.size / 2]
end

# ---------- Setup ----------

puts "=" * 70
puts "Per-Gem ISeq Bundle Benchmark"
puts "=" * 70
puts "Config: #{NUM_GEMS} gems × #{FILES_PER_GEM} files/gem"
puts

unless File.exist?(File.join(BENCH_DIR, "manifest.rb"))
  system("ruby", File.join(ROOT, "benchmark/setup_fake_gems.rb"),
         NUM_GEMS.to_s, FILES_PER_GEM.to_s, BENCH_DIR) || abort("Failed to generate fake gems")
end
load File.join(BENCH_DIR, "manifest.rb")

# Ensure individual compile cache is warm
puts "Warming individual compile cache..."
FileUtils.rm_rf(CACHE_DIR)
rd, wr = IO.pipe
pid = fork do
  rd.close
  FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
  require "bootsnap"
  # Disable ISeqBundle for this run so we only warm individual cache
  Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)
  # Remove bundle dir so auto-build doesn't happen
  FileUtils.rm_rf(File.join(CACHE_DIR, "bootsnap", "iseq-bundles"))
  FAKE_GEM_NAMES.each { |name| require name }
  wr.write($LOADED_FEATURES.grep(/fake/).size.to_s)
  wr.close
  exit!(0)
end
wr.close
Process.wait(pid)
puts "  Cached #{rd.read.to_i} features"
rd.close
# Remove any auto-built bundles from warmup
FileUtils.rm_rf(File.join(CACHE_DIR, "bootsnap", "iseq-bundles"))
puts

# ---------- Phase 1: Individual cache ----------

puts "-" * 70
puts "Phase 1: Individual compile cache (current bootsnap, no bundles)"
puts "-" * 70

individual_times = RUNS.times.map do |run|
  # Remove bundles each run so we test pure individual cache
  FileUtils.rm_rf(File.join(CACHE_DIR, "bootsnap", "iseq-bundles"))
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
    require "bootsnap"
    Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)
    # Disable auto-build by unsetting the bundle system
    Bootsnap::CompileCache::ISeqBundle.instance_variable_set(:@enabled, false)

    GC.disable
    t0 = clock
    FAKE_GEM_NAMES.each { |name| require name }
    elapsed = clock - t0
    GC.enable
    wr.write(JSON.dump({ elapsed: elapsed, features: $LOADED_FEATURES.size }))
    wr.close
    exit!(0)
  end
  wr.close
  Process.wait(pid)
  result = JSON.parse(rd.read)
  rd.close
  printf "  Run %d: %s (%d features)\n", run + 1, fmt(result["elapsed"]), result["features"]
  result["elapsed"]
end

individual_median = median(individual_times)
puts "  Median: #{fmt(individual_median)}"
puts

# ---------- Phase 2: Per-gem bundles (cold — auto-build on first boot) ----------

puts "-" * 70
puts "Phase 2: Per-gem bundles (cold — auto-building on first require)"
puts "-" * 70

FileUtils.rm_rf(File.join(CACHE_DIR, "bootsnap", "iseq-bundles"))

cold_times = RUNS.times.map do |run|
  FileUtils.rm_rf(File.join(CACHE_DIR, "bootsnap", "iseq-bundles"))
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
    require "bootsnap"
    Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)

    GC.disable
    t0 = clock
    FAKE_GEM_NAMES.each { |name| require name }
    elapsed = clock - t0
    GC.enable

    bundles = Dir.glob(File.join(CACHE_DIR, "bootsnap", "iseq-bundles", "**/*")).count { |f| File.file?(f) }
    wr.write(JSON.dump({ elapsed: elapsed, features: $LOADED_FEATURES.size, bundles: bundles }))
    wr.close
    exit!(0)
  end
  wr.close
  Process.wait(pid)
  result = JSON.parse(rd.read)
  rd.close
  printf "  Run %d: %s (%d features, %d bundles built)\n",
         run + 1, fmt(result["elapsed"]), result["features"], result["bundles"]
  result["elapsed"]
end

cold_median = median(cold_times)
puts "  Median: #{fmt(cold_median)}"
puts

# ---------- Phase 3: Per-gem bundles (warm — bundles pre-built) ----------

puts "-" * 70
puts "Phase 3: Per-gem bundles (warm — bundles already on disk)"
puts "-" * 70

warm_times = RUNS.times.map do |run|
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
    require "bootsnap"
    Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)

    GC.disable
    t0 = clock
    FAKE_GEM_NAMES.each { |name| require name }
    elapsed = clock - t0
    GC.enable
    wr.write(JSON.dump({ elapsed: elapsed, features: $LOADED_FEATURES.size }))
    wr.close
    exit!(0)
  end
  wr.close
  Process.wait(pid)
  result = JSON.parse(rd.read)
  rd.close
  printf "  Run %d: %s (%d features)\n", run + 1, fmt(result["elapsed"]), result["features"]
  result["elapsed"]
end

warm_median = median(warm_times)
puts "  Median: #{fmt(warm_median)}"
puts

# ---------- Summary ----------

puts "=" * 70
puts "Summary"
puts "=" * 70
puts "  Individual cache (current):       #{fmt(individual_median)}"
puts "  Per-gem bundles (cold auto-build): #{fmt(cold_median)}  (%.1fx vs individual)" % [individual_median / cold_median]
puts "  Per-gem bundles (warm):            #{fmt(warm_median)}  (%.1fx vs individual)" % [individual_median / warm_median]
bundles_count = Dir.glob(File.join(CACHE_DIR, "bootsnap", "iseq-bundles", "**/*")).count { |f| File.file?(f) }
bundles_size = Dir.glob(File.join(CACHE_DIR, "bootsnap", "iseq-bundles", "**/*")).select { |f| File.file?(f) }.sum { |f| File.size(f) }
puts "  Bundle files: #{bundles_count}, total #{bundles_size / 1024}KB"
puts "=" * 70
