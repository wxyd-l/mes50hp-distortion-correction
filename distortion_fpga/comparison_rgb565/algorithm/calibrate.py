"""Calibrate the five-coefficient pinhole model from raw chessboard frames."""
import argparse
import json
from pathlib import Path

import numpy as np


def parse_board(text):
    try:
        cols, rows = map(int, text.lower().split("x"))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("use INNER corners, e.g. 9x6") from exc
    if min(cols, rows) < 2:
        raise argparse.ArgumentTypeError("each inner-corner dimension must be >= 2")
    return cols, rows


def fit_camera(object_points, image_points, image_size, radial_order=2):
    import cv2
    if radial_order not in (2, 3):
        raise ValueError("radial_order must be 2 or 3")
    flags = cv2.CALIB_FIX_K3 if radial_order == 2 else 0
    rms, k, d, rvecs, tvecs = cv2.calibrateCamera(
        object_points, image_points, image_size, None, np.zeros(5), flags=flags)
    errors = []
    for obj, corners, rvec, tvec in zip(object_points, image_points, rvecs, tvecs):
        projected, _ = cv2.projectPoints(obj, rvec, tvec, k, d)
        delta = projected.reshape(-1, 2) - corners.reshape(-1, 2)
        errors.append(float(np.sqrt(np.mean(np.sum(delta * delta, axis=1)))))
    if not np.isfinite(k).all() or not np.isfinite(d).all() or not np.isfinite(rms):
        raise ValueError("calibration produced non-finite values")
    coeffs = d.ravel()[:4] if radial_order == 2 else d.ravel()
    return {"model": f"brown_conrady_{len(coeffs)}", "image_size": list(image_size),
            "radial_order": radial_order,
            "camera_matrix": k.tolist(), "dist_coeffs": coeffs.tolist(),
            "rms_reprojection_error_px": float(rms), "per_view_rms_px": errors}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--images", type=Path, required=True, help="directory of original camera frames")
    p.add_argument("--pattern", default="*.png")
    p.add_argument("--board", type=parse_board, default=(9, 6), help="INNER corners columns x rows")
    p.add_argument("--square-mm", type=float, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--radial-order", type=int, choices=(2, 3), default=2,
                   help="2: competition baseline (k3 fixed zero); 3: optional five-parameter model")
    args = p.parse_args()
    if not np.isfinite(args.square_mm) or args.square_mm <= 0:
        p.error("square-mm must be finite and positive")
    try:
        import cv2
    except ImportError:
        p.error("OpenCV is needed for calibration; install requirements.txt first")
    files = sorted(args.images.glob(args.pattern))
    if not files:
        p.error("no images found")
    cols, rows = args.board  # Already inner corners: NEVER subtract one.
    obj = np.zeros((cols * rows, 3), np.float32)
    obj[:, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2) * args.square_mm
    size = None
    object_points, image_points, used, rejected = [], [], [], []
    for file in files:
        # imdecode also handles Windows non-ASCII paths.
        image = cv2.imdecode(np.fromfile(file, dtype=np.uint8), cv2.IMREAD_GRAYSCALE)
        if image is None:
            p.error(f"unreadable image: {file}")
        current_size = (image.shape[1], image.shape[0])
        if size is None:
            size = current_size
        if current_size != size:
            p.error("mixed image sizes: all frames must use the same camera mode and resolution")
        found, corners = cv2.findChessboardCornersSB(image, args.board)
        if not found:
            rejected.append(str(file))
            continue
        object_points.append(obj.copy())
        image_points.append(corners.astype(np.float32).reshape(-1, 1, 2))
        used.append(str(file))
    if len(used) < 8:
        p.error(f"only {len(used)} usable views; need at least 8 (15-25 varied views recommended)")
    result = fit_camera(object_points, image_points, size, args.radial_order)
    result.update({"board_inner_corners": list(args.board), "square_mm": args.square_mm,
                   "used_images": used, "rejected_images": rejected,
                   "warning": "Low reprojection error alone does not prove good coverage or correct lens model."})
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Used {len(used)}/{len(files)} views; RMS={result['rms_reprojection_error_px']:.4f} px")
    print(f"Calibration: {args.out.resolve()}")


if __name__ == "__main__":
    main()
