#!/usr/bin/env python3
"""Custom hardware-aware test runner for NVIDIA cuda-samples v12.5.

The v12.5 release predates NVIDIA's repository-wide run_tests.py.  This
runner discovers binaries produced by the legacy Makefiles and invokes each
sample's own ``testrun`` recipe when it actually contains commands, otherwise
its ``run`` recipe.  Potentially unsuitable groups are skipped by default and
can be enabled explicitly.
"""

from __future__ import annotations

import argparse
import csv
import fnmatch
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


GRAPHICS_SOURCE = re.compile(
    r"(?:#\s*include\s*[<\"](?:GL/|GLFW/|vulkan/|EGL/|GLES)|"
    r"\b(?:glutInit|glfwInit|vkCreateInstance|eglInitialize)\s*\()",
    re.IGNORECASE,
)
MULTIGPU_NAME = re.compile(
    r"(?:MultiGPU|MultiDevice|CrossGPU|P2P|_MGPU)", re.IGNORECASE
)
MPI_NAME = re.compile(r"(?:^|simple)MPI", re.IGNORECASE)
SPECIAL_NAME = re.compile(
    r"(?:^cuDLA|NvSci|NvMedia|IPC|EGLStream|EGLSync)", re.IGNORECASE
)
NONWINDOW_GRAPHICS = frozenset(
    {
        "EGLStream_CUDA_CrossGPU",
        "EGLStream_CUDA_Interop",
        "EGLSync_CUDAEvent_Interop",
        "simpleGLES_EGLOutput",
    }
)
WAIVE_TEXT = re.compile(
    r"(?:waiv(?:e|ed|ing)|not supported on|unsupported platform|"
    r"no cuda capable device|requires (?:at least|two|2)|"
    r"(?:two|2) gpus? (?:are )?required|only one gpu detected)",
    re.IGNORECASE,
)
FAIL_TEXT = re.compile(r"(?:Result\s*=\s*FAIL|Test failed)", re.IGNORECASE)


@dataclass
class Sample:
    name: str
    source_dir: Path
    binary: Path
    target: str
    group: str
    reason: str = ""


@dataclass
class Result:
    name: str
    status: str
    group: str
    target: str
    return_code: int | None
    seconds: float
    log: str
    reason: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run cuda-samples v12.5 sequentially with logs and skips."
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="cuda-samples v12.5 repository root (default: script directory)",
    )
    parser.add_argument(
        "--bin",
        dest="bin_dir",
        type=Path,
        help="compiled binary directory (default: bin/aarch64/linux/release)",
    )
    parser.add_argument("--output", type=Path, help="output directory")
    parser.add_argument("--timeout", type=int, default=120, help="seconds per sample")
    parser.add_argument(
        "--name",
        action="append",
        default=[],
        help="only names matching this shell pattern; repeatable",
    )
    parser.add_argument(
        "--group",
        action="append",
        choices=("safe", "graphics", "multigpu", "mpi", "special"),
        default=[],
        help="only this classification group; repeatable",
    )
    parser.add_argument("--dry-run", action="store_true", help="list decisions only")
    parser.add_argument("--include-graphics", action="store_true")
    parser.add_argument(
        "--include-nonwindow-graphics",
        action="store_true",
        help="also run headless EGL/direct-display samples in the graphics group",
    )
    parser.add_argument(
        "--graphics-duration",
        type=int,
        metavar="SECONDS",
        help=(
            "maximum seconds for interactive graphics samples without testrun; "
            "samples with an official testrun still exit cleanly on their own"
        ),
    )
    parser.add_argument("--include-multigpu", action="store_true")
    parser.add_argument("--include-mpi", action="store_true")
    parser.add_argument("--include-special", action="store_true")
    parser.add_argument(
        "--use-run",
        action="store_true",
        help="always use run instead of a non-empty testrun recipe",
    )
    return parser.parse_args()


def recipe_lines(makefile: Path, target: str) -> list[str]:
    lines = makefile.read_text(encoding="utf-8", errors="replace").splitlines()
    found = False
    recipe: list[str] = []
    target_re = re.compile(rf"^{re.escape(target)}\s*:")
    other_target_re = re.compile(r"^[^#\s][^=]*:")
    for line in lines:
        if not found:
            if target_re.match(line):
                found = True
            continue
        if other_target_re.match(line):
            break
        if line.startswith("\t") and line.strip():
            recipe.append(line.strip())
    return recipe


