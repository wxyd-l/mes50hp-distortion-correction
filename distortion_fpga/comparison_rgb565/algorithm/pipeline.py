"""Competition software pipeline: pose commands, crop, enhancement and LUTs."""
import argparse
import json
from dataclasses import asdict, replace
from pathlib import Path
from time import perf_counter

import numpy as np
from PIL import Image, ImageDraw

from geometry import Mapping, View, camera_fingerprint
from undistort import Camera, as_uint8, demo_distorted_input, export_grid, sample_bilinear
from quality import line_error, slanted_edge_sfr


def enhance_image(image, mode="none", gamma=1.):
    image = np.asarray(image)
    if image.dtype != np.uint8 or image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("enhancement expects uint8 RGB")
    if not np.isfinite(gamma) or gamma <= 0:
        raise ValueError("gamma must be finite and positive")
    if mode == "none":
        return image.copy(), {"mode": mode}
    if mode in ("gamma", "auto-gamma"):
        if mode == "auto-gamma":
            median = np.median(image @ np.array([.2126, .7152, .0722])) / 255
            gamma = float(np.clip(np.log(np.clip(median, .02, .98)) / np.log(.5), .4, 3.))
        lut = as_uint8(255 * (np.arange(256) / 255) ** (1 / gamma))
        return lut[image], {"mode": mode, "gamma": gamma, "formula": "out=(in/255)**(1/gamma)*255"}
    if mode == "equalize":
        import cv2
        ycc = cv2.cvtColor(image, cv2.COLOR_RGB2YCrCb)
        ycc[:, :, 0] = cv2.equalizeHist(ycc[:, :, 0])
        return cv2.cvtColor(ycc, cv2.COLOR_YCrCb2RGB), {"mode": mode, "space": "YCrCb luminance"}
    raise ValueError("enhancement mode must be none, gamma, auto-gamma or equalize")


def process_frame(image, mapping, enhancement="none", gamma=1.):
    if (image.shape[1], image.shape[0]) != mapping.camera.size:
        raise ValueError("input frame size differs from calibrated camera mode")
    source, info = enhance_image(image, enhancement, gamma)
    mx, my = mapping.dense()
    result, valid = sample_bilinear(source, mx, my)
    return as_uint8(result), valid, mx, my, info


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False), encoding="utf-8")


def save_result(image, camera, view, out_dir, enhancement="none", gamma=1., step=32, frac_bits=8, export_lut=True):
    start = perf_counter()
    mapping = Mapping(camera, view)
    corrected, valid, mx, my, enhancement_info = process_frame(image, mapping, enhancement, gamma)
    elapsed = perf_counter() - start
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    Image.fromarray(corrected).save(out_dir / "corrected.png")
    Image.fromarray(valid.astype(np.uint8) * 255).save(out_dir / "valid_mask.png")
    np.savez_compressed(out_dir / "reference_maps.npz", map_x=mx, map_y=my, valid=valid)
    report = {"mapping": mapping.metadata(), "enhancement": enhancement_info,
              "valid_fraction": float(valid.mean()), "software_elapsed_seconds": elapsed,
              "timing_scope": "CPU map generation plus image processing; NOT FPGA latency or fps"}
    if export_lut:
        report["lut"] = export_grid(camera, out_dir, step, frac_bits, mapping, mapping.size, mapping.metadata())
    write_json(out_dir / "report.json", report)
    return corrected, report


def angle_commands(path):
    data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(data, list) or not data:
        raise ValueError("angle commands must be a nonempty list of {frame,view} objects")
    previous, commands = -1, []
    for item in data:
        frame = item["frame"]
        if isinstance(frame, bool) or not isinstance(frame, int) or frame <= previous:
            raise ValueError("command frames must be strictly increasing nonnegative integers")
        view = View(**item["view"])
        commands.append((frame, view))
        previous = frame
    if commands[0][0] != 0:
        raise ValueError("first angle command must apply at frame zero")
    return commands


def apply_crop_plan(camera, commands, plan):
    """Use identical ROI at every command; reject mismatched camera/unsafe views."""
    if (plan.get('schema')!='centered_fixed_crop_v1' or plan.get('input_size')!=list(camera.size)
            or plan.get('camera_fingerprint')!=camera_fingerprint(camera)):
        raise ValueError('crop plan schema or camera differs from the current calibration')
    converted=[]
    for frame,view in commands:
        fixed=replace(view,border='crop-fixed',fixed_roi=plan['fixed_roi'],crop_safety_px=plan['safety_px'])
        Mapping(camera,fixed)
        converted.append((frame,fixed))
    return converted


