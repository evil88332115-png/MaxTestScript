#!/usr/bin/env python3
import argparse
import csv
import os
import re
from datetime import datetime

import matplotlib

# 在沒有桌面的環境也能存圖，例如 SSH / Jetson console。
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
    for f in os.listdir("."):
        if os.path.isfile(f):
            ext = os.path.splitext(f)[1].lower()
            if ext in ALLOWED_EXTS:
                files.append(f)
    files.sort()
    return files


def choose_file(files):
    if not files:
        print("目前路徑下找不到可用檔案。")
        return None

    print("目前路徑下可選擇的檔案：")
    for i, f in enumerate(files, 1):
        print(f"{i}. {f}")

    while True:
        choice = input("\n請輸入要繪圖的檔案編號：").strip()
        if not choice.isdigit():
            print("請輸入數字。")
            continue
        idx = int(choice)
        if 1 <= idx <= len(files):
            return files[idx - 1]
        print("編號超出範圍，請重新輸入。")


def choose_plot_mode():
    print("\n請選擇要畫的溫度：")
    print("1. CPU 溫度")
    print("2. GPU 溫度")
    print("3. TJ 溫度")
    print("4. CPU + GPU")
    print("5. CPU + TJ")
    print("6. GPU + TJ")
    print("7. 全部 (CPU + GPU + TJ)")

    while True:
        choice = input("請輸入選項 (1/2/3/4/5/6/7)：").strip()
        if choice in INTERACTIVE_MODE_MAP:
            return INTERACTIVE_MODE_MAP[choice]
        print("請輸入 1、2、3、4、5、6 或 7。")


def choose_avg_interval():
    while True:
        value = input("請輸入平均區間（分鐘，0 表示不平均，直接畫原始資料）：").strip()
        try:
            minutes = float(value)
            if minutes >= 0:
                return minutes
            print("請輸入大於等於 0 的數字。")
        except ValueError:
            print("請輸入有效數字。")


def parse_tegrastats_temps(filepath, interval_ms=1000):
    times_min = []
    cpu_temps = []
    gpu_temps = []
    tj_temps = []

    # 支援 drawtemp 原本吃的「MM-DD-YYYY HH:MM:SS」時間戳。
    time_pattern = re.compile(r"(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2})")
    cpu_temp_pattern = re.compile(r"\bcpu@([+-]?\d+(?:\.\d+)?)C", re.IGNORECASE)
    gpu_temp_pattern = re.compile(r"\bgpu@([+-]?\d+(?:\.\d+)?)C", re.IGNORECASE)
    tj_temp_pattern = re.compile(r"\btj@([+-]?\d+(?:\.\d+)?)C", re.IGNORECASE)

    timestamp_rows = []
    sample_idx = 0
    interval_min = float(interval_ms) / 60000.0

    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            cpu_match = cpu_temp_pattern.search(line)
            gpu_match = gpu_temp_pattern.search(line)
            tj_match = tj_temp_pattern.search(line)

            if not (cpu_match or gpu_match or tj_match):
                continue

            tmatch = time_pattern.search(line)
            if tmatch:
                try:
                    ts = datetime.strptime(tmatch.group(1), "%m-%d-%Y %H:%M:%S")
                    timestamp_rows.append(ts)
                    if len(timestamp_rows) == 1:
                        base_time = ts
                    t_min = (ts - base_time).total_seconds() / 60.0
                except ValueError:
                    t_min = sample_idx * interval_min
            else:
                # tegrastats 預設通常不會印時間戳，所以用 sample index + interval 推時間。
                t_min = sample_idx * interval_min

            times_min.append(t_min)
            cpu_temps.append(float(cpu_match.group(1)) if cpu_match else None)
            gpu_temps.append(float(gpu_match.group(1)) if gpu_match else None)
            tj_temps.append(float(tj_match.group(1)) if tj_match else None)
            sample_idx += 1

    if not times_min:
        return None, None, None, None

    return times_min, cpu_temps, gpu_temps, tj_temps


