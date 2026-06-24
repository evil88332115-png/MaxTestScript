#!/usr/bin/env bash
set -euo pipefail

echo "6-6 Network Monitor Packet Loss Rate"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo

install_requirements() {
  local missing=()

  command -v mtr >/dev/null 2>&1 || missing+=(mtr-tiny)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Installing package(s): ${missing[*]}"
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    echo
  fi

  if ! python3 - <<'PY' >/dev/null 2>&1
import pandas
import matplotlib
PY
  then
    echo "Installing Python plotting packages..."
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pandas python3-matplotlib
    echo
  fi
}

install_requirements

python3 - <<'PY'
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def ensure_mtr():
    try:
        subprocess.run(
            ["mtr", "--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        print("'mtr' command found.")
    except (FileNotFoundError, subprocess.CalledProcessError):
        print("'mtr' command not found.")
        print("Please install it with: sudo apt update && sudo apt install -y mtr-tiny")
        sys.exit(1)


def run_mtr(target_ip, count=50):
    cmd = ["mtr", "-rw", "-n", "-c", str(count), target_ip]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.stdout


def parse_mtr_output(output, timestamp):
    lines = output.strip().splitlines()
    data = []

    for line in lines[2:]:
        parts = line.split()
        if len(parts) >= 9:
            hop = parts[0]
            host = parts[1]
            try:
                loss = float(parts[2].replace("%", ""))
                avg_latency = float(parts[4])
            except ValueError:
                loss = 0.0
                avg_latency = 0.0

            data.append(
                {
                    "Timestamp": timestamp,
                    "Hop": hop,
                    "Host": host,
                    "Loss (%)": loss,
                    "Avg Latency (ms)": avg_latency,
                }
            )

    return pd.DataFrame(data)


def save_csv(df, target_ip):
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"mtr_report_{target_ip}_{timestamp}.csv"
    df.to_csv(filename, index=False)
    print(f"CSV saved: {filename}")
    return filename


def plot_graph(df, target_ip):
    if df.empty:
        print("No data collected, skip graph.")
        return

    plt.figure(figsize=(10, 6))
    plt.plot(df["Host"], df["Loss (%)"], marker="o", label="Loss (%)", color="red")
    plt.plot(
        df["Host"],
        df["Avg Latency (ms)"],
        marker="x",
        label="Avg Latency (ms)",
        color="blue",
    )
    plt.xticks(rotation=45, ha="right")
    plt.title(f"Network Loss & Latency to {target_ip}")
    plt.xlabel("Hop Host")
    plt.ylabel("Value")
    plt.legend()
    plt.tight_layout()
    filename = f"mtr_graph_{target_ip}.png"
    plt.savefig(filename)
    print(f"Graph saved: {filename}")
    plt.close()


def plot_summary_graph(all_data, target_ip):
    if all_data.empty:
        print("No data collected, skip summary graph.")
        return

    unique_hosts = all_data["Host"].unique()

    plt.figure(figsize=(12, 6))
    for host in unique_hosts:
        host_data = all_data[all_data["Host"] == host]
        plt.plot(
            host_data["Timestamp"],
            host_data["Avg Latency (ms)"],
            label=f"{host} Latency",
            marker="o",
        )

    plt.xticks(rotation=45)
    plt.title(f"Latency Over Time to {target_ip}")
    plt.xlabel("Timestamp")
    plt.ylabel("Avg Latency (ms)")
    plt.legend()
    plt.tight_layout()
    filename = f"summary_latency_{target_ip}.png"
    plt.savefig(filename)
    print(f"Summary latency graph saved: {filename}")
    plt.close()

    plt.figure(figsize=(12, 6))
    for host in unique_hosts:
        host_data = all_data[all_data["Host"] == host]
        plt.plot(
            host_data["Timestamp"],
            host_data["Loss (%)"],
            label=f"{host} Loss",
            marker="x",
        )

    plt.xticks(rotation=45)
    plt.title(f"Packet Loss Over Time to {target_ip}")
    plt.xlabel("Timestamp")
    plt.ylabel("Loss (%)")
    plt.legend()
    plt.tight_layout()
    filename = f"summary_loss_{target_ip}.png"
    plt.savefig(filename)
    print(f"Summary loss graph saved: {filename}")
    plt.close()


def log_to_file(df, target_ip):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open("network_loss.log", "a", encoding="utf-8") as fh:
        for _, row in df.iterrows():
            log_line = (
                f"{timestamp} {target_ip} {row['Host']} "
                f"Loss={row['Loss (%)']}% Latency={row['Avg Latency (ms)']}ms\n"
            )
            fh.write(log_line)
    print("Log updated: network_loss.log")


def main():
    ensure_mtr()

    target_ip = input("Enter target IP or domain: ").strip()
    if not target_ip:
        print("Invalid input. Target IP/domain is required.")
        return

    try:
        hours = float(input("Enter test duration (in hours): ").strip())
        if hours <= 0:
            raise ValueError
    except ValueError:
        print("Invalid input. Please enter a positive number.")
        return

    end_time = datetime.now() + timedelta(hours=hours)
    interval = 60
    count = 50
    all_data = pd.DataFrame()

    print(f"Starting monitoring for {hours} hour(s)...")
    print(f"MTR command: mtr -rw -n -c {count} {target_ip}")

    while datetime.now() < end_time:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"\nRunning test at {timestamp}")
        output = run_mtr(target_ip, count=count)

        raw_filename = f"mtr_raw_{target_ip}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        Path(raw_filename).write_text(output, encoding="utf-8", errors="replace")
        print(f"Raw MTR saved: {raw_filename}")

        df = parse_mtr_output(output, timestamp)
        all_data = pd.concat([all_data, df], ignore_index=True)
        save_csv(df, target_ip)
        plot_graph(df, target_ip)
        log_to_file(df, target_ip)

        if datetime.now() + timedelta(seconds=interval) < end_time:
            print(f"Waiting {interval // 60} minutes before next test...")
            time.sleep(interval)
        else:
            break

    plot_summary_graph(all_data, target_ip)
    print("Monitoring complete.")


if __name__ == "__main__":
    main()
PY