def linked_libraries(binary: Path) -> str:
    try:
        completed = subprocess.run(
            ["ldd", str(binary)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
        )
        return completed.stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def source_uses_graphics(source_dir: Path) -> bool:
    for pattern in ("*.cpp", "*.cc", "*.c", "*.cu", "*.h", "*.hpp"):
        for path in source_dir.glob(pattern):
            try:
                if GRAPHICS_SOURCE.search(path.read_text(encoding="utf-8", errors="ignore")):
                    return True
            except OSError:
                continue
    return False


def classify(name: str, binary: Path, source_dir: Path) -> tuple[str, str]:
    libraries = linked_libraries(binary)
    if source_uses_graphics(source_dir):
        return "graphics", "source uses a graphics/display API"
    if MULTIGPU_NAME.search(name):
        return "multigpu", "requires or targets multiple GPUs/peer access"
    if MPI_NAME.search(name) or re.search(r"libmpi", libraries, re.IGNORECASE):
        return "mpi", "requires an MPI launch/runtime context"
    if SPECIAL_NAME.search(name):
        return "special", "uses DLA, IPC, EGL stream, NvSci, or NvMedia facilities"
    return "safe", "single-GPU/headless candidate"


def discover(repo: Path, bin_dir: Path, force_run: bool) -> tuple[list[Sample], list[str]]:
    binaries = {
        path.name: path.resolve()
        for path in sorted(bin_dir.iterdir())
        if path.is_file() and os.access(path, os.X_OK)
    }
    samples: list[Sample] = []
    matched: set[str] = set()
    source_root = repo / "Samples" if (repo / "Samples").is_dir() else repo / "cpp"
    source_dirs = {
        path.parent for path in source_root.rglob("Makefile")
    } | {
        path.parent for path in source_root.rglob("CMakeLists.txt")
    }
    for source_dir in sorted(source_dirs):
        name = source_dir.name
        binary = binaries.get(name)
        if binary is None:
            continue
        makefile = source_dir / "Makefile"
        if makefile.is_file():
            run_recipe = recipe_lines(makefile, "run")
            test_recipe = recipe_lines(makefile, "testrun")
            if not run_recipe and not test_recipe:
                continue
            target = "run" if force_run or not test_recipe else "testrun"
        else:
            target = "binary"
        group, reason = classify(name, binary, source_dir)
        samples.append(Sample(name, source_dir.resolve(), binary, target, group, reason))
        matched.add(name)
    return samples, sorted(set(binaries) - matched)


def selected(name: str, patterns: Iterable[str]) -> bool:
    patterns = list(patterns)
    return not patterns or any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns)


def skip_reason(sample: Sample, args: argparse.Namespace) -> str | None:
    if sample.group == "graphics":
        if not args.include_graphics:
            return "graphics disabled (use --include-graphics)"
        if sample.name in NONWINDOW_GRAPHICS and not args.include_nonwindow_graphics:
            return "no normal desktop window (use --include-nonwindow-graphics)"
        if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
            return "no DISPLAY or WAYLAND_DISPLAY"
    if sample.group == "multigpu" and not args.include_multigpu:
        return "multi-GPU disabled (use --include-multigpu)"
    if sample.group == "mpi" and not args.include_mpi:
        return "MPI disabled (use --include-mpi)"
    if sample.group == "special" and not args.include_special:
        return "special platform test disabled (use --include-special)"
    return None


def status_from_output(return_code: int, output: str) -> tuple[str, str]:
    if WAIVE_TEXT.search(output):
        return "WAIVED", "sample reported unsupported/unavailable requirements"
    if return_code == 0 and not FAIL_TEXT.search(output):
        return "PASS", ""
    if FAIL_TEXT.search(output):
        return "FAIL", "sample output reported failure"
    return "FAIL", f"make returned {return_code}"


