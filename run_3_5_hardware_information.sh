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

run_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif [[ -n "${SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "${SUDO_PASSWORD}" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"
}

need_cmd lshw
need_cmd python3

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LSHW_JSON="$(mktemp)"
GLX_INFO="$(mktemp)"
GLX_RAW="$(mktemp)"
trap 'rm -f "${LSHW_JSON}" "${GLX_INFO}" "${GLX_RAW}"' EXIT
OUTPUT_DIR="${HOME}/3-5"
DOCX_FILE="${OUTPUT_DIR}/hardware_information.docx"
mkdir -p "${OUTPUT_DIR}"

DOCX_TEMPLATE="${DOCX_TEMPLATE:-}"
if [[ -z "${DOCX_TEMPLATE}" ]]; then
  for candidate in \
    "${OUTPUT_DIR}/lshw_template.docx" \
    "${SCRIPT_DIR}/lshw_template.docx" \
    "${SCRIPT_DIR}/lshw.docx" \
    "${SCRIPT_DIR}/../lshw.docx" \
    "${PWD}/lshw.docx"; do
    if [[ -r "${candidate}" ]]; then
      DOCX_TEMPLATE="${candidate}"
      break
    fi
  done
fi

if [[ -z "${DOCX_TEMPLATE}" || ! -r "${DOCX_TEMPLATE}" ]]; then
  die "Word template not found. Put lshw.docx at ${OUTPUT_DIR}/lshw_template.docx or set DOCX_TEMPLATE=/path/to/lshw.docx"
fi

printf '%s3-5 Hardware Information%s\n' "${COLOR_TITLE}" "${COLOR_RESET}"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo "Source: sudo lshw -json"
echo "Word: ${DOCX_FILE}"
echo "Template: ${DOCX_TEMPLATE}"
echo

if ! command -v glxinfo >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || die "apt-get is not installed; cannot install mesa-utils"
  echo "Installing mesa-utils for glxinfo..."
  run_sudo apt-get install -y mesa-utils
  echo
fi

command -v glxinfo >/dev/null 2>&1 || die "glxinfo is still not available after installing mesa-utils"

run_sudo lshw -json > "${LSHW_JSON}"
DISPLAY="${DISPLAY:-:0}" glxinfo > "${GLX_RAW}" 2>/dev/null
awk '
  /^name of display:/ {print; next}
  /^display: .* screen:/ {print; next}
  /^direct rendering:/ {print; next}
  /^server glx vendor string:/ {print; next}
  /^server glx version string:/ {print; exit}
' "${GLX_RAW}" > "${GLX_INFO}"

if [[ ! -s "${GLX_INFO}" ]]; then
  die "Unable to read glxinfo output. Make sure DISPLAY=:0 is available."
fi

OUTPUT_MODE="${1:---wrap}"
case "${OUTPUT_MODE}" in
  --wrap) ;;
  --wide) ;;
  *)
    die "Unknown option: ${OUTPUT_MODE}. Use --wrap or --wide."
    ;;
esac

python3 - "${LSHW_JSON}" "${GLX_INFO}" "${OUTPUT_MODE}" "${DOCX_FILE}" "${DOCX_TEMPLATE}" <<'PY'
import copy
import json
import math
import re
import sys
import textwrap
import zipfile
import xml.etree.ElementTree as ET

path = sys.argv[1]
glx_path = sys.argv[2]
output_mode = sys.argv[3]
docx_path = sys.argv[4]
template_path = sys.argv[5]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

roots = data if isinstance(data, list) else [data]
rows = []


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value if item not in (None, "")]
    return [str(value)]


def text(value, default="-"):
    if value is None:
        return default
    if isinstance(value, list):
        value = ", ".join(str(item) for item in value if item not in (None, ""))
    value = str(value).strip()
    return value if value else default


def flatten(nodes):
    for node in nodes:
        yield node
        children = node.get("children") or []
        yield from flatten(children)


nodes = list(flatten(roots))


def first_node(match):
    for node in nodes:
        if match(node):
            return node
    return None


def add(class_name, device, description, businfo="-"):
    rows.append([
        text(class_name),
        text(device),
        text(description),
        text(businfo),
    ])


