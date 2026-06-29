#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="7-1 CoreMark-PRO"
WORK_DIR="${WORK_DIR:-${HOME}}"
REPO_DIR="${REPO_DIR:-${WORK_DIR}/coremark-pro}"
RESULT_DIR="${RESULT_DIR:-${HOME}/7-1_coremark_pro_$(date +%Y%m%d_%H%M%S)}"
LOG_FILE="${RESULT_DIR}/coremark_pro_raw.log"
WORKLOAD_CSV="${RESULT_DIR}/coremark_pro_workloads.csv"
MARK_CSV="${RESULT_DIR}/coremark_pro_mark.csv"
PNG_FILE="${RESULT_DIR}/7-1_coremark_pro.png"
TARGET="${TARGET:-linux64}"
XCMD="${XCMD:--c6}"

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
else
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '%sERROR: required command not found: %s%s\n' "${RED}" "${cmd}" "${RESET}" >&2
    exit 1
  fi
}

read_model() {
  local model_file
  for model_file in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    if [[ -r "${model_file}" ]]; then
      tr -d '\0' < "${model_file}"
      return
    fi
  done
  hostname
}

ensure_matplotlib() {
  if env PYTHONNOUSERSITE=1 python3 - <<'PY' >/dev/null 2>&1
import matplotlib
PY
  then
    return 0
  fi

  echo "python3 matplotlib not found. Installing python3-matplotlib..."
  sudo apt-get update
  sudo apt-get install -y python3-matplotlib
}

prepare_repo() {
  mkdir -p "${WORK_DIR}"

  if [[ -d "${REPO_DIR}/.git" ]]; then
    echo "CoreMark-PRO repo already exists: ${REPO_DIR}"
    return 0
  fi

  if [[ -e "${REPO_DIR}" ]]; then
    printf '%sERROR: %s exists but is not a git repo.%s\n' "${RED}" "${REPO_DIR}" "${RESET}" >&2
    exit 1
  fi

  echo "Cloning CoreMark-PRO..."
  git clone https://github.com/eembc/coremark-pro.git "${REPO_DIR}"
}

parse_and_draw_results() {
  local model="$1"

  env PYTHONNOUSERSITE=1 python3 - "${LOG_FILE}" "${WORKLOAD_CSV}" "${MARK_CSV}" "${PNG_FILE}" "${model}" <<'PY'
import csv
import re
import sys
from pathlib import Path

raw_log = Path(sys.argv[1])
workload_csv = Path(sys.argv[2])
mark_csv = Path(sys.argv[3])
png_file = Path(sys.argv[4])
model = sys.argv[5]

text = raw_log.read_text(errors="ignore").splitlines()

rows = []
marks = []
mode = None
row_re = re.compile(r"^(.+?)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s*$")

for line in text:
    stripped = line.strip()
    if not stripped:
        continue
    if stripped.startswith("Workload Name"):
        mode = "workload"
        continue
    if stripped.startswith("MARK RESULTS TABLE"):
        mode = None
        continue
    if stripped.startswith("Mark Name"):
        mode = "mark"
        continue
    if set(stripped) <= {"-"}:
        continue

    match = row_re.match(line.rstrip())
    if not match:
        continue

    name = match.group(1).strip()
    multicore = float(match.group(2))
    singlecore = float(match.group(3))
    scaling = float(match.group(4))

    if mode == "workload":
        rows.append((name, multicore, singlecore, scaling))
    elif mode == "mark":
        marks.append((name, multicore, singlecore, scaling))

if not rows:
    raise SystemExit("ERROR: no workload result rows parsed from CoreMark-PRO log")

with workload_csv.open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["Workload Name", "MultiCore(iter/s)", "SingleCore(iter/s)", "Scaling"])
    for row in rows:
        writer.writerow(row)

with mark_csv.open("w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["Mark Name", "MultiCore", "SingleCore", "Scaling"])
    for row in marks:
        writer.writerow(row)

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

names = [r[0] for r in rows]
multicore = [r[1] for r in rows]
singlecore = [r[2] for r in rows]
scaling = [r[3] for r in rows]

x = np.arange(len(names))
width = 0.18

fig_width = max(12, len(names) * 1.25)
fig, ax = plt.subplots(figsize=(fig_width, 6.5))
ax.bar(x - width, multicore, width, label="MultiCore", color="#1f77b4")
ax.bar(x, singlecore, width, label="SingleCore", color="#ff7f0e")
ax.bar(x + width, scaling, width, label="Scaling", color="#2ca02c")

model_lower = model.lower()
if "orin nano" in model_lower:
    short_model = "Orin Nano"
elif "orin nx" in model_lower:
    short_model = "Orin NX"
elif "agx orin" in model_lower:
    short_model = "AGX Orin"
else:
    short_model = model
    for prefix in ("NVIDIA Jetson ", "NVIDIA "):
        if short_model.startswith(prefix):
            short_model = short_model[len(prefix):]
title = f"CoreMark-PRO Performance on {short_model}"

ax.set_title(title)
ax.set_ylabel("Performance Value")
ax.set_xticks(x)
ax.set_xticklabels(names, rotation=30, ha="right")
ax.legend()
ax.grid(axis="y", alpha=0.25)
fig.tight_layout()
fig.savefig(png_file, dpi=150)
PY
}

print_summary() {
  echo
  echo "======================================"
  echo "${TEST_NAME} Summary"
  echo "======================================"
  echo "Raw log:      ${LOG_FILE}"
  echo "Workload CSV: ${WORKLOAD_CSV}"
  echo "Mark CSV:     ${MARK_CSV}"
  echo "Chart PNG:    ${PNG_FILE}"
  echo
  if [[ -s "${MARK_CSV}" ]]; then
    column -s, -t "${MARK_CSV}" 2>/dev/null || cat "${MARK_CSV}"
  fi
  echo
  printf '%sRESULT,COREMARK_PRO,7-1,PASS,chart=%s%s\n' "${GREEN}" "${PNG_FILE}" "${RESET}"
}

main() {
  local model rc

  require_cmd git
  require_cmd make
  require_cmd python3
  ensure_matplotlib

  mkdir -p "${RESULT_DIR}"
  model="$(read_model)"

  echo "======================================"
  echo "${TEST_NAME}"
  echo "Host: $(hostname)"
  echo "Date: $(date --iso-8601=seconds)"
  echo "Model: ${model}"
  echo "Repo: ${REPO_DIR}"
  echo "Result directory: ${RESULT_DIR}"
  echo "Command: make TARGET=${TARGET} XCMD='${XCMD}' certify-all"
  echo "======================================"

  prepare_repo

  set +e
  (
    cd "${REPO_DIR}"
    make TARGET="${TARGET}" XCMD="${XCMD}" certify-all
  ) 2>&1 | tee "${LOG_FILE}"
  rc="${PIPESTATUS[0]}"
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    printf '%sRESULT,COREMARK_PRO,7-1,FAIL,rc=%s,log=%s%s\n' "${RED}" "${rc}" "${LOG_FILE}" "${RESET}" >&2
    exit "${rc}"
  fi

  parse_and_draw_results "${model}"
  print_summary
}

main "$@"
