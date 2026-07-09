#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  COLOR_TITLE=$'\033[1;36m'
  COLOR_ERROR=$'\033[1;31m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_TITLE=""
  COLOR_ERROR=""
  COLOR_RESET=""
fi

die() {
  printf '%sERROR: %s%s\n' "${COLOR_ERROR}" "$*" "${COLOR_RESET}" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"
}

need_cmd python3
need_cmd xrandr

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${HOME}/4-5Resolution"
DOCX_FILE="${OUTPUT_DIR}/4-5_Resolution.docx"
mkdir -p "${OUTPUT_DIR}"

DOCX_TEMPLATE="${DOCX_TEMPLATE:-}"
if [[ -z "${DOCX_TEMPLATE}" ]]; then
  for candidate in \
    "${OUTPUT_DIR}/4-5_template.docx" \
    "${SCRIPT_DIR}/4-5_template.docx" \
    "${SCRIPT_DIR}/../4-5_template.docx" \
    "${PWD}/4-5_template.docx"; do
    if [[ -r "${candidate}" ]]; then
      DOCX_TEMPLATE="${candidate}"
      break
    fi
  done
fi

if [[ -z "${DOCX_TEMPLATE}" || ! -r "${DOCX_TEMPLATE}" ]]; then
  die "Word template not found. Put 4-5_template.docx in ${SCRIPT_DIR} or set DOCX_TEMPLATE=/path/to/4-5_template.docx"
fi

printf '%s4-5 Resolution%s\n' "${COLOR_TITLE}" "${COLOR_RESET}"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Template: ${DOCX_TEMPLATE}"
echo "Word: ${DOCX_FILE}"
echo

python3 - "${DOCX_TEMPLATE}" "${DOCX_FILE}" <<'PY'
import copy
import os
import re
import subprocess
import sys
import time
import zipfile
import xml.etree.ElementTree as ET

template_path = sys.argv[1]
output_path = sys.argv[2]

NS = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
W_NS = NS["w"]
ET.register_namespace("w", W_NS)


def local_name(tag):
    return tag.rsplit("}", 1)[-1]


def cell_text(cell):
    parts = []
    for elem in cell.iter():
        name = local_name(elem.tag)
        if name == "t":
            parts.append(elem.text or "")
        elif name == "br":
            parts.append("\n")
    return "".join(parts).strip()


def row_texts(row):
    return [cell_text(cell) for cell in row.findall("w:tc", NS)]


def set_cell_text(cell, value, color=None):
    first_run = cell.find(".//w:r", NS)
    run = first_run
    run_pr = run.find("w:rPr", NS) if run is not None else None

    for child in list(cell):
        if child.tag != f"{{{W_NS}}}tcPr":
            cell.remove(child)

    paragraph = ET.SubElement(cell, f"{{{W_NS}}}p")

    run = ET.SubElement(paragraph, f"{{{W_NS}}}r")
    if run_pr is not None:
        run.append(copy.deepcopy(run_pr))
    if color:
        run_pr = run.find("w:rPr", NS)
        if run_pr is None:
            run_pr = ET.Element(f"{{{W_NS}}}rPr")
            run.insert(0, run_pr)
        for old_color in run_pr.findall("w:color", NS):
            run_pr.remove(old_color)
        color_node = ET.SubElement(run_pr, f"{{{W_NS}}}color")
        color_node.set(f"{{{W_NS}}}val", color)

    lines = str(value).splitlines() or [""]
    for index, line in enumerate(lines):
        if index:
            ET.SubElement(run, f"{{{W_NS}}}br")
        text_node = ET.SubElement(run, f"{{{W_NS}}}t")
        if line[:1].isspace() or line[-1:].isspace():
            text_node.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        text_node.text = line


def normalize_mode(value):
    return value.strip().lower().replace("x", "x")


def clean_cell(value):
    return value.replace("\u3000", "").strip()