def preferred_logical(node, kind=None):
    values = as_list(node.get("logicalname"))
    if not values:
        return node.get("id")

    if kind == "network":
        return next((item for item in values if not item.startswith("/dev/")), values[0])
    if kind == "input":
        return next((item for item in values if re.fullmatch(r"input\d+", item)), values[0])
    if kind == "audio":
        return next((item for item in values if re.fullmatch(r"card\d+", item)), values[0])
    if kind == "display":
        return next((item for item in values if item.startswith("/dev/fb")), values[0])
    if kind == "storage":
        return next((item for item in values if item.startswith("/dev/")), values[0])
    if kind == "usb":
        return next((item for item in values if re.fullmatch(r"(usb|input)\d+", item)), values[0])
    return values[0]


def size_bytes(node):
    value = node.get("size", node.get("capacity"))
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def fmt_mib(value):
    if value is None:
        return "-"
    return f"{int(value / 1024 / 1024)}MiB"


def fmt_kib_or_mib(value):
    if value is None:
        return "-"
    if value >= 1024 * 1024:
        mib = value / 1024 / 1024
        return f"{mib:.0f}MiB" if mib.is_integer() else f"{mib:.1f}MiB"
    kib = value / 1024
    return f"{kib:.0f}KiB" if kib.is_integer() else f"{kib:.1f}KiB"


def fmt_gb(value):
    if value is None:
        return "-"
    gb = value / 1000 / 1000 / 1000
    return f"{gb:.0f}GB" if gb >= 10 else f"{gb:.1f}GB"


def fmt_gib(value):
    if value is None:
        return "-"
    gib = value / 1024 / 1024 / 1024
    return f"{gib:.0f}GiB" if gib >= 10 else f"{gib:.1f}GiB"


def fmt_volume_size(value):
    if value is None:
        return "-"
    if value >= 1024 * 1024 * 1024:
        return fmt_gib(value)
    return fmt_mib(value)


def descendant_size(node, class_name):
    sizes = [
        size_bytes(child)
        for child in flatten(node.get("children") or [])
        if child.get("class") == class_name and size_bytes(child)
    ]
    return max(sizes) if sizes else None


system = first_node(lambda n: n.get("class") == "system")
if system:
    add("System", "-", system.get("product") or system.get("description"), "-")

processor = first_node(
    lambda n: n.get("class") == "processor"
    and n.get("product")
    and str(n.get("product")).lower() not in {"cpu", "cpu-map", "idle-states"}
    and "cache" not in str(n.get("product")).lower()
)
if processor:
    add("Processor", "-", processor.get("product") or processor.get("description"), processor.get("businfo"))

cpu_nodes = [
    node for node in nodes
    if node.get("class") == "processor"
    and str(node.get("product", "")).lower() == "cpu"
    and re.fullmatch(r"cpu@\d+", str(node.get("businfo", "")))
]
if cpu_nodes:
    businfos = sorted({node.get("businfo") for node in cpu_nodes}, key=lambda x: int(x.split("@", 1)[1]))
    add("CPU Cores", "cpu", f"cpu (x{len(businfos)})", ", ".join(businfos))
elif processor and isinstance(processor.get("configuration"), dict):
    cores = processor["configuration"].get("cores") or processor["configuration"].get("enabledcores")
    if cores:
        add("CPU Cores", "cpu", f"cpu (x{cores})", processor.get("businfo"))

main_memory = first_node(
    lambda n: n.get("class") == "memory"
    and str(n.get("description", "")).lower() == "system memory"
)
if main_memory:
    add("Main Memory", "-", f"{fmt_mib(size_bytes(main_memory))} System Memory", "-")

cache_nodes = [
    node for node in nodes
    if node.get("class") == "memory"
    and "cache" in str(node.get("description", "")).lower()
    and size_bytes(node)
]
cache_summary = {}
for node in cache_nodes:
    label = str(node.get("description", "Cache Memory")).strip()
    cache_summary.setdefault((label, size_bytes(node)), 0)
    cache_summary[(label, size_bytes(node))] += 1
if cache_summary:
    parts = []
    for (label, value), count in sorted(cache_summary.items(), key=lambda item: (item[0][0], item[0][1])):
        suffix = f" (x{count})" if count > 1 else ""
        parts.append(f"{fmt_kib_or_mib(value)} {label}{suffix}")
    add("Cache Memory", "-", "; ".join(parts), "-")