def process_video(input_path, camera, commands, out_dir, enhancement="none", gamma=1.):
    """Replay upper-computer angle commands atomically at frame boundaries.

    No live UART/IMU/device integration and no CPU real-time throughput promise.
    """
    import cv2
    input_path, out_dir = Path(input_path), Path(out_dir)
    output_path = out_dir / "corrected.avi"
    if any(value % 2 for value in camera.size):
        raise ValueError("MJPG reference video requires even width and height to avoid codec cropping")
    if input_path.resolve() == output_path.resolve():
        raise ValueError("input and output video must differ")
    if any(view.border == "crop" for _, view in commands):
        raise ValueError("video requires constant dimensions: use keep, crop-resize, crop-center or crop-fixed, not crop")
    capture = cv2.VideoCapture(str(input_path))
    if not capture.isOpened():
        raise ValueError("could not open input video")
    writer = None
    log, frame, command_index, mapping, cached_maps = [], 0, 0, None, None
    try:
        fps = float(capture.get(cv2.CAP_PROP_FPS))
        if not np.isfinite(fps) or fps <= 0:
            raise ValueError("input video does not report a usable frame rate")
        out_dir.mkdir(parents=True, exist_ok=True)
        while True:
            ok, bgr = capture.read()
            if not ok:
                break
            if (bgr.shape[1], bgr.shape[0]) != camera.size:
                raise ValueError("video frame size differs from camera calibration")
            if mapping is None or (command_index < len(commands) and commands[command_index][0] == frame):
                view = commands[command_index][1]
                start = perf_counter()
                mapping = Mapping(camera, view)
                cached_maps = mapping.dense()
                log.append({"frame": frame, "mapping": mapping.metadata(),
                            "map_build_seconds": perf_counter() - start})
                command_index += 1
            if writer is None:
                writer = cv2.VideoWriter(str(output_path), cv2.VideoWriter_fourcc(*"MJPG"), fps, camera.size)
                if not writer.isOpened():
                    raise ValueError("MJPG writer unavailable")
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            enhanced, _ = enhance_image(rgb, enhancement, gamma)
            result, valid = sample_bilinear(enhanced, *cached_maps)
            writer.write(cv2.cvtColor(as_uint8(result), cv2.COLOR_RGB2BGR))
            frame += 1
        if not frame:
            raise ValueError("video has no decodable frames")
    finally:
        capture.release()
        if writer is not None:
            writer.release()
    report = {"frames": frame, "input_encoded_fps": fps, "commands_applied": log,
              "unused_commands": len(commands) - command_index,
              "enhancement": {"mode": enhancement, "gamma": gamma},
              "warning": "Offline CPU replay with lossy MJPG output; fps is playback metadata, not measured processing throughput or FPGA latency."}
    write_json(out_dir / "video_report.json", report)
    return report


def sweep_lut(camera, view, out_dir, steps, frac_bits):
    mapping = Mapping(camera, view)
    rows = []
    for step in steps:
        for bits in frac_bits:
            report = export_grid(camera, Path(out_dir) / f"s{step}_f{bits}", step, bits,
                                 mapping, mapping.size, mapping.metadata())
            rows.append({"step": step, "frac_bits": bits,
                         **{key: report[key] for key in ("memory_bytes", "max_coordinate_error_px", "p99_coordinate_error_px", "validity_disagreements")}})
    write_json(Path(out_dir) / "sweep.json", {"view": mapping.metadata(), "configurations": rows,
               "warning": "Coordinate error is not an image quality / hardware throughput guarantee."})
    return rows


