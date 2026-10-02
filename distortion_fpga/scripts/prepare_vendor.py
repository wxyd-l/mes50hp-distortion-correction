"""Extract local vendor design inputs; never modify original archives.
Run from any directory: python scripts/prepare_vendor.py [--list-only].
Vendor files remain separately licensed; do not publish them with new RTL.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import shutil
import subprocess

PROJECT = Path(__file__).resolve().parents[1]
REPO = PROJECT.parent
ARCHIVES = ("06_hdmi_loop", "07_ddr3_test", "10_HDMI_DDR3_OV5640_test")


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--demo-dir", type=Path, default=REPO / "盘古50K开发板资料/盘古50K开发板/2_Demo")
    p.add_argument("--unrar", default=shutil.which("unrar") or r"C:\Program Files\WinRAR\UnRAR.exe")
    p.add_argument("--list-only", action="store_true")
    args = p.parse_args()
    destination = PROJECT / "vendor"
    records = []
    for name in ARCHIVES:
        archive = args.demo_dir / (name + ".rar")
        listing = subprocess.check_output([args.unrar, "lb", str(archive)], text=True, errors="replace")
        selected = []
        for item in listing.splitlines():
            normalized = item.replace("\\", "/")
            parts = PurePosixPath(normalized).parts
            if not parts or parts[0] != name or ".." in parts or ":" in normalized:
                raise ValueError(f"Unsafe archive member: {item!r}")
            # Keep design source, IP configuration/models, and root project/constraints.
            if (len(parts) >= 3 and parts[1] in ("src", "source", "ipcore")) or (len(parts) == 2 and Path(parts[-1]).suffix.lower() in (".pds", ".fdc", ".sdc", ".adc", ".tcl")):
                if "constraint_backup" not in parts and not normalized.endswith("~"):
                    selected.append(item)
        print(f"{name}: {len(selected)} selected archive entries")
        if not args.list_only:
            destination.mkdir(parents=True, exist_ok=True)
            for first in range(0, len(selected), 40):
                subprocess.run([args.unrar, "x", "-y", "-idq", str(archive), *selected[first:first+40], str(destination) + "/"], check=True)
            files = []
            for path in sorted((destination / name).rglob("*")):
                if path.is_file():
                    files.append({"path": path.relative_to(destination).as_posix(), "sha256": sha256(path)})
            records.append({"archive": str(archive), "archive_sha256": sha256(archive), "files": files})
    if not args.list_only:
        (destination / "manifest.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote {destination / 'manifest.json'}")


if __name__ == "__main__":
    main()