storage_nodes = [
    node for node in nodes
    if node.get("class") in {"storage", "volume"}
    and (node.get("logicalname") or node.get("businfo"))
]
volumes = []
for node in storage_nodes:
    device = preferred_logical(node, "storage")
    description = node.get("description")
    if node.get("class") == "storage":
        size = fmt_gb(size_bytes(node) or descendant_size(node, "disk"))
        product = node.get("product") or description
        if product and str(product).lower().endswith("ssd"):
            product = f"{str(product)[:-3].rstrip()} Drive"
        description = f"{size} {product}" if size != "-" else product
    elif node.get("class") == "volume":
        volumes.append(node)
        continue
    add("Storage", device, description, node.get("businfo"))

main_volumes = []
other_volumes = []
for node in volumes:
    logicals = as_list(node.get("logicalname"))
    if "/" in logicals:
        main_volumes.append(node)
    else:
        other_volumes.append(node)

for node in main_volumes:
    size = fmt_volume_size(size_bytes(node))
    description = f"{size} {node.get('description')}" if size != "-" else node.get("description")
    add("Storage", preferred_logical(node, "storage"), description, node.get("businfo"))

if len(other_volumes) > 3:
    devices = [preferred_logical(node, "storage") for node in other_volumes]
    businfos = [str(node.get("businfo")) for node in other_volumes if node.get("businfo")]
    device = f"{devices[0]} - {devices[-1]}" if devices else "-"
    if len(devices) >= 2:
        first_match = re.fullmatch(r"(.+p)\d+", devices[0])
        last_match = re.fullmatch(r"(.+p)(\d+)", devices[-1])
        if first_match and last_match and first_match.group(1) == last_match.group(1):
            device = f"{devices[0]} - p{last_match.group(2)}"
    businfo = f"{businfos[0]} - {businfos[-1]}" if businfos else "-"
    add("Storage", device, "Various data partitions and volumes", businfo)
else:
    for node in other_volumes:
        size = fmt_volume_size(size_bytes(node))
        description = f"{size} {node.get('description')}" if size != "-" else node.get("description")
        add("Storage", preferred_logical(node, "storage"), description, node.get("businfo"))

for node in nodes:
    if node.get("class") != "network":
        continue
    device = preferred_logical(node, "network")
    description = node.get("product") or node.get("description")
    add("Network Interfaces", device, description, node.get("businfo"))

for node in nodes:
    businfo = str(node.get("businfo", ""))
    if not businfo.startswith("usb@"):
        continue
    logical = preferred_logical(node, "usb")
    description = node.get("product") or node.get("description")
    add("USB Devices", logical, description, node.get("businfo"))

for node in nodes:
    class_name = node.get("class")
    logicals = as_list(node.get("logicalname"))
    description = node.get("product") or node.get("description")
    if class_name == "multimedia":
        add("Audio/Multimedia", preferred_logical(node, "audio"), description, node.get("businfo"))
    elif class_name == "display" or (class_name != "network" and any(item.startswith("/dev/fb") for item in logicals)):
        add("Display", preferred_logical(node, "display"), description, node.get("businfo"))
    elif class_name == "input":
        add("Input Devices", preferred_logical(node, "input"), description, node.get("businfo"))

headers = ["Class", "Device", "Description", "Bus Info"]
glx_headers = ["Class", "Description", "Unitly", "GLX Version"]
with open(glx_path, "r", encoding="utf-8") as glx_file:
    glx_version_text = glx_file.read().strip()
glx_rows = [[
    "glxinfo",
    "Nvidia Graphics version",
    "$ sudo apt-get install mesa-utils\n$ glxinfo",
    glx_version_text,
]]