def managed_window_ids(env: dict[str, str]) -> set[str]:
    if shutil.which("wmctrl") is None or not env.get("DISPLAY"):
        return set()
    try:
        completed = subprocess.run(
            ["wmctrl", "-l"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return {
        line.split()[0].lower()
        for line in completed.stdout.splitlines()
        if line.split() and line.split()[0].startswith("0x")
    }


def close_process_group_windows(
    pgid: int, env: dict[str, str], windows_before: set[str]
) -> int:
    """Request WM_DELETE for X11 windows owned by processes in a group."""
    if shutil.which("xdotool") is None or not env.get("DISPLAY"):
        return 0
    try:
        listing = subprocess.run(
            ["ps", "-eo", "pid=,pgid="],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0
    pids: list[str] = []
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == str(pgid):
            pids.append(fields[0])
    windows: set[str] = managed_window_ids(env) - windows_before
    for pid in pids:
        found = subprocess.run(
            ["xdotool", "search", "--pid", pid],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
        windows.update(item for item in found.stdout.split() if item.isdigit())
    for window in windows:
        subprocess.run(
            ["xdotool", "windowclose", window],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    return len(windows)


def run_sample(
    sample: Sample, args: argparse.Namespace, logs_dir: Path, env: dict[str, str]
) -> Result:
    log_path = logs_dir / f"{sample.name}.log"
    command = (
        [str(sample.binary)]
        if sample.target == "binary"
        else ["make", "-s", sample.target, "SMS=87"]
    )
    timeout = (
        args.graphics_duration
        if sample.group == "graphics"
        and args.graphics_duration is not None
        else args.timeout
    )
    duration_run = sample.group == "graphics" and args.graphics_duration is not None
    windows_before = managed_window_ids(env) if duration_run else set()
    start = time.monotonic()
    process = subprocess.Popen(
            command,
            cwd=sample.source_dir,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    try:
        output, _ = process.communicate(timeout=timeout)
        elapsed = time.monotonic() - start
        log_path.write_text(
            f"cwd: {sample.source_dir}\ncommand: {' '.join(command)}\n\n{output}",
            encoding="utf-8",
        )
        status, reason = status_from_output(process.returncode, output)
        return Result(
            sample.name,
            status,
            sample.group,
            sample.target,
            process.returncode,
            elapsed,
            str(log_path),
            reason,
        )
    except subprocess.TimeoutExpired:
        closed_windows = (
            close_process_group_windows(process.pid, env, windows_before)
            if duration_run
            else 0
        )
        gracefully_closed = False
        if closed_windows:
            try:
                output, _ = process.communicate(timeout=5)
                gracefully_closed = True
            except subprocess.TimeoutExpired:
                pass
        # Some EGL samples have no managed X11 window but finish naturally.
        # Give those their normal timeout budget rather than tearing down an
        # active GPU channel at the requested display duration.
        if duration_run and not closed_windows:
            remaining = max(args.timeout - timeout, 5)
            try:
                output, _ = process.communicate(timeout=remaining)
                elapsed = time.monotonic() - start
                log_path.write_text(
                    f"cwd: {sample.source_dir}\ncommand: {' '.join(command)}\n\n{output}",
                    encoding="utf-8",
                )
                status, reason = status_from_output(process.returncode, output)
                return Result(
                    sample.name,
                    status,
                    sample.group,
                    sample.target,
                    process.returncode,
                    elapsed,
                    str(log_path),
                    reason or "no managed window; sample exited naturally",
                )
            except subprocess.TimeoutExpired:
                pass
        if not gracefully_closed:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            if not gracefully_closed:
                output, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
        elapsed = time.monotonic() - start
        log_path.write_text(
            f"cwd: {sample.source_dir}\ncommand: {' '.join(command)}\n\n"
            f"STOPPED after {timeout}s\n{output}",
            encoding="utf-8",
        )
        stop_method = (
            f"closed {closed_windows} window(s) through the window manager"
            if gracefully_closed
            else "forced process-group stop (no responsive window was found)"
        )
        return Result(
            sample.name,
            "RAN" if duration_run else "TIMEOUT",
            sample.group,
            sample.target,
            None,
            elapsed,
            str(log_path),
            (
                f"ran for requested {timeout}s; {stop_method}"
                if duration_run
                else f"exceeded {timeout}s"
            ),
        )
    except KeyboardInterrupt:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise


def write_reports(output_dir: Path, results: list[Result], metadata: dict[str, object]) -> None:
    csv_path = output_dir / "summary.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(asdict(results[0]).keys()) if results else [
            "name", "status", "group", "target", "return_code", "seconds", "log", "reason"
        ])
        writer.writeheader()
        for result in results:
            row = asdict(result)
            row["seconds"] = f"{result.seconds:.3f}"
            writer.writerow(row)
    payload = {"metadata": metadata, "results": [asdict(item) for item in results]}
    (output_dir / "summary.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8"
    )


def print_summary(results: list[Result]) -> None:
    order = ["PASS", "RAN", "FAIL", "WAIVED", "SKIPPED", "TIMEOUT"]
    counts = {status: sum(item.status == status for item in results) for status in order}
    print("\nTest Summary")
    for status in order:
        print(f"  {status:8s} {counts[status]:3d}")
    print(f"  {'TOTAL':8s} {len(results):3d}")
    noteworthy = [item for item in results if item.status in {"FAIL", "TIMEOUT"}]
    if noteworthy:
        print("\nFailures/timeouts:")
        for item in noteworthy:
            print(f"  {item.name}: {item.status} ({item.reason})")


def main() -> int:
    args = parse_args()
    if args.graphics_duration is not None and args.graphics_duration <= 0:
        print("error: --graphics-duration must be greater than zero", file=sys.stderr)
        return 2
    repo = args.repo.expanduser().resolve()
    bin_dir = (
        args.bin_dir.expanduser().resolve()
        if args.bin_dir
        else repo / "bin" / "aarch64" / "linux" / "release"
    )
    source_root = repo / "Samples" if (repo / "Samples").is_dir() else repo / "cpp"
    if not source_root.is_dir() or not ((repo / "Makefile").is_file() or (repo / "CMakeLists.txt").is_file()):
        print(f"error: not a recognized cuda-samples root: {repo}", file=sys.stderr)
        return 2
    if not bin_dir.is_dir():
        print(f"error: binary directory not found: {bin_dir}", file=sys.stderr)
        return 2
    if shutil.which("make") is None:
        print("error: make not found", file=sys.stderr)
        return 2

    samples, unmatched = discover(repo, bin_dir, args.use_run)
    samples = [
        sample
        for sample in samples
        if selected(sample.name, args.name)
        and (not args.group or sample.group in args.group)
        and (args.include_nonwindow_graphics or sample.name not in NONWINDOW_GRAPHICS)
    ]
    if args.graphics_duration is not None:
        for sample in samples:
            if sample.group == "graphics":
                sample.target = "run"
    print(f"Repository: {repo}")
    print(f"Binary dir: {bin_dir}")
    print(f"Matched candidate samples: {len(samples)}")
    if unmatched:
        print(f"Warning: {len(unmatched)} binaries have no matching runnable Makefile:")
        print("  " + ", ".join(unmatched))

    decisions: list[tuple[Sample, str | None]] = [
        (sample, skip_reason(sample, args)) for sample in samples
    ]
    planned_runs = sum(reason is None for _, reason in decisions)
    planned_skips = len(decisions) - planned_runs
    print(f"Execution plan: {planned_runs} run, {planned_skips} skip")
    if args.dry_run:
        for sample, reason in decisions:
            action = "SKIP" if reason else "RUN"
            if reason:
                detail = reason
            elif (
                sample.group == "graphics"
                and args.graphics_duration is not None
            ):
                detail = f"make run for {args.graphics_duration}s"
            else:
                detail = f"make {sample.target}"
            print(f"{action:4s} {sample.name:42s} {sample.group:10s} {detail}")
        run_count = sum(reason is None for _, reason in decisions)
        print(f"\nDry run: {run_count} run, {len(decisions) - run_count} skip")
        return 0

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = (
        args.output.expanduser().resolve()
        if args.output
        else repo / "test-v12.5" / timestamp
    )
    logs_dir = output_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    cuda_bin = "/usr/local/cuda/bin"
    cuda_lib = "/usr/local/cuda/lib64"
    env["PATH"] = cuda_bin + os.pathsep + env.get("PATH", "")
    env["LD_LIBRARY_PATH"] = cuda_lib + os.pathsep + env.get("LD_LIBRARY_PATH", "")
    results: list[Result] = []
    metadata: dict[str, object] = {
        "repository": str(repo),
        "binary_dir": str(bin_dir),
        "started": datetime.now().isoformat(timespec="seconds"),
        "timeout_seconds": args.timeout,
        "patterns": args.name,
        "groups": args.group,
        "include_graphics": args.include_graphics,
        "include_nonwindow_graphics": args.include_nonwindow_graphics,
        "graphics_duration_seconds": args.graphics_duration,
        "include_multigpu": args.include_multigpu,
        "include_mpi": args.include_mpi,
        "include_special": args.include_special,
    }

    try:
        for index, (sample, reason) in enumerate(decisions, start=1):
            if reason:
                print(f"[{index:3d}/{len(decisions)}] SKIP    {sample.name}: {reason}")
                results.append(
                    Result(sample.name, "SKIPPED", sample.group, sample.target, None, 0.0, "", reason)
                )
                continue
            print(f"[{index:3d}/{len(decisions)}] RUN     {sample.name} ({sample.target})", flush=True)
            result = run_sample(sample, args, logs_dir, env)
            print(f"                 {result.status} in {result.seconds:.1f}s")
            results.append(result)
    except KeyboardInterrupt:
        print("\nInterrupted; writing partial reports.", file=sys.stderr)
        metadata["interrupted"] = True

    metadata["finished"] = datetime.now().isoformat(timespec="seconds")
    write_reports(output_dir, results, metadata)
    print_summary(results)
    print(f"\nReports: {output_dir}")
    return 1 if any(item.status in {"FAIL", "TIMEOUT"} for item in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
