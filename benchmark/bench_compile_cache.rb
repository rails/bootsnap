#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmarks the bundled compile cache vs individual file cache.
#
# Usage:
#   ruby benchmark/bench_compile_cache.rb [num_gems] [files_per_gem]
#
# Measures the time to require all gems (which exercises the compile cache).
# Compares: individual cache files vs bundled cache (single file, in-memory).

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
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

# ---------- Setup ----------

puts "=" * 70
puts "Compile Cache Bundle Benchmark"
puts "=" * 70
puts "Config: #{NUM_GEMS} gems × #{FILES_PER_GEM} files/gem"
puts

# Generate fake gems if needed
unless File.exist?(File.join(BENCH_DIR, "manifest.rb"))
  system("ruby", File.join(ROOT, "benchmark/setup_fake_gems.rb"),
         NUM_GEMS.to_s, FILES_PER_GEM.to_s, BENCH_DIR) || abort("Failed to generate fake gems")
end
load File.join(BENCH_DIR, "manifest.rb")

# Ensure compile cache is populated by doing one full boot
puts "Warming compile cache..."
FileUtils.rm_rf(CACHE_DIR)
rd, wr = IO.pipe
pid = fork do
  rd.close
  FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
  require "bootsnap"
  Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)
  FAKE_GEM_NAMES.each { |name| require name }
  wr.write($LOADED_FEATURES.grep(/fake/).size.to_s)
  wr.close
  exit!(0)
end
wr.close
Process.wait(pid)
features_cached = rd.read.to_i
rd.close
puts "  Cached #{features_cached} features"
puts

# ---------- Phase 1: Individual cache files (current behavior) ----------

puts "-" * 70
puts "Phase 1: Individual compile cache files (current bootsnap)"
puts "-" * 70

individual_times = RUNS.times.map do |run|
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

individual_median = median(individual_times)
puts "  Median: #{fmt(individual_median)}"
puts

# ---------- Build the bundle ----------

puts "-" * 70
puts "Building ISeq bundle..."
puts "-" * 70

rd, wr = IO.pipe
pid = fork do
  rd.close
  FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
  require "bootsnap"
  Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)

  # First require everything to populate $LOADED_FEATURES
  FAKE_GEM_NAMES.each { |name| require name }

  # Now build the bundle from $LOADED_FEATURES
  require "bootsnap/compile_cache/iseq_bundle"
  source_paths = $LOADED_FEATURES.select { |f| f.end_with?(".rb") }

  # Use the actual compile cache dir that Bootsnap.setup creates
  compile_cache_dir = "#{CACHE_DIR}/bootsnap/compile-cache"

  t0 = clock
  result = Bootsnap::CompileCache::ISeqBundle.build!(compile_cache_dir, source_paths: source_paths)
  elapsed = clock - t0

  wr.write(JSON.dump({
    elapsed: elapsed,
    entries: result[:entries],
    data_size: result[:data_size],
    path: result[:path],
  }))
  wr.close
  exit!(0)
end
wr.close
Process.wait(pid)
build_result = JSON.parse(rd.read)
rd.close
puts "  Built #{build_result['entries']} entries, #{build_result['data_size'] / 1024}KB data"
puts "  Build time: #{fmt(build_result['elapsed'])}"
puts "  Path: #{build_result['path']}"
puts

# ---------- Phase 2: Bundled compile cache ----------

puts "-" * 70
puts "Phase 2: Bundled compile cache (single file, in-memory)"
puts "-" * 70

bundle_times = RUNS.times.map do |run|
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
    require "bootsnap"
    Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)

    bundle_loaded = defined?(Bootsnap::CompileCache::ISeqBundle) && Bootsnap::CompileCache::ISeqBundle.loaded?

    GC.disable
    t0 = clock
    FAKE_GEM_NAMES.each { |name| require name }
    elapsed = clock - t0
    GC.enable

    wr.write(JSON.dump({ elapsed: elapsed, features: $LOADED_FEATURES.size, bundle_loaded: bundle_loaded }))
    wr.close
    exit!(0)
  end
  wr.close
  Process.wait(pid)
  result = JSON.parse(rd.read)
  rd.close
  bundle_status = result["bundle_loaded"] ? "BUNDLE" : "NO BUNDLE"
  printf "  Run %d: [%s] %s (%d features)\n", run + 1, bundle_status, fmt(result["elapsed"]), result["features"]
  result["elapsed"]
end

bundle_median = median(bundle_times)
puts "  Median: #{fmt(bundle_median)}"
puts

# ---------- Phase 3: Bundled + skip_validation (production/readonly mode) ----------

puts "-" * 70
puts "Phase 3: Bundled + skip_validation (production mode, no stat per file)"
puts "-" * 70

nostat_times = RUNS.times.map do |run|
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
    require "bootsnap"
    Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true, readonly: true)

    bundle_loaded = defined?(Bootsnap::CompileCache::ISeqBundle) && Bootsnap::CompileCache::ISeqBundle.loaded?

    GC.disable
    t0 = clock
    FAKE_GEM_NAMES.each { |name| require name }
    elapsed = clock - t0
    GC.enable

    wr.write(JSON.dump({ elapsed: elapsed, features: $LOADED_FEATURES.size, bundle_loaded: bundle_loaded }))
    wr.close
    exit!(0)
  end
  wr.close
  Process.wait(pid)
  result = JSON.parse(rd.read)
  rd.close
  bundle_status = result["bundle_loaded"] ? "BUNDLE+NOSTAT" : "NO BUNDLE"
  printf "  Run %d: [%s] %s (%d features)\n", run + 1, bundle_status, fmt(result["elapsed"]), result["features"]
  result["elapsed"]
end

nostat_median = median(nostat_times)
puts "  Median: #{fmt(nostat_median)}"
puts

# ---------- Summary ----------

puts "=" * 70
puts "Summary"
puts "=" * 70
puts "  Individual cache:          #{fmt(individual_median)}"
puts "  Bundled cache:             #{fmt(bundle_median)}  (%.1fx)" % [individual_median / bundle_median]
puts "  Bundled + no stat (prod):  #{fmt(nostat_median)}  (%.1fx)" % [individual_median / nostat_median]
puts "=" * 70
