"""Development quality metrics, NOT an ISO-certified SFR instrument."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def grayscale(image, encoding="linear"):
    a = np.asarray(image)
    a = a.astype(float) / 255 if a.dtype == np.uint8 else a.astype(float)
    if not np.isfinite(a).all() or a.min() < 0 or a.max() > 1:
        raise ValueError("quality input must be uint8 or finite float in [0,1]")
    if encoding == "srgb":
        a = np.where(a <= .04045, a / 12.92, ((a + .055) / 1.055) ** 2.4)
    elif encoding != "linear":
        raise ValueError("encoding must be linear or srgb")
    if a.ndim == 3 and a.shape[2] == 3:
        a = a @ np.array([.2126, .7152, .0722])
    if a.ndim != 2:
        raise ValueError("quality input must be grayscale or RGB")
    return a


def line_error(points):
    """Orthogonal TLS residual; does not confuse a slanted straight line with curvature."""
    points = np.asarray(points, dtype=float)
    if points.ndim != 2 or points.shape[1] != 2 or len(points) < 3 or not np.isfinite(points).all():
        raise ValueError("need at least three finite [x,y] points per line")
    center = points.mean(axis=0)
    _, singular, vh = np.linalg.svd(points - center, full_matrices=False)
    if singular[0] < 1e-9:
        raise ValueError("line points must span a nonzero length")
    normal = vh[-1]
    distance = (points - center) @ normal
    return {"n_points": len(points), "rms_orthogonal_error_px": float(np.sqrt(np.mean(distance ** 2))),
            "max_orthogonal_error_px": float(np.max(np.abs(distance))),
            "normal": normal.tolist(), "centroid": center.tolist()}


def chessboard_straightness(image, board=(9, 6)):
    import cv2
    a = np.asarray(image)
    if a.ndim == 3:
        a = cv2.cvtColor(a, cv2.COLOR_RGB2GRAY)
    found, corners = cv2.findChessboardCornersSB(a, board)
    if not found:
        raise ValueError("chessboard not detected; use a clear raw/corrected image or supplied line points")
    cols, rows = board
    corners = corners.reshape(rows, cols, 2)
    lines = [line_error(row) for row in corners] + [line_error(corners[:, c]) for c in range(cols)]
    rms = np.sqrt(sum(item['n_points'] * item['rms_orthogonal_error_px'] ** 2 for item in lines)
                  / sum(item['n_points'] for item in lines))
    return {"method": "TLS distance of detected chessboard rows and columns",
            "weighted_rms_px": float(rms), "max_error_px": max(item['max_orthogonal_error_px'] for item in lines),
            "lines": lines, "warning": "Corner detection adds uncertainty; retain the same scene for before/after comparisons."}


def slanted_edge_sfr(image, encoding="linear", oversampling=4):
    """Near-vertical isolated edge -> oversampled ESF -> LSF -> FFT estimate.

    Near-horizontal ROIs are automatically transposed. Includes gradient
    derivative correction, but does not implement the full ISO 12233 workflow.
    """
    if oversampling != 4:
        raise ValueError("this estimator uses fixed 4x oversampling")
    gray = grayscale(image, encoding)
    if min(gray.shape) < 32:
        raise ValueError("slanted-edge ROI must be at least 32x32")
    transposed = np.abs(np.diff(gray, axis=0)).sum() > np.abs(np.diff(gray, axis=1)).sum()
    if transposed:
        gray = gray.T
    height, width = gray.shape
    contrast = float(np.percentile(gray, 95) - np.percentile(gray, 5))
    if contrast < .05:
        raise ValueError("ROI contrast too low; select one clean slanted edge")
    gradient = np.abs(np.diff(gray, axis=1))
    positions, rows = [], []
    for row in range(2, height - 2):
        peak = int(np.argmax(gradient[row]))
        if peak < 10 or peak > width - 12:
            continue
        lo, hi = peak - 8, peak + 9
        weights = gradient[row, lo:hi]
        if weights.sum() < .03:
            continue
        positions.append(float(np.sum((np.arange(lo, hi) + .5) * weights) / weights.sum()))
        rows.append(row)
    if len(rows) < .75 * (height - 4):
        raise ValueError("edge leaves ROI or is not consistently detectable")
    slope, intercept = np.polyfit(rows, positions, 1)
    angle = float(np.rad2deg(np.arctan(slope)))
    if not 2 <= abs(angle) <= 10:
        raise ValueError("choose a nearly vertical/horizontal edge slanted 2-10 degrees")
    fit_residual = float(np.sqrt(np.mean((np.asarray(positions) - (slope * np.asarray(rows) + intercept)) ** 2)))
    if fit_residual > .5:
        raise ValueError("edge is curved/noisy; choose a smaller, clean straight-edge ROI")
    yy, xx = np.indices(gray.shape)
    distance = (xx - slope * yy - intercept) / np.sqrt(1 + slope ** 2)
    half_window, step = 12., 1 / oversampling
    select = (np.abs(distance) < half_window) & (yy >= 2) & (yy < height - 2)
    indices = np.floor((distance[select] + half_window) / step).astype(int)
    n_bins = int(2 * half_window / step)
    count = np.bincount(indices, minlength=n_bins)
    sums = np.bincount(indices, weights=gray[select], minlength=n_bins)
    good = count > 0
    if good.mean() < .95:
        raise ValueError("insufficient edge phases / ROI coverage for oversampled ESF")
    esf = np.interp(np.arange(n_bins), np.flatnonzero(good), sums[good] / count[good])
    lsf = np.gradient(esf, step)
    lsf *= np.hamming(len(lsf))
    fft_length = 2048
    frequency = np.fft.rfftfreq(fft_length, d=step)
    sfr = np.abs(np.fft.rfft(lsf, n=fft_length))
    if sfr[0] < 1e-8:
        raise ValueError("edge has no measurable DC contrast")
    sfr /= sfr[0]
    # Correct central-difference attenuation only below sensor Nyquist.
    omega = 2 * np.pi * frequency * step
    correction = np.ones_like(omega)
    nz = omega > 0
    correction[nz] = np.minimum(10., omega[nz] / np.abs(np.sin(omega[nz])))
    sfr *= correction
    in_band = frequency <= .5
    frequency, sfr = frequency[in_band], sfr[in_band]
    crosses = np.flatnonzero(sfr <= .5)
    mtf50 = None
    if len(crosses) and crosses[0] > 0:
        i = crosses[0]
        mtf50 = float(frequency[i - 1] + (frequency[i] - frequency[i - 1])
                      * (.5 - sfr[i - 1]) / (sfr[i] - sfr[i - 1]))
    return {"method": "development slanted-edge ESF/LSF/FFT (not ISO-certified)",
            "encoding_assumed": encoding, "mtf50_cycles_per_pixel": mtf50,
            "mtf50_status": "crossing found" if mtf50 is not None else "no crossing below Nyquist; not zero sharpness",
            "edge_angle_deg_from_vertical": angle, "transposed": bool(transposed),
            "edge_fit_rms_px": fit_residual, "contrast": contrast,
            "frequency_cycles_per_pixel": frequency.tolist(), "sfr": sfr.tolist(),
            "esf": esf.tolist(), "warning": "Not an ISO conformance result. Requires a clean isolated edge, known tone response, controlled chart/lighting and matched scale for comparisons."}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    line = sub.add_parser("lines")
    line.add_argument("--points", type=Path, required=True, help="JSON: {lines: [[[x,y],...],...]}")
    board = sub.add_parser("chessboard")
    board.add_argument("--image", type=Path, required=True)
    board.add_argument("--board", default="9x6")
    sfr = sub.add_parser("sfr")
    sfr.add_argument("--image", type=Path, required=True)
    sfr.add_argument("--roi", nargs=4, type=int, required=True, metavar=("X", "Y", "W", "H"))
    sfr.add_argument("--encoding", choices=("linear", "srgb"), required=True)
    for child in (line, board, sfr):
        child.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    if args.command == "lines":
        data = json.loads(args.points.read_text(encoding="utf-8-sig"))
        results = [line_error(points) for points in data["lines"]]
        if not results:
            p.error("no lines supplied")
        result = {"lines": results, "max_error_px": max(r['max_orthogonal_error_px'] for r in results)}
    else:
        image = np.asarray(Image.open(args.image).convert("RGB"))
        if args.command == "chessboard":
            from calibrate import parse_board
            result = chessboard_straightness(image, parse_board(args.board))
        else:
            x, y, width, height = args.roi
            if min(x, y) < 0 or min(width, height) < 32 or x + width > image.shape[1] or y + height > image.shape[0]:
                p.error("ROI must fit inside image and be at least 32x32")
            result = slanted_edge_sfr(image[y:y + height, x:x + width], args.encoding)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    print(f"Report: {args.out.resolve()}")


if __name__ == "__main__":
    main()
