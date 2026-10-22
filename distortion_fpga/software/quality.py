"""Whole-line straightness and explicitly selected slanted-edge SFR measurements.

Run ``python -m software.quality --help`` from distortion_fpga. See
docs/quality_metrics.md for the measurement definitions and supported inputs.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def fit_line_tls(points):
    """Equal-weight orthogonal fit to ALL supplied (x, y) points, in pixels."""
    points = np.asarray(points, dtype=np.float64)
    if points.ndim != 2 or points.shape[1] != 2 or len(points) < 3:
        raise ValueError("a line needs at least three (x, y) points")
    if not np.isfinite(points).all():
        raise ValueError("line points must be finite")
    centroid = points.mean(axis=0)
    centered = points - centroid
    _, singular, vectors = np.linalg.svd(centered, full_matrices=False)
    if singular[0] <= 1e-12:
        raise ValueError("line points have no spatial extent")
    normal = vectors[1]
    if normal[np.argmax(np.abs(normal))] < 0:
        normal = -normal
    direction = np.array([-normal[1], normal[0]])
    residual = centered @ normal
    along = centered @ direction
    return {
        "point_count": len(points),
        "line_abc": [float(normal[0]), float(normal[1]), float(-centroid @ normal)],
        "centroid_xy_px": centroid.tolist(),
        "span_px": float(np.ptp(along)),
        "rms_perpendicular_px": float(np.sqrt(np.mean(residual**2))),
        "max_abs_perpendicular_px": float(np.max(np.abs(residual))),
        "signed_perpendicular_px": residual.tolist(),
        "points_xy_px": points.tolist(),
    }


def straightness_report(data):
    """Read {lines: [{id: ..., points: [[x,y], ...]}, ...]} without segmentation."""
    lines = data.get("lines", [])
    if not lines:
        raise ValueError("points JSON needs a nonempty 'lines' list")
    results = [{"id": line.get("id", str(i)), **fit_line_tls(line["points"])}
               for i, line in enumerate(lines)]
    return {"status": "ok", "metric": "whole_line_tls_straightness",
            "provenance": data.get("provenance", "unspecified"), "lines": results}


def _edge_line(image, polarity):
    """Two-pass derivative-centroid line fit; no per-row alignment or curve fit."""
    height, width = image.shape
    x = np.arange(1, width - 1, dtype=np.float64)
    y = np.arange(height, dtype=np.float64)
    derivative = polarity * (image[:, 2:] - image[:, :-2]) / 2
    window = np.broadcast_to(np.hamming(width - 2), derivative.shape)
    for _ in range(2):
        weighted = derivative * window
        mass = weighted.sum(axis=1)
        if np.any(mass <= 0):
            raise ValueError("ROI does not contain one consistently oriented edge in every row")
        centers = (weighted * x).sum(axis=1) / mass
        slope, intercept = np.polyfit(y, centers, 1)
        predicted = slope * y + intercept
        z = (x[None, :] - predicted[:, None]) / (width / 2)
        window = np.where(np.abs(z) < 1, .54 + .46 * np.cos(np.pi * z), 0)
    residual = (centers - predicted) / np.sqrt(1 + slope**2)
    return float(slope), float(intercept), residual


def slanted_edge_sfr(image, roi=None, orientation="vertical"):
    """Measure a single straight edge in a 2-D, already linearized image.

    ROI is (x, y, width, height); integer pixel centers have integer coordinates.
    SFR uses perpendicular distance in analyzed-image pixels, fourfold binning,
    central differences, a flat-core cosine window and derivative/bin corrections.
    Only MTF50 crossings <= 0.4 cycles/pixel are supported. Unresolved crossings
    return status='not_measurable' and None, never a clipped or extrapolated MTF50.
    """
    image = np.asarray(image, dtype=np.float64)
    if image.ndim != 2 or not np.isfinite(image).all():
        raise ValueError("SFR input must be a finite 2-D linear-light image")
    if roi is None:
        roi = (0, 0, image.shape[1], image.shape[0])
    if len(roi) != 4 or any(int(v) != v for v in roi):
        raise ValueError("ROI must be integer x, y, width, height")
    x0, y0, width, height = map(int, roi)
    if x0 < 0 or y0 < 0 or width < 32 or height < 32 or \
            x0 + width > image.shape[1] or y0 + height > image.shape[0]:
        raise ValueError("ROI must be inside the image and at least 32 by 32 pixels")
    patch = image[y0:y0 + height, x0:x0 + width]
    if orientation == "horizontal":
        patch = patch.T
    elif orientation != "vertical":
        raise ValueError("orientation must be 'vertical' or 'horizontal'")
    height, width = patch.shape
    border = max(3, width // 16)
    left, right = np.median(patch[:, :border]), np.median(patch[:, -border:])
    contrast = float(abs(right - left))
    if contrast <= 1e-8:
        raise ValueError("edge plateau contrast is zero")
    polarity = 1 if right > left else -1
    slope, intercept, residual = _edge_line(patch, polarity)
    angle = float(np.degrees(np.arctan(abs(slope))))
    if not 2 <= angle <= 10 or abs(slope) * (height - 1) < 4:
        raise ValueError("edge must be slanted 2 to 10 degrees from its stated axis and drift >=4 pixels across rows")
    fit_rms = float(np.sqrt(np.mean(residual**2)))
    if fit_rms > .1:
        raise ValueError(f"edge line-fit RMS {fit_rms:.4g} px exceeds 0.1 px; use a straighter/cleaner edge")

    yy, xx = np.indices(patch.shape)
    distance = (xx - slope * yy - intercept) / np.sqrt(1 + slope**2)
    # A common symmetric support keeps all scan lines in the measurement.
    radius = np.floor(min(-np.max(distance[:, 0]), np.min(distance[:, -1])) * 4) / 4
    if radius < 12:
        raise ValueError("edge needs at least 12 pixels of plateau support on each side in every scan line")
    spacing = .25
    count_bins = int(2 * radius / spacing)
    indices = np.floor((distance + radius) / spacing).astype(np.int64)
    inside = (indices >= 0) & (indices < count_bins)
    counts = np.bincount(indices[inside], minlength=count_bins)
    if np.any(counts == 0):
        raise ValueError("slant does not fill every oversampled ESF bin; select a longer or differently angled edge")
    esf = np.bincount(indices[inside], weights=patch[inside], minlength=count_bins) / counts
    position = (np.arange(count_bins) + .5) * spacing - radius
    low, high = np.mean(esf[:8]), np.mean(esf[-8:])
    normalized = (esf - low) / (high - low)
    # The cosine taper must start on the plateaus, not inside a broad transition.
    left_core = (position >= -radius / 2 - 1) & (position <= -radius / 2)
    right_core = (position >= radius / 2) & (position <= radius / 2 + 1)
    tail_fraction = float(max(abs(np.mean(normalized[left_core])),
                              abs(1 - np.mean(normalized[right_core]))))
    if tail_fraction > .01:
        raise ValueError("edge transition reaches the window taper (>1% plateau departure); select a wider ROI")

    lsf = polarity * (esf[2:] - esf[:-2]) / (2 * spacing)
    lsf_position = position[1:-1]
    window_radius = max(abs(lsf_position[0]), abs(lsf_position[-1]))
    z = np.abs(lsf_position) / window_radius
    window = np.where(z <= .5, 1, .5 * (1 + np.cos(2 * np.pi * (z - .5))))
    windowed = lsf * window
    nfft = 2 ** int(np.ceil(np.log2(max(4096, 8 * len(lsf)))))
    frequency = np.fft.rfftfreq(nfft, d=spacing)
    keep = frequency <= .5
    frequency = frequency[keep]
    spectrum = np.abs(np.fft.rfft(windowed, n=nfft))[keep]
    uncorrected = spectrum / spectrum[0]
    # np.sinc(t)=sin(pi*t)/(pi*t). The bin term is the rectangular bin aperture.
    derivative_correction = 1 / np.sinc(2 * frequency * spacing)
    bin_correction = 1 / np.sinc(frequency * spacing)
    sfr = uncorrected * derivative_correction * bin_correction
    crossing = np.flatnonzero((sfr[:-1] >= .5) & (sfr[1:] < .5))
    mtf50 = None
    reason = "SFR does not cross 0.5 inside the measured 0 to 0.5 cycles/pixel band"
    if len(crossing):
        i = int(crossing[0])
        value = frequency[i] + (.5 - sfr[i]) * (frequency[i + 1] - frequency[i]) / (sfr[i + 1] - sfr[i])
        if value <= .4:
            mtf50 = float(value)
            reason = None
        else:
            reason = "MTF50 crossing exceeds the supported 0.4 cycles/pixel limit"
    return {
        "status": "ok" if mtf50 is not None else "not_measurable",
        "metric": "slanted_edge_sfr", "failure_reason": reason,
        "mtf50_cycles_per_pixel": mtf50,
        "mtf50_definition": "first downward crossing of 0.5 relative to zero-frequency response",
        "roi_xywh": list(map(int, roi)), "orientation": orientation,
        "edge_slope_in_oriented_roi": slope, "edge_intercept_in_oriented_roi_px": intercept,
        "edge_angle_from_axis_degrees": angle, "edge_fit_rms_px": fit_rms,
        "edge_fit_max_abs_px": float(np.max(np.abs(residual))),
        "edge_fit_residual_px": residual.tolist(),
        "plateau_contrast_linear": contrast, "taper_start_plateau_departure_fraction": tail_fraction,
        "oversampling": 4, "support_radius_px": float(radius),
        "window": "Tukey alpha=0.5, symmetric about fitted edge",
        "frequency_units": "cycles per analyzed-image pixel along the edge normal",
        "mtf50_supported_max_cycles_per_pixel": .4,
        "curves": {
            "esf_distance_px": position.tolist(), "esf_linear": esf.tolist(),
            "esf_bin_count": counts.tolist(),
            "lsf_distance_px": lsf_position.tolist(), "lsf": lsf.tolist(),
            "lsf_window": window.tolist(), "lsf_windowed": windowed.tolist(),
            "frequency_cycles_per_pixel": frequency.tolist(), "sfr": sfr.tolist(),
            "sfr_without_corrections": uncorrected.tolist(),
            "derivative_correction": derivative_correction.tolist(),
            "bin_correction": bin_correction.tolist(),
        },
    }


def read_linear_image(path, encoding, gamma=None):
    """Decode integer images; apply the stated transfer curve BEFORE RGB luminance."""
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if image is None:
        raise ValueError(f"could not read image: {path}")
    if image.dtype not in (np.uint8, np.uint16):
        raise ValueError("CLI images must contain uint8 or uint16 samples")
    value = image.astype(np.float64) / np.iinfo(image.dtype).max
    if encoding == "srgb":
        value = np.where(value <= .04045, value / 12.92, ((value + .055) / 1.055)**2.4)
    elif encoding == "power":
        if gamma is None or not np.isfinite(gamma) or gamma <= 0:
            raise ValueError("power encoding requires a positive --gamma (linear = code ** gamma)")
        value = value**gamma
    elif encoding != "linear":
        raise ValueError("encoding must be linear, srgb, or power")
    if encoding != "power" and gamma is not None:
        raise ValueError("--gamma applies only to --encoding power")
    if value.ndim == 3:
        if value.shape[2] != 3:
            raise ValueError("use a grayscale or three-channel RGB image")
        value = value @ np.array([.0722, .7152, .2126])  # OpenCV reads BGR.
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("lines", help="whole-line TLS fit from user-supplied point lists")
    p.add_argument("--points", required=True)
    p.add_argument("--output", required=True)
    p = sub.add_parser("sfr", help="SFR of one user-selected slanted-edge ROI")
    p.add_argument("--image", required=True)
    p.add_argument("--roi", type=int, nargs=4, metavar=("X", "Y", "WIDTH", "HEIGHT"), required=True)
    p.add_argument("--orientation", choices=("vertical", "horizontal"), required=True)
    p.add_argument("--encoding", choices=("linear", "srgb", "power"), required=True)
    p.add_argument("--gamma", type=float)
    p.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "lines":
            report = straightness_report(json.loads(Path(args.points).read_text(encoding="utf-8-sig")))
            report["source_points"] = str(Path(args.points))
        else:
            image = read_linear_image(args.image, args.encoding, args.gamma)
            report = slanted_edge_sfr(image, args.roi, args.orientation)
            report.update(source_image=str(Path(args.image)), encoding=args.encoding, gamma=args.gamma,
                          channel="linear luminance (RGB weights 0.2126, 0.7152, 0.0722), or grayscale")
    except (ValueError, KeyError, OSError) as error:
        report = {"status": "failed", "metric": args.command, "error": str(error)}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    summary = {key: value for key, value in report.items() if key not in ("curves", "lines", "edge_fit_residual_px")}
    print(json.dumps(summary, ensure_ascii=False, allow_nan=False))
    return 0 if report["status"] == "ok" else 2


if __name__ == "__main__":
    raise SystemExit(main())
