#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmarks each phase of bootsnap's load path cache initialization and require.
#
# Usage:
#   ruby benchmark/bench_phases.rb [num_gems] [files_per_gem]
#
# Set BOOTSNAP_BENCH_RUNS=N for multiple iterations (default: 5)
# Set BOOTSNAP_BENCH_COLD=1 to also benchmark cold-cache startup
#
# Measures:
#   1. Baseline: Ruby require without bootsnap
#   2. Cold cache: First bootsnap init (scans all dirs)
#   3. Warm cache: Subsequent bootsnap init (loads from cache)
#   4. Per-require lookup time
#   5. Breakdown of warm init: store load, mtime checks, index build

require "fileutils"
require "json"

NUM_GEMS      = Integer(ARGV[0] || ENV.fetch("NUM_GEMS", 300))
FILES_PER_GEM = Integer(ARGV[1] || ENV.fetch("FILES_PER_GEM", 20))
RUNS          = Integer(ENV.fetch("BOOTSNAP_BENCH_RUNS", 3))
# Control which phases run. Default: only warm cache + breakdown (the fast ones).
# Set BENCH_BASELINE=1 to include the slow no-bootsnap baseline (~80s × RUNS).
# Set BENCH_COLD=1 to include cold-cache init.
# Set BENCH_REQUIRE=1 to include per-require timing (~17s × RUNS).
BENCH_BASELINE = ENV.fetch("BENCH_BASELINE", "0") == "1"
BENCH_COLD     = ENV.fetch("BENCH_COLD", "0") == "1"
BENCH_REQUIRE  = ENV.fetch("BENCH_REQUIRE", "0") == "1"

ROOT      = File.expand_path("..", __dir__)
BENCH_DIR = File.expand_path("tmp/fake_gems_#{NUM_GEMS}_#{FILES_PER_GEM}", ROOT)
CACHE_DIR = File.expand_path("tmp/bench_cache_#{NUM_GEMS}_#{FILES_PER_GEM}", ROOT)

$LOAD_PATH.unshift(File.join(ROOT, "lib"))

# ---------- helpers ----------

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def measure
  GC.disable
  t0 = clock
  result = yield
  elapsed = clock - t0
  GC.enable
  [elapsed, result]
end

def clear_cache!
  FileUtils.rm_rf(CACHE_DIR)
  FileUtils.mkdir_p(CACHE_DIR)
end

def fmt(seconds)
  if seconds < 0.001
    format("%.1fµs", seconds * 1_000_000)
  elsif seconds < 1
    format("%.2fms", seconds * 1000)
  else
    format("%.3fs", seconds)
  end
end

def median(arr)
  sorted = arr.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def stats(arr)
  {median: median(arr), min: arr.min, max: arr.max, mean: arr.sum / arr.size.to_f}
end

# ---------- generate gems if needed ----------

$bench_start = clock
puts "=" * 70
puts "Bootsnap Load Path Cache Benchmark"
puts "=" * 70
puts "Config: #{NUM_GEMS} gems × #{FILES_PER_GEM} files/gem = #{NUM_GEMS * (FILES_PER_GEM + 1)} total files"
puts "Runs: #{RUNS} iterations per measurement"
puts

# Generate fake gems
system("ruby", File.join(ROOT, "benchmark/setup_fake_gems.rb"),
       NUM_GEMS.to_s, FILES_PER_GEM.to_s, BENCH_DIR) || abort("Failed to generate fake gems")
puts

load File.join(BENCH_DIR, "manifest.rb")

# ---------- Phase 1: Baseline (no bootsnap) ----------

baseline_stats = nil
if BENCH_BASELINE
  puts "-" * 70
  puts "Phase 1: Baseline require (no bootsnap)"
  puts "-" * 70
  phase_start = clock

  baseline_times = RUNS.times.map do |run|
    # Fork to get clean Ruby state each time
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }

      elapsed, = measure do
        FAKE_GEM_NAMES.each { |name| require name }
      end

      wr.write(elapsed.to_s)
      wr.close
      exit!(0)
    end
    wr.close
    Process.wait(pid)
    result = rd.read.to_f
    rd.close
    printf "  Run %<run>d: %<time>s\n", run: run + 1, time: fmt(result)
    result
  end

  baseline_stats = stats(baseline_times)
  puts "  Median: #{fmt(baseline_stats[:median])}  (phase took #{fmt(clock - phase_start)})"
  puts