def parse_csv_temps(filepath):
    with open(filepath, "r", encoding="utf-8", errors="ignore", newline="") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            return None, None, None, None
        fields_lower = {name.lower(): name for name in reader.fieldnames}
        seconds_col = fields_lower.get("seconds")
        time_min_col = fields_lower.get("time_min") or fields_lower.get("minutes")
        cpu_col = fields_lower.get("cpu") or fields_lower.get("cpu@") or fields_lower.get("cpu_temp")
        gpu_col = fields_lower.get("gpu") or fields_lower.get("gpu@") or fields_lower.get("gpu_temp")
        tj_col = fields_lower.get("tj") or fields_lower.get("tj@") or fields_lower.get("tj_temp")

        times_min, cpu_temps, gpu_temps, tj_temps = [], [], [], []
        for idx, row in enumerate(reader):
            if seconds_col and row.get(seconds_col, "") != "":
                t = float(row[seconds_col]) / 60.0
            elif time_min_col and row.get(time_min_col, "") != "":
                t = float(row[time_min_col])
            else:
                t = float(idx)

            def cell(col):
                if not col or row.get(col, "") == "":
                    return None
                return float(row[col])

            times_min.append(t)
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
        for t, v in zip(times_min, values):
            if v is not None:
                filtered_times.append(t)
                filtered_values.append(v)
        return filtered_times, filtered_values

    buckets = {}
    for t, v in zip(times_min, values):
        if v is None:
            continue
        bucket_idx = int(t // interval_min)
        buckets.setdefault(bucket_idx, []).append((t, v))

    avg_times = []
    avg_values = []
    for bucket_idx in sorted(buckets.keys()):
        samples = buckets[bucket_idx]
        avg_time = sum(t for t, _ in samples) / len(samples)
        avg_temp = sum(v for _, v in samples) / len(samples)
        avg_times.append(avg_time)
        avg_values.append(avg_temp)
    return avg_times, avg_values


def calc_overlap_ratio(values_a, values_b, tolerance=0.3):
    paired = [(a, b) for a, b in zip(values_a, values_b) if a is not None and b is not None]
    if not paired:
        return 0.0
    overlap_count = sum(1 for a, b in paired if abs(a - b) <= tolerance)
    return overlap_count / len(paired)


def print_basic_stats(name, values):
    filtered = [v for v in values if v is not None]
    if not filtered:
        print(f"{name}: 無資料")
        return
    print(
        f"{name}: 筆數={len(filtered)}, "
        f"最低={min(filtered):.2f}°C, "
        f"最高={max(filtered):.2f}°C, "
        f"平均={sum(filtered) / len(filtered):.2f}°C"
    )


def default_output_name(filename, mode, avg_interval):
    suffix = f"_{mode}_avg.png" if avg_interval > 0 else f"_{mode}.png"
    return os.path.splitext(filename)[0] + suffix


def plot_temps(times_cpu, temps_cpu,
               times_gpu, temps_gpu,
               times_tj, temps_tj,
               filename, mode, avg_interval, out_png=None, show=False):
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
        plt.plot(times_gpu, temps_gpu, linewidth=gpu_style["linewidth"], color=gpu_style["color"], linestyle=gpu_style["linestyle"], alpha=gpu_style["alpha"], zorder=gpu_style["zorder"], label=gpu_style["label"])
        plotted = True

    if "tj" in sensors and temps_tj:
        plt.plot(times_tj, temps_tj, linewidth=tj_style["linewidth"], color=tj_style["color"], linestyle=tj_style["linestyle"], alpha=tj_style["alpha"], zorder=tj_style["zorder"], label=tj_style["label"])
        plotted = True

    if not plotted:
        print("沒有可繪製的資料。")
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
    print(f"\n圖片已儲存：{out_png}")
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
        print(f"\n你選擇的檔案是：{selected}")
        mode = choose_plot_mode()
        avg_interval = choose_avg_interval()
        show = True

    times_min, cpu_temps, gpu_temps, tj_temps = load_temps(selected, interval_ms=args.interval_ms)
    if times_min is None:
        print("解析失敗：找不到有效溫度資料。")
        return 1

    print("\n=== 原始資料統計 ===")
    print_basic_stats("CPU", cpu_temps)
    print_basic_stats("GPU", gpu_temps)
    print_basic_stats("TJ", tj_temps)

    if gpu_temps and tj_temps:
        overlap_ratio = calc_overlap_ratio(gpu_temps, tj_temps, tolerance=0.3)
        print(f"GPU 與 TJ 重疊比例（誤差 ±0.3°C）: {overlap_ratio * 100:.2f}%")
        if overlap_ratio >= 0.95:
            print("提示：GPU 與 TJ 幾乎完全重疊，圖上可能會看起來像只有一條線。")

    cpu_times_avg, cpu_vals_avg = average_by_interval(times_min, cpu_temps, avg_interval)
    gpu_times_avg, gpu_vals_avg = average_by_interval(times_min, gpu_temps, avg_interval)
    tj_times_avg, tj_vals_avg = average_by_interval(times_min, tj_temps, avg_interval)

    print(f"\n平均後資料筆數：CPU {len(cpu_vals_avg)} 筆、GPU {len(gpu_vals_avg)} 筆、TJ {len(tj_vals_avg)} 筆")

    out_png = plot_temps(
        cpu_times_avg, cpu_vals_avg,
        gpu_times_avg, gpu_vals_avg,
        tj_times_avg, tj_vals_avg,
        selected, mode, avg_interval,
        out_png=args.out,
        show=show,
    )
    return 0 if out_png else 1


if __name__ == "__main__":
    raise SystemExit(main())
