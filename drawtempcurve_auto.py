#!/usr/bin/env python3
import argparse
import csv
import os
import re
from datetime import datetime

import matplotlib

if os.environ.get("DISPLAY", "") == "":
    matplotlib.use("Agg")

import matplotlib.pyplot as plt


ALLOWED_EXTS = {".log", ".txt", ".csv"}

MODE_MAP = {
    "cpu": {"cpu"},
    "gpu": {"gpu"},
    "tj": {"tj"},
    "cpu_gpu": {"cpu", "gpu"},
    "cpu_tj": {"cpu", "tj"},
    "gpu_tj": {"gpu", "tj"},
    "all": {"cpu", "gpu", "tj"},
}

INTERACTIVE_MODE_MAP = {
    "1": "cpu",
    "2": "gpu",
    "3": "tj",
    "4": "cpu_gpu",
    "5": "cpu_tj",
    "6": "gpu_tj",
    "7": "all",
}


def list_files():
    files = []
    for name in os.listdir("."):
        if os.path.isfile(name) and os.path.splitext(name)[1].lower() in ALLOWED_EXTS:
            files.append(name)
    return sorted(files)


def choose_file(files):
    if not files:
        print("No supported .log/.txt/.csv files found in current directory.")
        return None

    print("Available files:")
    for i, name in enumerate(files, 1):
        print(f"{i}. {name}")

    while True:
        choice = input("\nSelect file number: ").strip()
        if not choice.isdigit():
            print("Please enter a valid number.")
            continue
        index = int(choice)
        if 1 <= index <= len(files):
            return files[index - 1]
        print("Selection out of range. Please try again.")


def choose_plot_mode():
    print("\nSelect temperature plot mode:")
    print("1. CPU temperature")
    print("2. GPU temperature")
    print("3. TJ temperature")
    print("4. CPU + GPU")
    print("5. CPU + TJ")
    print("6. GPU + TJ")
    print("7. All (CPU + GPU + TJ)")

    while True:
        choice = input("Select mode (1/2/3/4/5/6/7): ").strip()
        if choice in INTERACTIVE_MODE_MAP:
            return INTERACTIVE_MODE_MAP[choice]
        print("Please enter a number from 1 to 7.")


def choose_avg_interval():
    while True:
        value = input("Average interval in minutes, 0 = raw data: ").strip()
        try:
            minutes = float(value)
            if minutes >= 0:
                return minutes
            print("Please enter a number >= 0.")
        except ValueError:
            print("Please enter a valid number.")


