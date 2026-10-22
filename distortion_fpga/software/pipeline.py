"""Frame sequence: raw RGB -> frame-adaptive Gamma -> geometric remapping."""
from __future__ import annotations

import copy
import glob
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np


def gamma_bank(gamma):
    from .enhancement import GAMMAS
    for index, value in enumerate(GAMMAS):
        if abs(gamma - value) < 1e-9:
            return index
    raise ValueError(f"gamma must be one of {GAMMAS}")


def add_arguments(parser):
    parser.add_argument("--config", required=True)
    parser.add_argument("--images", required=True, help="one image or a quoted glob; sorted filename order is frame order")
    parser.add_argument("--output", required=True)
    parser.add_argument("--mode", choices=("bypass", "fixed", "adaptive"), default="adaptive")
    parser.add_argument("--gamma", type=float, default=1.0, help="fixed mode: 0.5, 0.65, 0.8, 1, 1.25, 1.5, 2")
    parser.add_argument("--yaw", type=float, default=0.0, help="output-to-source camera rotation, degrees about Y")
    parser.add_argument("--pitch", type=float, default=0.0, help="degrees about X")
    parser.add_argument("--roll", type=float, default=0.0, help="degrees about Z")


def process_frame(config, image, state, *, mode="adaptive", bank=3, coordinates=None):
    from .reference import bilinear_fixed, fixed_map
    if image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("input must be RGB888")
    if list(image.shape[1::-1]) != config["image_size"]:
        raise ValueError("image resolution must match calibration")
    # Validate geometry before advancing the exposure state.
    qx, qy = fixed_map(config) if coordinates is None else coordinates
    enhanced, exposure = state.process(image, mode=mode, bank=bank)
    corrected = bilinear_fixed(enhanced, qx, qy)
    return corrected, enhanced, exposure


def run(args):
    from .enhancement import GammaFrameState
    from .geometry import pose_config
    from .reference import fixed_map, load_config
    paths = sorted(Path(p) for p in glob.glob(args.images, recursive=True))
    if not paths:
        raise ValueError("no input images matched --images")
    config = load_config(args.config)
    if any((args.yaw, args.pitch, args.roll)):
        config = pose_config(config, yaw_degrees=args.yaw, pitch_degrees=args.pitch,
                             roll_degrees=args.roll)
    coordinates = fixed_map(config)
    bank = gamma_bank(args.gamma)
    state = GammaFrameState()
    destination = Path(args.output)
    destination.mkdir(parents=True, exist_ok=True)
    reports = []
    for index, path in enumerate(paths):
        bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if bgr is None:
            raise ValueError(f"could not read {path}")
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        corrected, enhanced, metadata = process_frame(config, rgb, state, mode=args.mode,
                                                       bank=bank, coordinates=coordinates)
        stem = f"{index:04d}_{path.stem}"
        write_rgb(destination / f"{stem}_enhanced.png", enhanced)
        write_rgb(destination / f"{stem}_corrected.png", corrected)
        reports.append({"input": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "output": f"{stem}_corrected.png", **metadata})
    report = {"config": config, "processing_order": "raw RGB -> Gamma -> distortion/perspective -> bilinear",
              "frame_order": "sorted filenames", "frames": reports}
    (destination / "pipeline_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def write_rgb(path, rgb):
    if not cv2.imwrite(str(path), cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)):
        raise OSError(f"could not write {path}")


def demo(destination, width=384, height=288):
    """A reproducible lighting step, independently distorted grid, and pose change."""
    from .enhancement import GammaFrameState
    from .geometry import pose_config
    from .reference import fixed_map
    from .roundtrip import generate_roundtrip
    dst = Path(destination)
    dst.mkdir(parents=True, exist_ok=True)
    config, geometric_report, _ = generate_roundtrip(dst / "lens", width, height)
    source = cv2.cvtColor(cv2.imread(str(dst / "lens/synthetic_distorted_input.png")), cv2.COLOR_BGR2RGB)
    # Exposure is simulated in stored RGB code values, with no claim of a sensor noise model.
    exposures = [.17] * 5 + [1.12] * 5
    state = GammaFrameState()
    reports, panels = [], []
    selected = {0, 4, 5, 9}
    for index, exposure in enumerate(exposures):
        raw = np.clip(np.floor(source.astype(float) * exposure + .5), 0, 255).astype(np.uint8)
        frame_config = copy.deepcopy(config)
        if index >= 5:
            frame_config = pose_config(frame_config, yaw_degrees=6, pitch_degrees=-4, roll_degrees=3)
        corrected, enhanced, metadata = process_frame(frame_config, raw, state)
        entry = {"frame": index, "synthetic_rgb_gain": exposure, **metadata}
        reports.append(entry)
        write_rgb(dst / f"frame_{index:02d}_raw.png", raw)
        write_rgb(dst / f"frame_{index:02d}_corrected.png", corrected)
        if index in selected:
            row = np.full((height + 38, 3 * width, 3), 247, dtype=np.uint8)
            row[38:] = np.concatenate([raw, enhanced, corrected], axis=1)
            for column, label in enumerate((f"Frame {index}: RAW", "GAMMA BEFORE RESAMPLING", "DISTORTION + POSE")):
                cv2.putText(row, label, (column * width + 10, 26), cv2.FONT_HERSHEY_SIMPLEX,
                            .48, (25, 38, 52), 1, cv2.LINE_AA)
            panels.append(row)
    header = np.full((58, 3 * width, 3), 247, dtype=np.uint8)
    cv2.putText(header, "SYNTHETIC: lighting step + lens distortion + camera rotation", (12, 25),
                cv2.FONT_HERSHEY_SIMPLEX, .6, (25, 38, 52), 1, cv2.LINE_AA)
    cv2.putText(header, "Adaptive Gamma uses the previous raw frame; pose changes at frame 5.", (12, 47),
                cv2.FONT_HERSHEY_SIMPLEX, .46, (25, 38, 52), 1, cv2.LINE_AA)
    write_rgb(dst / "SYNTHETIC_ALGORITHM_PIPELINE.png", np.concatenate([header, *panels], axis=0))
    # Save an immediately reusable synthetic config for CLI examples.
    (dst / "SYNTHETIC_CONFIG.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    report = {"provenance": "SYNTHETIC", "frames": reports,
              "pose_from_frame_5_degrees": {"yaw": 6, "pitch": -4, "roll": 3},
              "independent_lens_generation": geometric_report}
    (dst / "pipeline_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report