else
  puts "Phase 1: Baseline (skipped, set BENCH_BASELINE=1 to enable)"
end # BENCH_BASELINE

# ---------- Phase 2: Cold cache (first bootsnap init) ----------

cold_stats = nil
if BENCH_COLD
  puts "-" * 70
  puts "Phase 2: Bootsnap cold cache (first init, scans all directories)"
  puts "-" * 70

  cold_init_times = RUNS.times.map do |run|
    clear_cache!
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
      require "bootsnap"

      t_init_start = clock
      Bootsnap.setup(
        cache_dir: CACHE_DIR,
        development_mode: false,
        load_path_cache: true,
      )
      t_init_end = clock

      elapsed_total = t_init_end - t_init_start

      wr.write(JSON.dump({
        init: elapsed_total,
        push: 0,
        total: elapsed_total,
      }))
      wr.close
      exit!(0)
    end
    wr.close
    Process.wait(pid)
    result = JSON.parse(rd.read)
    rd.close
    printf "  Run %<run>d: init=%<init>s  push_paths=%<push>s  total=%<total>s\n",
           run: run + 1, init: fmt(result["init"]), push: fmt(result["push"]),
           total: fmt(result["total"])
    result
  end

  cold_stats = stats(cold_init_times.map { |r| r["total"] })
  puts "  Median total: #{fmt(cold_stats[:median])}"
  puts
end

# ---------- Phase 3: Warm cache init ----------

puts "-" * 70
puts "Phase 3: Bootsnap warm cache (subsequent inits, cache populated)"
puts "-" * 70
phase_start = clock

# First, ensure cache is warm by doing one cold run.
# Realistic pattern: Bundler adds all gem paths BEFORE bootsnap setup.
clear_cache!
rd, wr = IO.pipe
pid = fork do
  rd.close
  FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
  require "bootsnap"
  Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)
  FAKE_GEM_NAMES.each { |name| require name }
  wr.write("ok")
  wr.close
  exit!(0)
end
wr.close
Process.wait(pid)
rd.close

warm_init_times = RUNS.times.map do |run|
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    # Realistic: paths already in $LOAD_PATH before bootsnap init
    FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
    require "bootsnap"

    t0 = clock
    Bootsnap.setup(
      cache_dir: CACHE_DIR,
      development_mode: false,
      load_path_cache: true,
    )
    t_setup = clock

    wr.write(JSON.dump({
      setup: t_setup,
      total: t_setup - t0,
    }))
    wr.close
    exit!(0)
  end
  wr.close
  Process.wait(pid)
  result = JSON.parse(rd.read)
  rd.close
  printf "  Run %<run>d: total=%<total>s\n",
         run: run + 1, total: fmt(result["total"])
  result
end

warm_total_stats = stats(warm_init_times.map { |r| r["total"] })
puts "  Median: total=#{fmt(warm_total_stats[:median])}  (phase took #{fmt(clock - phase_start)})"
puts

per_req_us = nil
if BENCH_REQUIRE
  # ---------- Phase 4: Per-require lookup time ----------

  puts "-" * 70
  puts "Phase 4: Per-require lookup time (warm cache, #{NUM_GEMS * (FILES_PER_GEM + 1)} requires)"
  puts "-" * 70
  phase_start = clock

  require_times = RUNS.times.map do |run|
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
      require "bootsnap"
      Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)

      total_requires = 0
      elapsed, = measure do
        FAKE_GEM_NAMES.each do |name|
          require name
          total_requires += 1
        end
      end

      features_loaded = $LOADED_FEATURES.size
      wr.write(JSON.dump({
        elapsed: elapsed,
        features_loaded: features_loaded,
        total_requires: total_requires,
      }))
      wr.close
      exit!(0)
    end
    wr.close
    Process.wait(pid)
    result = JSON.parse(rd.read)
    rd.close
    per_require = result["elapsed"] / result["features_loaded"]
    printf "  Run %<run>d: %<time>s total for %<features>d features (%<per_req>.1fµs/require)\n",
           run: run + 1, time: fmt(result["elapsed"]),
           features: result["features_loaded"], per_req: per_require * 1_000_000
    result
  end

  req_stats = stats(require_times.map { |r| r["elapsed"] })
  features = require_times[0]["features_loaded"]
  per_req_us = (req_stats[:median] / features) * 1_000_000
  puts format(
    "  Median: %<total>s total, %<per_req>.1fµs/require (%<features>d features) (phase took %<phase>s)",
    total: fmt(req_stats[:median]), per_req: per_req_us,
    features: features, phase: fmt(clock - phase_start)
  )
  puts