def run_demo(camera, out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    width, height = camera.size
    # Extend the scene beyond the nominal ideal image. Otherwise artificial
    # source-frame black margins would be confused with invalid output rays.
    padding = 256
    ideal = Image.new("RGB", (width + 2 * padding, height + 2 * padding), (220, 220, 220))
    draw = ImageDraw.Draw(ideal)
    for x in range(-padding, width + padding, 64):
        draw.line((x + padding, 0, x + padding, ideal.height - 1), fill=(40, 65, 95), width=2)
    for y in range(-padding, height + padding, 64):
        draw.line((0, y + padding, ideal.width - 1, y + padding), fill=(40, 65, 95), width=2)
    source = demo_distorted_input(np.asarray(ideal), camera, (-padding, -padding))
    Image.fromarray(source).save(out_dir / "input_synthetic.png")
    views = [("undistort", View()), ("rotate_keep", View(angle=20)),
             ("rotate_crop_resize", View(angle=20, border="crop-resize")),
             ("tilt_crop_resize", View(roll=8, pitch=5, yaw=-7, border="crop-resize"))]
    images, reports = [source], []
    for name, view in views:
        result, report = save_result(source, camera, view, out_dir / name)
        images.append(result)
        reports.append({"name": name, "valid_fraction": report['valid_fraction'],
                        "lut_error_px": report['lut']['max_coordinate_error_px']})
    thumbnail_width = 640
    thumbnail_height = round(height * thumbnail_width / width)
    panel = Image.new("RGB", (thumbnail_width * 3, (thumbnail_height + 32) * 2), "white")
    labels = ["SYNTHETIC INPUT", "UNDISTORTED", "ROTATE 20 DEG / KEEP FOV", "ROTATE / SAFE CROP + RESIZE", "3-D ROTATION / SAFE CROP + RESIZE"]
    for i, (array, label) in enumerate(zip(images, labels)):
        x, y = (i % 3) * thumbnail_width, (i // 3) * (thumbnail_height + 32)
        panel.paste(Image.fromarray(array).resize((thumbnail_width, thumbnail_height)), (x, y + 32))
        ImageDraw.Draw(panel).text((x + 8, y + 8), label, fill="black")
    ImageDraw.Draw(panel).text((1288, thumbnail_height + 48), "DEMONSTRATION ONLY\nNo real OV5640 calibration\nNo FPGA performance claim", fill="black")
    panel.save(out_dir / "comparison.png")
    # Separate analytic quality fixtures: no claim of real camera MTF.
    yy, xx = np.indices((160, 160), dtype=float)
    distance = (xx - .1 * yy - 72) / np.sqrt(1.01)
    from math import erf
    edge = .2 + .6 * np.vectorize(erf)(distance / (np.sqrt(2) * 1.4)) / 2 + .3
    Image.fromarray(as_uint8(edge * 255)).save(out_dir / "slanted_edge_synthetic.png")
    sfr = slanted_edge_sfr(edge, "linear")
    write_json(out_dir / "sfr_synthetic.json", sfr)
    points = np.column_stack((np.arange(20), 2 * np.arange(20) + 3))
    write_json(out_dir / "line_synthetic.json", line_error(points))
    write_json(out_dir / "summary.json", {"synthetic_only": True, "views": reports,
               "mtf50_synthetic_cycles_per_pixel": sfr['mtf50_cycles_per_pixel']})
    print(json.dumps({"out_dir": str(out_dir.resolve()), "views": reports}, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    children = {}
    for name in ("demo", "image", "export", "sweep", "video"):
        child = sub.add_parser(name)
        children[name] = child
        child.add_argument("--camera", type=Path, required=True)
        child.add_argument("--out", type=Path, required=True)
        if name in ("image", "export", "sweep"):
            child.add_argument("--view", type=Path, help="JSON of View fields")
        if name in ("image", "video"):
            child.add_argument("--input", type=Path, required=True)
            child.add_argument("--enhance", choices=("none", "gamma", "auto-gamma", "equalize"), default="none")
            child.add_argument("--gamma", type=float, default=1.)
        if name in ("image", "export"):
            child.add_argument("--step", type=int, default=32)
            child.add_argument("--frac-bits", type=int, default=8)
    children['sweep'].add_argument("--steps", type=int, nargs='+', default=[16, 32, 64])
    children['sweep'].add_argument("--frac-bits", type=int, nargs='+', default=[4, 6, 8])
    children['video'].add_argument("--commands", type=Path, required=True)
    children['video'].add_argument('--crop-plan',type=Path,help='validated centered fixed ROI JSON; overrides per-command border policy')
    children['image'].add_argument("--no-lut", action="store_true", help="allow horizon-invalid keep view without LUT export")
    args = p.parse_args()
    camera = Camera.load(args.camera)
    view = View(**json.loads(args.view.read_text(encoding="utf-8-sig"))) if getattr(args, "view", None) else View()
    if args.command == "demo":
        run_demo(camera, args.out)
    elif args.command == "video":
        commands=angle_commands(args.commands)
        if args.crop_plan:
            commands=apply_crop_plan(camera,commands,json.loads(args.crop_plan.read_text(encoding='utf-8-sig')))
        report = process_video(args.input, camera, commands, args.out, args.enhance, args.gamma)
        print(f"Processed {report['frames']} frames; report in {args.out.resolve()}")
    elif args.command == "image":
        image = np.asarray(Image.open(args.input).convert("RGB"))
        save_result(image, camera, view, args.out, args.enhance, args.gamma, args.step, args.frac_bits, not args.no_lut)
        print(f"Result: {args.out.resolve()}")
    elif args.command == "export":
        mapping = Mapping(camera, view)
        export_grid(camera, args.out, args.step, args.frac_bits, mapping, mapping.size, mapping.metadata())
        print(f"LUT: {args.out.resolve()}")
    else:
        sweep_lut(camera, view, args.out, args.steps, args.frac_bits)
        print(f"Sweep: {args.out.resolve()}")


if __name__ == "__main__":
    main()