def parse_tegrastats_temps(filepath, interval_ms=1000):
    times_min = []
    cpu_temps = []
    gpu_temps = []
    tj_temps = []

    time_pattern = re.compile(r"(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2})")
    cpu_temp_pattern = re.compile(r"\bcpu@([+-]?\d+(?:\.\d+)?)C", re.IGNORECASE)
    gpu_temp_pattern = re.compile(r"\bgpu@([+-]?\d+(?:\.\d+)?)C", re.IGNORECASE)
    tj_temp_pattern = re.compile(r"\btj@([+-]?\d+(?:\.\d+)?)C", re.IGNORECASE)

    base_time = None
    sample_idx = 0
    interval_min = float(interval_ms) / 60000.0

    with open(filepath, "r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            cpu_match = cpu_temp_pattern.search(line)
            gpu_match = gpu_temp_pattern.search(line)
            tj_match = tj_temp_pattern.search(line)

            if not (cpu_match or gpu_match or tj_match):
                continue

            time_match = time_pattern.search(line)
            if time_match:
                try:
                    timestamp = datetime.strptime(time_match.group(1), "%m-%d-%Y %H:%M:%S")
                    if base_time is None:
                        base_time = timestamp
                    time_min = (timestamp - base_time).total_seconds() / 60.0
                except ValueError:
                    time_min = sample_idx * interval_min
            else:
                time_min = sample_idx * interval_min

            times_min.append(time_min)
            cpu_temps.append(float(cpu_match.group(1)) if cpu_match else None)
            gpu_temps.append(float(gpu_match.group(1)) if gpu_match else None)
            tj_temps.append(float(tj_match.group(1)) if tj_match else None)
            sample_idx += 1

    if not times_min:
        return None, None, None, None
    return times_min, cpu_temps, gpu_temps, tj_temps


def parse_csv_temps(filepath):
    with open(filepath, "r", encoding="utf-8", errors="ignore", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            return None, None, None, None

        fields_lower = {name.lower(): name for name in reader.fieldnames}
        seconds_col = fields_lower.get("seconds")
        time_min_col = fields_lower.get("time_min") or fields_lower.get("minutes")
        cpu_col = fields_lower.get("cpu") or fields_lower.get("cpu@") or fields_lower.get("cpu_temp")
        gpu_col = fields_lower.get("gpu") or fields_lower.get("gpu@") or fields_lower.get("gpu_temp")
        tj_col = fields_lower.get("tj") or fields_lower.get("tj@") or fields_lower.get("tj_temp")

        times_min, cpu_temps, gpu_temps, tj_temps = [], [], [], []

        for index, row in enumerate(reader):
            if seconds_col and row.get(seconds_col, "") != "":
                time_min = float(row[seconds_col]) / 60.0
            elif time_min_col and row.get(time_min_col, "") != "":
                time_min = float(row[time_min_col])
            else:
                time_min = float(index)

            def cell(column):
                if not column or row.get(column, "") == "":
                    return None
                return float(row[column])

            times_min.append(time_min)
            cpu_temps.append(cell(cpu_col))
            gpu_temps.append(cell(gpu_col))
            tj_temps.append(cell(tj_col))

    if not times_min:
        return None, None, None, None
    return times_min, cpu_temps, gpu_temps, tj_temps


def load_temps(filepath, interval_ms):
    if os.path.splitext(filepath)[1].lower() == ".csv":
        parsed = parse_csv_temps(filepath)
        if parsed[0] is not None:
            return parsed
    return parse_tegrastats_temps(filepath, interval_ms=interval_ms)


def average_by_interval(times_min, values, interval_min):
    if interval_min <= 0:
        filtered_times = []
        filtered_values = []
        for time_min, value in zip(times_min, values):
            if value is not None:
                filtered_times.append(time_min)
                filtered_values.append(value)
        return filtered_times, filtered_values

    buckets = {}
    for time_min, value in zip(times_min, values):
        if value is None:
            continue
        bucket_idx = int(time_min // interval_min)
        buckets.setdefault(bucket_idx, []).append((time_min, value))

    avg_times = []
    avg_values = []
    for bucket_idx in sorted(buckets.keys()):
        samples = buckets[bucket_idx]
        avg_times.append(sum(time_min for time_min, _ in samples) / len(samples))
        avg_values.append(sum(value for _, value in samples) / len(samples))
    return avg_times, avg_values


def calc_overlap_ratio(values_a, values_b, tolerance=0.3):
    paired = [(a, b) for a, b in zip(values_a, values_b) if a is not None and b is not None]
    if not paired:
        return 0.0
    return sum(1 for a, b in paired if abs(a - b) <= tolerance) / len(paired)


def print_basic_stats(name, values):
    filtered = [value for value in values if value is not None]
    if not filtered:
        print(f"{name}: no data")
        return
    print(
        f"{name}: samples={len(filtered)}, "
        f"min={min(filtered):.2f}°C, "
        f"max={max(filtered):.2f}°C, "
        f"avg={sum(filtered) / len(filtered):.2f}°C"
    )


def default_output_name(filename, mode, avg_interval):
    suffix = f"_{mode}_avg.png" if avg_interval > 0 else f"_{mode}.png"
    return os.path.splitext(filename)[0] + suffix


def plot_temps(
    times_cpu,
    temps_cpu,
    times_gpu,
    temps_gpu,
    times_tj,
    temps_tj,
    filename,
    mode,
    avg_interval,
    out_png=None,
    show=False,
):
    plt.figure(figsize=(12, 6))
    plotted = False

    gpu_tj_overlap_ratio = 0.0
    if temps_gpu and temps_tj:
        min_len = min(len(temps_gpu), len(temps_tj))
        gpu_tj_overlap_ratio = calc_overlap_ratio(temps_gpu[:min_len], temps_tj[:min_len], tolerance=0.3)

    gpu_style = {
        "color": "tab:orange",
        "linewidth": 2.0,
        "linestyle": "-",
        "alpha": 1.0,
        "zorder": 3,
        "label": "GPU Temp",
    }
    tj_style = {
        "color": "tab:green",
        "linewidth": 2.0,
        "linestyle": "-",
        "alpha": 0.9,
        "zorder": 2,
        "label": "TJ Temp",
    }

    if gpu_tj_overlap_ratio >= 0.95:
        gpu_style["linestyle"] = "--"
        gpu_style["linewidth"] = 2.2
        tj_style["alpha"] = 0.75
        tj_style["linewidth"] = 1.8

    sensors = MODE_MAP.get(mode, MODE_MAP["cpu_gpu"])

    if "cpu" in sensors and temps_cpu:
        plt.plot(times_cpu, temps_cpu, linewidth=2.0, color="tab:blue", linestyle="-", alpha=0.95, zorder=1, label="CPU Temp")
        plotted = True

    if "gpu" in sensors and temps_gpu:
        plt.plot(
            times_gpu,
            temps_gpu,
            linewidth=gpu_style["linewidth"],
            color=gpu_style["color"],
            linestyle=gpu_style["linestyle"],
            alpha=gpu_style["alpha"],
            zorder=gpu_style["zorder"],
            label=gpu_style["label"],
        )
        plotted = True

    if "tj" in sensors and temps_tj:
        plt.plot(
            times_tj,
            temps_tj,
            linewidth=tj_style["linewidth"],
            color=tj_style["color"],
            linestyle=tj_style["linestyle"],
            alpha=tj_style["alpha"],
            zorder=tj_style["zorder"],
            label=tj_style["label"],
        )
        plotted = True

    if not plotted:
        print("No plottable temperature data.")
        return None

    title_suffix = f" ({avg_interval} min average)" if avg_interval > 0 else ""
    plt.title("Temperature Over Time" + title_suffix)
    plt.xlabel("Time (minutes)")
    plt.ylabel("Temperature (°C)")
    plt.grid(True, linestyle="--", alpha=0.4)
    plt.legend()
    plt.tight_layout()

    if out_png is None:
        out_png = default_output_name(filename, mode, avg_interval)

    plt.savefig(out_png, dpi=150)
    print(f"\nImage saved: {out_png}")
    if show:
        plt.show()
    else:
        plt.close()
    return out_png


def main():
    parser = argparse.ArgumentParser(description="Draw Jetson tegrastats temperature curve. Default: CPU + GPU.")
    parser.add_argument("--file", "-f", help="tegrastats .log/.txt or parsed .csv file")
    parser.add_argument("--mode", "-m", choices=sorted(MODE_MAP.keys()), default="cpu_gpu", help="default: cpu_gpu")
    parser.add_argument("--avg-min", "--avg", type=float, default=0.0, help="average interval in minutes; 0 means raw data")
    parser.add_argument("--interval-ms", type=float, default=1000.0, help="tegrastats interval when log has no timestamp")
    parser.add_argument("--out", "-o", help="output PNG path")
    parser.add_argument("--show", action="store_true", help="show window after saving")
    args = parser.parse_args()

    if args.file:
        selected = args.file
        mode = args.mode
        avg_interval = args.avg_min
        show = args.show
    else:
        files = list_files()
        selected = choose_file(files)
        if not selected:
            return 1
        print(f"\nSelected file: {selected}")
        mode = choose_plot_mode()
        avg_interval = choose_avg_interval()
        show = True

    times_min, cpu_temps, gpu_temps, tj_temps = load_temps(selected, interval_ms=args.interval_ms)
    if times_min is None:
        print("Parse failed: no valid temperature data found.")
        return 1

    print("\n=== Raw Data Statistics ===")
    print_basic_stats("CPU", cpu_temps)
    print_basic_stats("GPU", gpu_temps)
    print_basic_stats("TJ", tj_temps)

    if gpu_temps and tj_temps:
        overlap_ratio = calc_overlap_ratio(gpu_temps, tj_temps, tolerance=0.3)
        print(f"GPU and TJ overlap ratio (tolerance ±0.3°C): {overlap_ratio * 100:.2f}%")
        if overlap_ratio >= 0.95:
            print("Note: GPU and TJ almost overlap; the plot may look like only one line.")

    cpu_times_avg, cpu_vals_avg = average_by_interval(times_min, cpu_temps, avg_interval)
    gpu_times_avg, gpu_vals_avg = average_by_interval(times_min, gpu_temps, avg_interval)
    tj_times_avg, tj_vals_avg = average_by_interval(times_min, tj_temps, avg_interval)

    print(f"\nAveraged data points: CPU {len(cpu_vals_avg)}, GPU {len(gpu_vals_avg)}, TJ {len(tj_vals_avg)}")

    out_png = plot_temps(
        cpu_times_avg,
        cpu_vals_avg,
        gpu_times_avg,
        gpu_vals_avg,
        tj_times_avg,
        tj_vals_avg,
        selected,
        mode,
        avg_interval,
        out_png=args.out,
        show=show,
    )
    return 0 if out_png else 1


if __name__ == "__main__":
    raise SystemExit(main())