def run_shell(command, timeout=15):
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")
    proc = subprocess.run(
        command,
        shell=True,
        executable="/bin/bash",
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout.strip()


def xrandr_output():
    _, output = run_shell("xrandr", timeout=10)
    return output


def current_mode_rate(xrandr_text, output_name):
    lines = xrandr_text.splitlines()
    for index, line in enumerate(lines):
        if line.startswith(output_name + " connected"):
            match = re.search(r"\b(\d+x\d+)\+", line)
            mode = match.group(1) if match else ""
            for mode_line in lines[index + 1:]:
                if not mode_line.startswith("   "):
                    break
                if "*" in mode_line:
                    tokens = mode_line.split()
                    active_mode = tokens[0]
                    active_rate = ""
                    for token in tokens[1:]:
                        if "*" in token:
                            active_rate = token.replace("*", "").replace("+", "")
                            break
                    return mode or active_mode, active_rate
            return mode, ""
    return "", ""


def is_mode_rate_available(xrandr_text, mode, rate):
    wanted_mode = normalize_mode(mode)
    mode_line = None
    for line in xrandr_text.splitlines():
        stripped = line.strip()
        if stripped.lower().startswith(wanted_mode + " "):
            mode_line = stripped
            break
    if not mode_line:
        return False
    return re.search(rf"(?<!\d){re.escape(rate)}(?!\d)", mode_line) is not None


def supported_rates_for_mode(xrandr_text, mode):
    wanted_mode = normalize_mode(mode)
    for line in xrandr_text.splitlines():
        stripped = line.strip()
        if not stripped.lower().startswith(wanted_mode + " "):
            continue

        rates = []
        for token in stripped.split()[1:]:
            rate = token.replace("*", "").replace("+", "")
            if re.fullmatch(r"\d+(?:\.\d+)?", rate):
                rates.append(rate)
        return rates
    return []


with zipfile.ZipFile(template_path, "r") as source:
    document_xml = source.read("word/document.xml")

root = ET.fromstring(document_xml)
tables = root.findall(".//w:tbl", NS)
if not tables:
    raise RuntimeError("Template does not contain a Word table")

table = tables[0]
rows = table.findall("w:tr", NS)
recording_cell = None
recording_sections = []
current_output = "HDMI-0"
initial_xrandr = xrandr_output()
initial_mode, initial_rate = current_mode_rate(initial_xrandr, current_output)

for candidate_table in tables:
    candidate_rows = candidate_table.findall("w:tr", NS)
    for row_index, row in enumerate(candidate_rows):
        values = row_texts(row)
        if not values or values[0] != "Recording":
            continue
        for next_row in candidate_rows[row_index + 1:]:
            for cell in next_row.findall("w:tc", NS):
                if "Resolution and Frequency" in cell_text(cell):
                    recording_cell = cell
                    break
            if recording_cell is not None:
                break
        break
    if recording_cell is not None:
        break

for row_index, row in enumerate(rows):
    values = row_texts(row)
    if not values:
        continue

    if values[0].startswith("HDMI"):
        current_output = values[0]
        continue

    command_text = values[0] if values else ""
    if "xrandr --output" not in command_text:
        continue

    cells = row.findall("w:tc", NS)
    if len(values) < 3 or len(cells) < 3:
        continue

    previous_row = row_texts(rows[row_index - 1]) if row_index > 0 else []
    mode = clean_cell(previous_row[1]) if len(previous_row) > 1 else ""
    if not mode:
        continue

    set_cell_text(cells[0], f"$ xrandr --verbose\n$ xrandr --output {current_output} --mode {mode} -r  [ refresh rate ]\n$ xrandr")

    available_text = xrandr_output()
    supported_rates = supported_rates_for_mode(available_text, mode)
    previous_cells = rows[row_index - 1].findall("w:tc", NS) if row_index > 0 else []
    rate_slots = max(0, min(len(previous_cells) - 2, len(cells) - 1))

    for slot in range(rate_slots):
        rate_cell_index = slot + 2
        result_cell_index = slot + 1
        if slot < len(supported_rates):
            set_cell_text(previous_cells[rate_cell_index], supported_rates[slot])
        else:
            set_cell_text(previous_cells[rate_cell_index], "")
            set_cell_text(cells[result_cell_index], "")

    if not supported_rates:
        if len(cells) > 1:
            set_cell_text(cells[1], "Failed", color="FF0000")
        recording_sections.append(f"{mode} is not listed by xrandr on {current_output}")
        continue

    for slot, rate in enumerate(supported_rates[:rate_slots]):
        result_cell_index = slot + 1

        mode_arg = normalize_mode(mode)
        command = f"xrandr --output {current_output} --mode {mode_arg} -r {rate}"
        returncode, output = run_shell(command, timeout=15)
        time.sleep(0.5)
        after = xrandr_output()
        if returncode == 0:
            set_cell_text(cells[result_cell_index], "OK")
            recording_sections.append(f"$ {command}\n{after}")
        else:
            set_cell_text(cells[result_cell_index], "Failed", color="FF0000")
            recording_sections.append(f"$ {command}\nERROR({returncode}): {output}\n{after}")
        available_text = after

if recording_cell is not None:
    if initial_mode and initial_rate:
        restore_command = f"xrandr --output {current_output} --mode {initial_mode} -r {initial_rate}"
        returncode, output = run_shell(restore_command, timeout=15)
        restored = xrandr_output()
        if returncode == 0:
            recording_sections.append(f"$ {restore_command}\n{restored}")
        else:
            recording_sections.append(f"$ {restore_command}\nERROR({returncode}): {output}\n{restored}")

    recording_text = "Resolution and Frequency\n" + "\n\n".join(recording_sections)
    set_cell_text(recording_cell, recording_text)

updated_document = ET.tostring(root, encoding="utf-8", xml_declaration=True)
with zipfile.ZipFile(template_path, "r") as source, zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as target:
    for item in source.infolist():
        content = updated_document if item.filename == "word/document.xml" else source.read(item.filename)
        target.writestr(item, content)

print(f"Generated: {output_path}")
PY
