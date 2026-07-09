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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${HOME}/3-6Identify"
DOCX_FILE="${OUTPUT_DIR}/3-6_Identify.docx"
mkdir -p "${OUTPUT_DIR}"

DOCX_TEMPLATE="${DOCX_TEMPLATE:-}"
if [[ -z "${DOCX_TEMPLATE}" ]]; then
  for candidate in \
    "${OUTPUT_DIR}/3-6_template.docx" \
    "${SCRIPT_DIR}/3-6_template.docx" \
    "${SCRIPT_DIR}/../3-6_template.docx" \
    "${PWD}/3-6_template.docx"; do
    if [[ -r "${candidate}" ]]; then
      DOCX_TEMPLATE="${candidate}"
      break
    fi
  done
fi

if [[ -z "${DOCX_TEMPLATE}" || ! -r "${DOCX_TEMPLATE}" ]]; then
  die "Word template not found. Put 3-6_template.docx in ${SCRIPT_DIR} or set DOCX_TEMPLATE=/path/to/3-6_template.docx"
fi

printf '%s3-6 Identify%s\n' "${COLOR_TITLE}" "${COLOR_RESET}"
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
    paragraphs = cell.findall("w:p", NS)
    if not paragraphs:
        paragraph = ET.SubElement(cell, f"{{{W_NS}}}p")
    else:
        paragraph = paragraphs[0]
        for extra_paragraph in paragraphs[1:]:
            cell.remove(extra_paragraph)

    run = paragraph.find("w:r", NS)
    run_pr = run.find("w:rPr", NS) if run is not None else None
    for child in list(paragraph):
        paragraph.remove(child)

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


def split_template_commands(command_text):
    text = command_text.replace("\u2013", "-").replace("\u2014", "-")
    commands = []
    for part in re.split(r"(?=\$)", text):
        part = part.strip()
        if not part.startswith("$"):
            continue
        command = part[1:].strip()
        if not command:
            continue
        commands.append(command)
    return commands


def normalize_command(command):
    command = command.strip()
    sudo_prefix = ""
    if command.startswith("sudo "):
        sudo_prefix = "sudo "
        command = command[5:].strip()
    command = re.sub(r"\s+", " ", command)

    if command == "top":
        return "top -b -n 1 | head -n 6"
    if command.startswith("xdpyinfo"):
        return "DISPLAY=${DISPLAY:-:0} xdpyinfo | awk '{print} /^number of screens:/ {exit}'"
    if command == "cat /proc/device-tree/model":
        return "tr -d '\\0' < /proc/device-tree/model"
    if command == "lspci":
        return f"{sudo_prefix}lspci".strip()
    if command.startswith("lspci -vv") and "[" in command:
        return ""
    return f"{sudo_prefix}{command}".strip()


def is_dangerous(command_text, operation_text):
    haystack = f"{command_text} {operation_text}".lower()
    return any(word in haystack for word in ("shutdown", "poweroff", "reboot"))


def run_command(command):
    command = normalize_command(command)
    if not command:
        return ""
    env = os.environ.copy()
    env.setdefault("DISPLAY", ":0")
    if command.startswith("sudo ") and env.get("SUDO_PASSWORD"):
        quoted_password = env["SUDO_PASSWORD"].replace("'", "'\"'\"'")
        shell_command = f"printf '%s\\n' '{quoted_password}' | sudo -S -p '' {command[5:]}"
    else:
        shell_command = command
    proc = subprocess.run(
        shell_command,
        shell=True,
        executable="/bin/bash",
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=20,
    )
    output = proc.stdout.strip()
    if proc.returncode != 0:
        return f"ERROR({proc.returncode}): {output}" if output else f"ERROR({proc.returncode})"
    return output


def read_os_version():
    try:
        with open("/etc/os_version", "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def check_desktop_os_version_file():
    version = read_os_version()
    if not version:
        return "", False
    desktop_path = os.path.join(os.path.expanduser("~"), "Desktop", version)
    return version, os.path.exists(desktop_path)


with zipfile.ZipFile(template_path, "r") as source:
    document_xml = source.read("word/document.xml")

root = ET.fromstring(document_xml)
table = root.find(".//w:tbl", NS)
if table is None:
    raise RuntimeError("Template does not contain a Word table")

rows = table.findall("w:tr", NS)
if not rows:
    raise RuntimeError("Template table is empty")

header = row_texts(rows[0])
try:
    command_index = header.index("Command")
    record_index = header.index("Record")
except ValueError as exc:
    raise RuntimeError("Template must contain Command and Record columns") from exc

operation_index = header.index("Operation") if "Operation" in header else -1

for row in rows[1:]:
    cells = row.findall("w:tc", NS)
    if len(cells) <= max(command_index, record_index):
        continue

    values = row_texts(row)
    command_text = values[command_index] if command_index < len(values) else ""
    operation_text = values[operation_index] if 0 <= operation_index < len(values) else ""

    if is_dangerous(command_text, operation_text):
        set_cell_text(cells[record_index], "OK")
        continue

    if "check the text file exist" in command_text.lower() and "desktop" in command_text.lower():
        version, exists = check_desktop_os_version_file()
        if exists:
            set_cell_text(cells[record_index], version)
        else:
            set_cell_text(cells[record_index], "Failed", color="FF0000")
        continue

    commands = split_template_commands(command_text)
    if not commands:
        set_cell_text(cells[record_index], "OK")
        continue

    outputs = []
    for command in commands:
        output = run_command(command)
        if output:
            outputs.append(output)
    set_cell_text(cells[record_index], "\n".join(outputs) if outputs else "OK")

updated_document = ET.tostring(root, encoding="utf-8", xml_declaration=True)
with zipfile.ZipFile(template_path, "r") as source, zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as target:
    for item in source.infolist():
        content = updated_document if item.filename == "word/document.xml" else source.read(item.filename)
        target.writestr(item, content)

print(f"Generated: {output_path}")
PY
