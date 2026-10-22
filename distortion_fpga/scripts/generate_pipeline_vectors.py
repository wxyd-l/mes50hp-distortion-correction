"""Golden frames for raw RGB -> adaptive Gamma -> projective DDR remapper."""
from pathlib import Path
import json
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from software.enhancement import GammaFrameState
from software.geometry import pose_config
from software.pipeline import process_frame
from software.reference import fixed_parameters, synthetic_config, synthetic_image

WIDTH, HEIGHT, CASES = 32, 24, 10


def main():
    destination = ROOT / "build/pipeline"
    destination.mkdir(parents=True, exist_ok=True)
    source = synthetic_image(WIDTH, HEIGHT).astype(float)
    modes = ["adaptive"] * 7 + ["fixed", "bypass", "adaptive"]
    gains = [.2] * 4 + [1.0] * 3 + [.4, .2, .2]
    state = GammaFrameState()
    inputs, enhanced_frames, corrected_frames, coeffs, control, stats, reports = [], [], [], [], [], [], []

    def pixels(array):
        return [f"{int(r):02x}{int(g):02x}{int(b):02x}" for r, g, b in array.reshape(-1, 3)]

    for index, (mode, gain) in enumerate(zip(modes, gains)):
        config = pose_config(synthetic_config(WIDTH, HEIGHT), yaw_degrees=(index % 3 - 1) * 7,
                             pitch_degrees=(index % 2) * -5, roll_degrees=(index % 4) * 2)
        raw = np.clip(np.floor(source * gain + .5), 0, 255).astype(np.uint8)
        if index in (4, 5, 6):
            # An explicit bright step, including true saturated samples.
            raw = np.maximum(raw, 210)
        corrected, enhanced, metadata = process_frame(config, raw, state, mode=mode, bank=5)
        inputs += pixels(raw)
        enhanced_frames += pixels(enhanced)
        corrected_frames += pixels(corrected)
        coeffs += [f"{value & 0xffffffff:08x}" for value in fixed_parameters(config).values()]
        # mode[7:6], configured bank[5:3], expected applied bank[2:0].
        control.append(f"{({'bypass': 0, 'fixed': 1, 'adaptive': 2}[mode] << 6) | (5 << 3) | metadata['used_bank']:02x}")
        stats.append(f"{metadata['raw_sum']:010x}{metadata['raw_count']:08x}")
        reports.append({"frame": index, "mode": mode, "config": config, **metadata})
    for name, rows in (("raw.mem", inputs), ("enhanced.mem", enhanced_frames), ("corrected.mem", corrected_frames),
                        ("parameters.mem", coeffs), ("control.mem", control), ("statistics.mem", stats)):
        (destination / name).write_text("\n".join(rows) + "\n", encoding="ascii")
    manifest = {"provenance": "SYNTHETIC", "width": WIDTH, "height": HEIGHT, "cases": CASES, "frames": reports}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Generated {CASES * WIDTH * HEIGHT} raw/Gamma/projective RGB triples")


if __name__ == "__main__":
    main()
