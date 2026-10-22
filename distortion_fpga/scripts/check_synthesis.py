"""Check synthesizable RTL structure with Yosys; do not perform device mapping.

Uses a native Yosys or the project-local Ubuntu package under tools/yosys-wsl.
No package installation, ABC invocation, or Pango resource claim is performed.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
BASE_SOURCES = [
    "rtl/distortion_mapper.sv",
    "rtl/bilinear_rgb.sv",
    "rtl/remap_frame_core.sv",
    "rtl/pixel_read_cache.sv",
    "rtl/pango_read_bridge.sv",
    "rtl/remap_ddr_read_top.sv",
    "rtl/homography_normalizer.sv",
    "rtl/projective_distortion_mapper.sv",
    "rtl/gamma_stream.sv",
]
DEFAULT_TOPS = ["distortion_mapper", "bilinear_rgb", "remap_frame_core",
                "pixel_read_cache", "pango_read_bridge", "remap_ddr_read_top",
                "homography_normalizer", "projective_distortion_mapper", "gamma_stream"]


def wsl_path(path: Path) -> str:
    path = path.resolve()
    if not path.drive:
        return path.as_posix()
    return "/mnt/" + path.drive[0].lower() + "/" + path.as_posix()[3:]


def locate_yosys():
    native = shutil.which("yosys")
    if native:
        return [native], lambda path: path.resolve().as_posix(), os.environ.copy()
    local = ROOT / "tools" / "yosys-wsl" / "usr"
    binary = local / "bin" / "yosys"
    if not binary.exists():
        raise RuntimeError("No Yosys found. See docs/synthesis_check.md for local package setup.")
    library = local / "lib" / "x86_64-linux-gnu"
    if os.name == "nt":
        distro = os.environ.get("FPGA_WSL_DISTRO", "Ubuntu-22.04")
        return (["wsl", "-d", distro, "--", "env", "LD_LIBRARY_PATH=" + wsl_path(library),
                 wsl_path(binary)], wsl_path, os.environ.copy())
    environment = os.environ.copy()
    environment["LD_LIBRARY_PATH"] = str(library)
    return [str(binary)], lambda path: path.resolve().as_posix(), environment


def run(command, environment, timeout=180):
    return subprocess.run(command, cwd=ROOT, env=environment, timeout=timeout,
                          text=True, encoding="utf-8", errors="replace", capture_output=True)


def parameter_int(value):
    return int(value, 2) if isinstance(value, str) else int(value)


def summarize_netlist(netlist, top):
    """Count primitive cells through hierarchy, including every instance."""
    modules = netlist["modules"]
    primitive_types = Counter()
    multipliers = Counter()
    flip_flop_bits = 0
    latch_bits = 0
    memory_bits = 0
    memory_blocks = []

    def visit(name, stack):
        nonlocal flip_flop_bits, latch_bits, memory_bits
        if name in stack:
            raise RuntimeError("Recursive module hierarchy: " + " -> ".join(stack + [name]))
        module = modules[name]
        for memory in module.get("memories", {}).values():
            memory_bits += memory["width"] * memory["size"]
        for cell_name, cell in module.get("cells", {}).items():
            kind = cell["type"]
            if kind in modules:
                visit(kind, stack + [name])
                continue
            primitive_types[kind] += 1
            lowered = kind.lower()
            if "dff" in lowered or lowered == "$ff":
                flip_flop_bits += len(cell["connections"]["Q"])
            if "latch" in lowered:
                latch_bits += len(cell["connections"]["Q"])
            if kind in ("$mem", "$mem_v2"):
                params = cell["parameters"]
                width = parameter_int(params["WIDTH"])
                size = parameter_int(params["SIZE"])
                memory_bits += width * size
                memory_blocks.append({
                    "module": name,
                    "cell": cell_name,
                    "width": width,
                    "size": size,
                    "read_ports": parameter_int(params["RD_PORTS"]),
                    "read_clock_enable_mask": parameter_int(params["RD_CLK_ENABLE"]),
                    "write_ports": parameter_int(params["WR_PORTS"]),
                    "write_clock_enable_mask": parameter_int(params["WR_CLK_ENABLE"]),
                })
            if kind == "$mul":
                params = cell["parameters"]
                lhs = parameter_int(params["A_WIDTH"])
                rhs = parameter_int(params["B_WIDTH"])
                result = parameter_int(params["Y_WIDTH"])
                lhs_sign = "s" if parameter_int(params["A_SIGNED"]) else "u"
                rhs_sign = "s" if parameter_int(params["B_SIGNED"]) else "u"
                multipliers[f"{lhs}{lhs_sign} x {rhs}{rhs_sign} -> {result}"] += 1

    visit(top, [])
    return {
        "generic_cells": sum(primitive_types.values()),
        "generic_cell_types": dict(sorted(primitive_types.items())),
        "flip_flop_bits": flip_flop_bits,
        "latch_bits": latch_bits,
        "memory_bits": memory_bits,
        "memory_blocks": memory_blocks,
        "multiplication_cells": primitive_types["$mul"],
        "multiplier_widths": dict(sorted(multipliers.items())),
    }


def check_top(top, sources, prefix, path_for_tool, environment, parameters=None, label=None):
    build = ROOT / "build"
    label = label or top
    script_path = build / f"synthesis_{label}.ys"
    json_path = build / f"synthesis_{label}.json"
    log_path = build / f"synthesis_{label}.log"
    quoted_sources = " ".join('"' + path_for_tool(source) + '"' for source in sources)
    # Word-level reduction only. Multiplication stays a generic $mul; no
    # techmap, synth_*, memory mapping, ABC, or place-and-route is requested.
    commands = [
        "read_verilog -sv " + quoted_sources,
        *(["chparam " + " ".join(f"-set {key} {value}" for key,value in parameters.items()) + " " + top]
          if parameters else []),
        "hierarchy -check -top " + top,
        "proc",
        "opt",
        "wreduce",
        "opt",
        "memory_dff",
        "memory_collect",
        "opt_clean",
        "check -assert",
        "stat",
        'write_json "' + path_for_tool(json_path) + '"',
    ]
    script_path.write_text("\n".join(commands) + "\n", encoding="utf-8")
    result = run(prefix + ["-Q", "-T", "-s", path_for_tool(script_path)], environment)
    log = result.stdout + result.stderr
    log_path.write_text(log, encoding="utf-8")
    if result.returncode:
        tail = "\n".join(log.splitlines()[-30:])
        raise RuntimeError(f"Yosys failed for {top}; see {log_path}\n{tail}")
    findings = re.findall(r"Found and reported (\d+) problems", log, flags=re.IGNORECASE)
    if not findings or int(findings[-1]) != 0:
        raise RuntimeError(f"No clean CHECK result for {top}; see {log_path}")
    stats = summarize_netlist(json.loads(json_path.read_text(encoding="utf-8")), top)
    if stats["latch_bits"]:
        raise RuntimeError(f"{top} inferred {stats['latch_bits']} latch bits; see {json_path}")
    warnings = [line for line in log.splitlines() if line.startswith("Warning:")]
    return {
        "top": top,
        "configuration": label,
        "parameters": parameters or {},
        "passed": True,
        "check_problems": int(findings[-1]),
        **stats,
        "warnings": warnings,
        "log": log_path.relative_to(ROOT).as_posix(),
        "netlist": json_path.relative_to(ROOT).as_posix(),
        "flow": commands,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top", action="append", help="Top module to check; repeat for multiple modules")
    parser.add_argument("--rtl", action="append", default=[],
                        help="Additional project-relative RTL source; repeat for dependencies")
    args = parser.parse_args()
    tops = args.top or DEFAULT_TOPS
    for top in tops:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", top):
            raise ValueError(f"Invalid Verilog module identifier: {top!r}")
    relative_sources = list(BASE_SOURCES)
    for top in tops:
        candidate = f"rtl/{top}.sv"
        if (ROOT / candidate).exists() and candidate not in relative_sources:
            relative_sources.append(candidate)
    for source in args.rtl:
        if source not in relative_sources:
            relative_sources.append(source)
    sources = [(ROOT / source).resolve() for source in relative_sources]
    for source in sources:
        if not source.is_file():
            raise FileNotFoundError(source)
    prefix, path_for_tool, environment = locate_yosys()
    version = run(prefix + ["-V"], environment, timeout=30)
    if version.returncode:
        raise RuntimeError(version.stderr or version.stdout)
    (ROOT / "build").mkdir(exist_ok=True)
    report = {
        "kind": "Generic RTL structural synthesis; no Pango mapping, timing, or board validation",
        "tool": version.stdout.strip(),
        "utc_time": datetime.now(timezone.utc).isoformat(),
        "sources_sha256": {
            source.relative_to(ROOT).as_posix(): hashlib.sha256(source.read_bytes()).hexdigest()
            for source in sources
        },
        "modules": [],
    }
    for top in tops:
        stats = check_top(top, sources, prefix, path_for_tool, environment)
        report["modules"].append(stats)
        print(f"PASS {top}: check=0 latch_bits=0 mul={stats['multiplication_cells']} "
              f"FF_bits={stats['flip_flop_bits']} memory_bits={stats['memory_bits']} "
              f"generic_cells={stats['generic_cells']}", flush=True)
    if not args.top:
        stats = check_top("remap_ddr_read_top", sources, prefix, path_for_tool, environment,
                          parameters={"PROJECTIVE": 1, "POSITIVE_DEPTH": 1},
                          label="remap_ddr_read_top_projective")
        report["modules"].append(stats)
        print(f"PASS remap_ddr_read_top_projective: check=0 latch_bits=0 "
              f"mul={stats['multiplication_cells']} FF_bits={stats['flip_flop_bits']} "
              f"memory_bits={stats['memory_bits']} generic_cells={stats['generic_cells']}", flush=True)
    suffix = "_" + "_".join(tops) if args.top else ""
    report_path = ROOT / "build" / f"synthesis_results{suffix}.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Report: {report_path}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