def write_docx_from_template(template, output):
    ns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    w_ns = ns["w"]
    ET.register_namespace("w", w_ns)

    with zipfile.ZipFile(template, "r") as source:
        document_xml = source.read("word/document.xml")

    root = ET.fromstring(document_xml)
    def set_cell_text(cell, value):
        paragraphs = cell.findall("w:p", ns)
        if not paragraphs:
            paragraph = ET.SubElement(cell, f"{{{w_ns}}}p")
        else:
            paragraph = paragraphs[0]
            for extra_paragraph in paragraphs[1:]:
                cell.remove(extra_paragraph)

        run = paragraph.find("w:r", ns)
        if run is None:
            run = ET.SubElement(paragraph, f"{{{w_ns}}}r")

        run_pr = run.find("w:rPr", ns)
        for child in list(paragraph):
            paragraph.remove(child)
        if run_pr is not None:
            run = ET.SubElement(paragraph, f"{{{w_ns}}}r")
            run.append(copy.deepcopy(run_pr))
        else:
            run = ET.SubElement(paragraph, f"{{{w_ns}}}r")

        text = str(value)
        lines = text.splitlines() or [""]
        for index, line in enumerate(lines):
            if index:
                ET.SubElement(run, f"{{{w_ns}}}br")
            text_node = ET.SubElement(run, f"{{{w_ns}}}t")
            if line[:1].isspace() or line[-1:].isspace():
                text_node.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
            text_node.text = line

    def set_row_text(row, values):
        cells = row.findall("w:tc", ns)
        if len(cells) < len(values):
            raise RuntimeError("Template data row has fewer cells than output columns")
        for cell, value in zip(cells, values):
            set_cell_text(cell, value)

    def fill_table(table, table_headers, table_rows_data):
        table_rows = table.findall("w:tr", ns)
        if len(table_rows) < 2:
            raise RuntimeError("Template table must contain one header row and one data row")

        header_row = table_rows[0]
        data_template_row = table_rows[1]
        for old_row in table_rows[1:]:
            table.remove(old_row)

        set_row_text(header_row, table_headers)
        for row_values in table_rows_data:
            new_row = copy.deepcopy(data_template_row)
            set_row_text(new_row, row_values)
            table.append(new_row)

    def fill_single_table_with_glx(table):
        table_rows = table.findall("w:tr", ns)
        if len(table_rows) < 4:
            raise RuntimeError("Template table must contain hardware and GLX sections")

        hardware_header_template = table_rows[0]
        hardware_data_template = table_rows[1]
        glx_header_template = table_rows[-2]
        glx_data_template = table_rows[-1]

        for old_row in table_rows:
            table.remove(old_row)

        new_header = copy.deepcopy(hardware_header_template)
        set_row_text(new_header, headers)
        table.append(new_header)

        for row_values in rows:
            new_row = copy.deepcopy(hardware_data_template)
            set_row_text(new_row, row_values)
            table.append(new_row)

        new_glx_header = copy.deepcopy(glx_header_template)
        set_row_text(new_glx_header, glx_headers)
        table.append(new_glx_header)

        for row_values in glx_rows:
            new_row = copy.deepcopy(glx_data_template)
            set_row_text(new_row, row_values)
            table.append(new_row)

    tables = root.findall(".//w:tbl", ns)
    if not tables:
        raise RuntimeError("Template does not contain a Word table")

    if len(tables) >= 2:
        fill_table(tables[0], headers, rows)
        fill_table(tables[1], glx_headers, glx_rows)
    else:
        fill_single_table_with_glx(tables[0])

    updated_document = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    with zipfile.ZipFile(template, "r") as source, zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as target:
        for item in source.infolist():
            content = updated_document if item.filename == "word/document.xml" else source.read(item.filename)
            target.writestr(item, content)


write_docx_from_template(template_path, docx_path)

if output_mode == "--wide":
    widths = [len(header) for header in headers]
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))

    line = "  ".join("-" * width for width in widths)
    print("  ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print(line)
    for row in rows:
        print("  ".join(row[index].ljust(widths[index]) for index in range(len(headers))))
else:
    widths = [18, 28, 48, 32]

    def wrap_cell(value, width):
        value = str(value)
        if not value:
            return [""]
        return textwrap.wrap(
            value,
            width=width,
            break_long_words=False,
            break_on_hyphens=False,
        ) or [""]

    def print_row(row):
        wrapped = [wrap_cell(row[index], widths[index]) for index in range(len(widths))]
        height = max(len(cell) for cell in wrapped)
        for line_index in range(height):
            parts = []
            for column_index, cell_lines in enumerate(wrapped):
                part = cell_lines[line_index] if line_index < len(cell_lines) else ""
                parts.append(part.ljust(widths[column_index]))
            print("  ".join(parts).rstrip())

    print_row(headers)
    print_row(["-" * width for width in widths])
    for row in rows:
        print_row(row)
PY
