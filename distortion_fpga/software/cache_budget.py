"""32-byte-line set-associative cache traffic estimate, not a DDR timing proof.
Example: python -m software.cache_budget --width 1920 --height 1080 --fps 60 --output build/cache_budget.json
Default --bpp 4 matches RGB888-in-32-bit abstract memory; --bpp 2 models a proposed RGB565 layout. Optional --config uses the same calibration JSON as software.reference.
"""
import argparse
from collections import OrderedDict
import json
from pathlib import Path
import numpy as np
from .reference import float_map, load_config


def scenario(width, height, name):
    cx, cy = (width - 1) / 2, (height - 1) / 2
    c = {"image_size": [width, height], "camera_matrix": [[width, 0, cx], [0, width, cy], [0, 0, 1]], "distortion": [0, 0, 0, 0]}
    if name == "distortion":
        c["distortion"] = [-0.3, 0.08, 0.004, -0.003]
    elif name == "rotate90":
        c["output_to_ideal"] = [[0, -1, cx + cy], [1, 0, cy - cx]]
    return c


def trace_lines(sx, sy, bpp, order, tile):
    h, w = sx.shape
    x, y = np.floor(sx).astype(np.int64), np.floor(sy).astype(np.int64)
    # Include first/last byte lines, so RGB888 pixels crossing a line are accounted for.
    fields = []
    for dy, dx in ((0, 0), (0, 1), (1, 0), (1, 1)):
        xx, yy = x + dx, y + dy
        valid = (xx >= 0) & (xx < w) & (yy >= 0) & (yy < h)
        a = (yy * w + xx) * bpp
        lo, hi = a // 32, (a + bpp - 1) // 32
        fields.extend([np.where(valid, lo, -1), np.where(valid & (hi != lo), hi, -1)])
    lines = np.stack(fields, axis=-1)
    if order == "raster":
        return lines.reshape(-1)
    return np.concatenate([lines[v:v+tile, u:u+tile].reshape(-1) for v in range(0, h, tile) for u in range(0, w, tile)])


def simulate(trace, kib, ways):
    count = kib * 1024 // 32
    if ways < 1 or count < ways or count % ways:
        raise ValueError("cache line count must be a positive multiple of ways")
    sets = [OrderedDict() for _ in range(count // ways)]
    hits = misses = 0
    for raw in trace:
        line = int(raw)
        if line < 0:
            continue
        bucket = sets[line % len(sets)]
        if line in bucket:
            hits += 1
            bucket.move_to_end(line)
        else:
            misses += 1
            if len(bucket) == ways:
                bucket.popitem(last=False)
            bucket[line] = None
    return hits, misses


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--config", type=Path)
    p.add_argument("--width", type=int, default=320)
    p.add_argument("--height", type=int, default=180)
    p.add_argument("--fps", type=float, default=60)
    p.add_argument("--bpp", type=int, choices=(2, 3, 4), default=4)
    p.add_argument("--cache-kib", type=int, nargs="+", default=[16, 64])
    p.add_argument("--ways", type=int, default=4)
    p.add_argument("--tile", type=int, default=32)
    p.add_argument("--cases", nargs="+", choices=("identity", "distortion", "rotate90"), default=["identity", "distortion", "rotate90"])
    p.add_argument("--output", type=Path, default=Path("build/cache_budget.json"))
    a = p.parse_args()
    if min(a.width, a.height, a.tile, a.fps) <= 0:
        p.error("dimensions, tile and fps must be positive")
    configs = {a.config.stem: load_config(a.config)} if a.config else {n: scenario(a.width, a.height, n) for n in a.cases}
    rows = []
    for name, config in configs.items():
        sx, sy = float_map(config)
        w, h = config["image_size"]
        frame_bytes = w * h * a.bpp
        for order in ("raster", "tile"):
            trace = trace_lines(sx, sy, a.bpp, order, a.tile)
            for kib in a.cache_kib:
                hits, misses = simulate(trace, kib, a.ways)
                read_bytes = misses * 32
                # One captured frame write, one output-frame write and one display read.
                total = read_bytes + 3 * frame_bytes
                row = {"case": name, "width": w, "height": h, "order": order, "tile": a.tile, "cache_kib": kib, "ways": a.ways, "hits": hits, "misses": misses, "hit_ratio": hits / max(1, hits + misses), "source_read_bytes_per_frame": read_bytes, "capture_write_bytes_per_frame": frame_bytes, "output_write_and_display_read_bytes_per_frame": 2 * frame_bytes, "total_GBps": total * a.fps / 1e9, "physical_peak_fraction": total * a.fps / 3.2e9}
                rows.append(row)
                print(f"{name:12} {order:6} {kib:3} KiB: hit {row['hit_ratio']:.4%}, total {row['total_GBps']:.6f} GB/s", flush=True)
    report = {"status": "offline_traffic_estimate_only", "fps": a.fps, "bytes_per_pixel": a.bpp, "line_bytes": 32, "assumptions": ["Floating-point reference map, not bit-exact RTL request trace; quantization can change lines near boundaries.", "Proposed cached/tiled architecture estimate; remap_frame_core currently has no cache or tile scheduler.", "Cold cache each frame; line allocation on demand; LRU within each set.", "No prefetch or burst overfetch; tags/replacement metadata excluded from cache KiB.", "Constant border: out-of-image neighbors generate no memory read.", "Includes full capture write, full output write, full display read regardless of cropped area.", "No row/bank timing, refresh, arbitration, DDR command-rate, FIFO or latency model.", "Tile output writes assumed perfectly combined: requires tile storage/write combiner in RTL.", "Below physical peak does not prove achievable timing or throughput."], "results": rows}
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