else
  puts "Phase 4: Per-require (skipped, set BENCH_REQUIRE=1 to enable)"
end

# ---------- Phase 5: Warm init breakdown (instrumented) ----------

puts "-" * 70
puts "Phase 5: Warm init breakdown (instrumented internals)"
puts "-" * 70

breakdown_times = RUNS.times.map do |run|
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    FAKE_LOAD_PATHS.each { |p| $LOAD_PATH.push(p) }
    require "bootsnap"
    require "bootsnap/load_path_cache/store"
    require "bootsnap/load_path_cache/path"
    require "bootsnap/load_path_cache/path_scanner"

    # Instrument Store#load_data
    store_load_time = 0
    original_load = Bootsnap::LoadPathCache::Store.instance_method(:load_data)
    Bootsnap::LoadPathCache::Store.define_method(:load_data) do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = original_load.bind_call(self)
      store_load_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      result
    end

    # Instrument Store#load_index to detect cache hits
    index_cache_hit = false
    index_load_time = 0
    original_load_index = Bootsnap::LoadPathCache::Store.instance_method(:load_index)
    Bootsnap::LoadPathCache::Store.define_method(:load_index) do |fingerprint|
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = original_load_index.bind_call(self, fingerprint)
      index_load_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      index_cache_hit = !result.nil?
      result
    end

    # Instrument Path#entries to measure mtime checks + scanning
    path_entries_time = 0
    path_entries_count = 0
    original_entries = Bootsnap::LoadPathCache::Path.instance_method(:entries)
    Bootsnap::LoadPathCache::Path.define_method(:entries) do |store|
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = original_entries.bind_call(self, store)
      path_entries_time += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      path_entries_count += 1
      result
    end

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Bootsnap.setup(cache_dir: CACHE_DIR, development_mode: false, load_path_cache: true)
    t_setup = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    wr.write(JSON.dump({
      store_load: store_load_time,
      index_load: index_load_time,
      index_cache_hit: index_cache_hit,
      path_entries_total: path_entries_time,
      path_entries_count: path_entries_count,
      total: t_setup - t0,
    }))
    wr.close
    exit!(0)
  end
  wr.close
  Process.wait(pid)
  result = JSON.parse(rd.read)
  rd.close
  hit = result["index_cache_hit"] ? "HIT" : "MISS"
  printf(
    "  Run %<run>d: [%<hit>s] store_load=%<store>s  index_load=%<idx>s  " \
    "path_entries=%<paths>s (%<count>d paths)  total=%<total>s\n",
    run: run + 1, hit: hit,
    store: fmt(result["store_load"]),
    idx: fmt(result["index_load"]),
    paths: fmt(result["path_entries_total"]),
    count: result["path_entries_count"],
    total: fmt(result["total"])
  )
  result
end

puts
puts "  Breakdown medians:"
%w[store_load index_load path_entries_total total].each do |key|
  s = stats(breakdown_times.map { |r| r[key] })
  puts format("    %-25<key>s %<val>s", key: "#{key}:", val: fmt(s[:median]))
end
hits = breakdown_times.count { |r| r["index_cache_hit"] }
puts "    Index cache hits:         #{hits}/#{breakdown_times.size}"

# ---------- Summary ----------

puts
puts "=" * 70
puts "Summary for #{NUM_GEMS} gems × #{FILES_PER_GEM} files"
puts "=" * 70
puts "  Baseline (no bootsnap):     #{baseline_stats ? fmt(baseline_stats[:median]) : '(skipped)'}"
puts "  Cold cache init:            #{cold_stats ? fmt(cold_stats[:median]) : '(skipped)'}"
puts "  Warm cache init:            #{fmt(warm_total_stats[:median])}"
puts "  Per-require (warm):         #{per_req_us ? format('%.1fµs', per_req_us) : '(skipped)'}"
puts
puts "  Warm init is overhead on every boot even when nothing changed."
puts "  Optimization target: reduce warm init from #{fmt(warm_total_stats[:median])} toward zero."
puts "=" * 70
puts "Total benchmark time: #{fmt(clock - $bench_start)}"
