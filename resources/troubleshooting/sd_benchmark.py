#!/usr/bin/env python3

import os
import time
import hashlib
import subprocess
import argparse
import math

# Module-level defaults
SOURCE_DIR = "/home/ark"
TARGET_DIR = "/roms"
DEFAULT_FILE_SIZE_MB = 100
DEFAULT_NUM_RUNS = 3

def generate_random_file(filename, size_mb):
    print(f"Generating {size_mb} MB random file at {filename}...")
    subprocess.run([
        "dd", "if=/dev/urandom", f"of={filename}",
        "bs=1M", f"count={size_mb}", "conv=fsync", "status=progress"
    ], check=True)
    os.sync()

def drop_caches():
    try:
        with open("/proc/sys/vm/drop_caches", "w") as f:
            f.write("3\n")
        print("System caches dropped.")
    except PermissionError:
        print("Warning: Run as sudo for accurate read tests (cache drop).")
    except FileNotFoundError:
        print("Warning: Cache drop not available.")

def compute_hash(filename):
    sha256 = hashlib.sha256()
    with open(filename, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            sha256.update(block)
    return sha256.hexdigest()

def mean(values):
    return sum(values) / len(values) if values else 0.0

def stddev(values):
    if not values or len(values) < 2:
        return 0.0
    avg = mean(values)
    variance = sum((x - avg) ** 2 for x in values) / (len(values) - 1)
    return math.sqrt(variance)

def benchmark_copy(src, dst, label, file_size_mb, num_runs):
    times = []
    for run in range(1, num_runs + 1):
        print(f"{label} Run {run}/{num_runs}...")
        drop_caches()
        start = time.perf_counter()
        subprocess.run(["cp", src, dst], check=True)
        os.sync()
        end = time.perf_counter()
        elapsed = end - start
        times.append(elapsed)
        speed = file_size_mb / elapsed if elapsed > 0 else 0
        print(f"  Time: {elapsed:.2f} s | Speed: {speed:.2f} MB/s")

    if times:
        avg_time = mean(times)
        std_time = stddev(times)
        avg_speed = file_size_mb / avg_time if avg_time > 0 else 0
        print(f"{label} Average: {avg_time:.2f} s (std: {std_time:.2f}) | Avg Speed: {avg_speed:.2f} MB/s")
    print("")

def main():
    # Read current module defaults into locals
    current_size = DEFAULT_FILE_SIZE_MB
    current_runs = DEFAULT_NUM_RUNS

    parser = argparse.ArgumentParser(description="SD Card Benchmark – RK3326 / dArkOS")
    parser.add_argument("--size", type=int, default=current_size, help="File size in MB")
    parser.add_argument("--runs", type=int, default=current_runs, help="Number of runs")
    args = parser.parse_args()

    # Now use the parsed values (locals)
    file_size_mb = args.size
    num_runs = args.runs

    random_file   = os.path.join(SOURCE_DIR, "random_test.bin")
    copy_to_sd    = os.path.join(TARGET_DIR,  "random_test_copy.bin")
    copy_back     = os.path.join(SOURCE_DIR, "random_test_back.bin")

    os.makedirs(SOURCE_DIR, exist_ok=True)
    os.makedirs(TARGET_DIR, exist_ok=True)

    print("Benchmark Setup:")
    print(f"  File Size: {file_size_mb} MB | Runs: {num_runs}")
    print(f"  Target (SD?): {TARGET_DIR}")
    subprocess.run(["df", "-h", TARGET_DIR])
    print("")

    generate_random_file(random_file, file_size_mb)
    orig_hash = compute_hash(random_file)

    benchmark_copy(random_file, copy_to_sd,    "Write (to SD)", file_size_mb, num_runs)
    benchmark_copy(copy_to_sd,    copy_back,   "Read (from SD)", file_size_mb, num_runs)

    back_hash = compute_hash(copy_back)
    print("Integrity:", "OK (hashes match)" if orig_hash == back_hash else "FAIL (hashes differ!)")

    print("\nCleaning up...")
    for f in [random_file, copy_to_sd, copy_back]:
        if os.path.exists(f):
            try:
                os.remove(f)
            except:
                pass
    os.sync()

    print("Benchmark complete. Compare before/after DTB GPIO/LED changes.")

if __name__ == "__main__":
    main()