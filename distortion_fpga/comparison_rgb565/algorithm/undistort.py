"""Camera-independent Brown-Conrady reference and experimental FPGA LUT export.

Maps are destination-to-source, in pixel coordinates with integer pixel centers.
Only the pinhole five-coefficient model is accepted; fisheye is NOT equivalent.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def checked_size(size):
    if len(size) != 2 or any(isinstance(v, bool) or int(v) != v or v < 2 for v in size):
        raise ValueError("image_size must contain two integers >= 2: [width, height]")
    return tuple(int(v) for v in size)


def checked_matrix(matrix):
    k = np.array(matrix, dtype=np.float64, copy=True)
    if k.shape != (3, 3) or not np.isfinite(k).all():
        raise ValueError("camera_matrix must be a finite 3x3 matrix")
    if k[0, 0] <= 0 or k[1, 1] <= 0:
        raise ValueError("fx and fy must be positive")
    if not np.array_equal(k[[0, 1, 2, 2, 2], [1, 0, 0, 1, 2]], [0, 0, 0, 0, 1]):
        raise ValueError("only zero-skew pinhole camera matrices are supported")
    k.setflags(write=False)
    return k


@dataclass(frozen=True)
class Camera:
    size: tuple[int, int]
    k: np.ndarray
    d: np.ndarray

    def __post_init__(self):
        object.__setattr__(self, "size", checked_size(self.size))
        object.__setattr__(self, "k", checked_matrix(self.k))
        d = np.array(self.d, dtype=np.float64, copy=True)
        if d.shape != (5,) or not np.isfinite(d).all():
            raise ValueError("dist_coeffs must be [k1, k2, p1, p2, k3], all finite")
        d.setflags(write=False)
        object.__setattr__(self, "d", d)

    @classmethod
    def load(cls, path):
        obj = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        model = obj.get("model")
        if model not in ("brown_conrady_4", "brown_conrady_5"):
            raise ValueError("model must be brown_conrady_4 or brown_conrady_5; fisheye is different")
        d = obj["dist_coeffs"]
        if model == "brown_conrady_4":
            if len(d) != 4:
                raise ValueError("brown_conrady_4 requires exactly [k1,k2,p1,p2]")
            d = [*d, 0.0]
        return cls(obj["image_size"], obj["camera_matrix"], d)


def distort_normalized(x, y, coeffs):
    """Ideal normalized ray -> distorted normalized ray (forward lens model)."""
    k1, k2, p1, p2, k3 = coeffs
    r2 = x * x + y * y
    radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3))
    return (x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x),
            y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y)


def destination_to_source(camera, u, v, output_k=None):
    """Corrected output pixel -> original camera pixel. No coordinate clamping."""
    k_out = camera.k if output_k is None else checked_matrix(output_k)
    x = (np.asarray(u, dtype=np.float64) - k_out[0, 2]) / k_out[0, 0]
    y = (np.asarray(v, dtype=np.float64) - k_out[1, 2]) / k_out[1, 1]
    xd, yd = distort_normalized(x, y, camera.d)
    return xd * camera.k[0, 0] + camera.k[0, 2], yd * camera.k[1, 1] + camera.k[1, 2]


def build_map(camera, output_size=None, output_k=None):
    width, height = camera.size if output_size is None else checked_size(output_size)
    v, u = np.indices((height, width), dtype=np.float64)
    return destination_to_source(camera, u, v, output_k)


def valid_coordinates(mx, my, size):
    width, height = checked_size(size)
    return (np.isfinite(mx) & np.isfinite(my) & (mx >= 0) & (my >= 0)
            & (mx <= width - 1) & (my <= height - 1))


def sample_bilinear(image, mx, my):
    """Float bilinear reference; entire out-of-range samples become black.

    At exactly the last column/row the neighbor is replicated. This is NOT the
    partial-neighbor BORDER_CONSTANT convention of cv2.remap near an edge.
    """
    image = np.asarray(image)
    mx, my = np.broadcast_arrays(np.asarray(mx, dtype=np.float64), np.asarray(my, dtype=np.float64))
    if image.ndim not in (2, 3) or image.shape[0] < 2 or image.shape[1] < 2:
        raise ValueError("image must be grayscale or multichannel, at least 2x2")
    height, width = image.shape[:2]
    valid = valid_coordinates(mx, my, (width, height))
    x = np.clip(np.where(valid, mx, 0), 0, width - 1)
    y = np.clip(np.where(valid, my, 0), 0, height - 1)
    x0, y0 = np.floor(x).astype(np.intp), np.floor(y).astype(np.intp)
    x1, y1 = np.minimum(x0 + 1, width - 1), np.minimum(y0 + 1, height - 1)
    wx, wy = x - x0, y - y0
    if image.ndim == 3:
        wx, wy = wx[..., None], wy[..., None]
    result = ((1 - wy) * ((1 - wx) * image[y0, x0] + wx * image[y0, x1])
              + wy * ((1 - wx) * image[y1, x0] + wx * image[y1, x1]))
    result = np.where(valid[..., None] if image.ndim == 3 else valid, result, 0)
    return result, valid


def as_uint8(image):
    return np.clip(np.rint(image), 0, 255).astype(np.uint8)


def grid_axis(length, step):
    if not isinstance(step, int) or isinstance(step, bool) or step < 1:
        raise ValueError("grid step must be a positive integer")
    return np.unique(np.append(np.arange(0, length, step), length - 1))


def quantize_coordinates(values, frac_bits):
    if not isinstance(frac_bits, int) or isinstance(frac_bits, bool) or not 0 <= frac_bits <= 20:
        raise ValueError("frac_bits must be an integer in [0, 20]")
    q = np.rint(np.asarray(values) * (1 << frac_bits))
    if not np.isfinite(q).all() or (q < -(1 << 31)).any() or (q > (1 << 31) - 1).any():
        raise ValueError("coordinate overflows signed 32-bit fixed point")
    return q.astype(np.int64)


def interpolate_grid(values, xs, ys, output_size):
    """Bilinear coordinate interpolation, including shorter final grid cells."""
    width, height = checked_size(output_size)
    v, u = np.indices((height, width), dtype=np.float64)
    ix = np.clip(np.searchsorted(xs, u, side="right") - 1, 0, len(xs) - 2)
    iy = np.clip(np.searchsorted(ys, v, side="right") - 1, 0, len(ys) - 2)
    wx = (u - xs[ix]) / (xs[ix + 1] - xs[ix])
    wy = (v - ys[iy]) / (ys[iy + 1] - ys[iy])
    return ((1 - wy) * ((1 - wx) * values[iy, ix] + wx * values[iy, ix + 1])
            + wy * ((1 - wx) * values[iy + 1, ix] + wx * values[iy + 1, ix + 1]))


def export_grid(camera, out_dir, step=32, frac_bits=8, map_function=None,
                output_size=None, transform_metadata=None):
    """Export an experimental interface, not a drop-in for the archived RTL."""
    size = camera.size if output_size is None else checked_size(output_size)
    width, height = size
    mapping = map_function or (lambda u, v: destination_to_source(camera, u, v))
    xs, ys = grid_axis(width, step), grid_axis(height, step)
    u, v = np.meshgrid(xs, ys)
    mx, my = mapping(u, v)
    qx, qy = quantize_coordinates(mx, frac_bits), quantize_coordinates(my, frac_bits)
    packed = ((qy.astype(np.uint64) & np.uint64(0xffffffff)) << np.uint64(32)) | (qx.astype(np.uint64) & np.uint64(0xffffffff))
    vv, uu = np.indices((height, width), dtype=np.float64)
    exact_x, exact_y = mapping(uu, vv)
    if not np.isfinite(exact_x).all() or not np.isfinite(exact_y).all():
        raise ValueError("LUT export requires finite rays throughout the output; reduce tilt or crop the view")
    approx_x = interpolate_grid(qx / (1 << frac_bits), xs, ys, size)
    approx_y = interpolate_grid(qy / (1 << frac_bits), xs, ys, size)
    error = np.hypot(approx_x - exact_x, approx_y - exact_y)
    exact_valid = valid_coordinates(exact_x, exact_y, camera.size)
    approx_valid = valid_coordinates(approx_x, approx_y, camera.size)
    valid_dy = np.abs(exact_y - np.arange(height)[:, None])[exact_valid]
    metadata = {
        "schema": "experimental_grid_v1", "camera_model": "brown_conrady_4" if camera.d[4] == 0 else "brown_conrady_5",
        "camera_matrix": camera.k.tolist(),
        "dist_coeffs": camera.d[:4].tolist() if camera.d[4] == 0 else camera.d.tolist(),
        "input_size": list(camera.size), "output_size": list(size),
        "output_camera_matrix": camera.k.tolist(),
        "mapping_direction": "output_corrected_pixel_to_input_distorted_pixel",
        "pixel_centers": "integer coordinates; x rightward, y downward; RGB channel order",
        "x_nodes": xs.tolist(), "y_nodes": ys.tolist(), "grid_step": step,
        "grid_shape": [len(ys), len(xs)], "address": "row * grid_width + column",
        "word_bits": 64, "packing": "[63:32] signed y; [31:0] signed x; two's complement",
        "frac_bits": frac_bits, "decode": "signed_int32 / 2**frac_bits",
        "rounding": "nearest, ties to even", "border": "whole sample black if outside [0,W-1]x[0,H-1]",
        "interpolation": "bilinear grid coordinates, then bilinear source pixels",
        "last_cell": "use actual node interval, not grid_step, for fractional weights",
        "memory_bytes": int(packed.size * 8),
        "max_coordinate_error_px": float(error.max()),
        "p99_coordinate_error_px": float(np.percentile(error, 99)),
        "validity_disagreements": int(np.count_nonzero(exact_valid != approx_valid)),
        "valid_fraction": float(exact_valid.mean()),
        "max_vertical_displacement_valid_px": float(valid_dy.max()) if valid_dy.size else None,
        "warning": "Not an RTL line-buffer/throughput guarantee; protocol and accuracy budget require team agreement."
    }
    if transform_metadata is not None:
        metadata["transform"] = transform_metadata
        metadata["output_camera_matrix"] = None  # General composite map is not just K_out.
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "grid.memh").write_text("".join(f"{int(word):016x}\n" for word in packed.flat), encoding="ascii")
    (out_dir / "grid.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    return metadata


def demo_distorted_input(ideal, camera, ideal_origin=(0, 0)):
    """Synthetic input only: invert the lens model by fixed-point iteration.

    This helper is not the correction map and is checked for convergence.
    It is suitable for the moderate demonstration parameters, not arbitrary lenses.
    """
    v, u = np.indices((camera.size[1], camera.size[0]), dtype=np.float64)
    xd = (u - camera.k[0, 2]) / camera.k[0, 0]
    yd = (v - camera.k[1, 2]) / camera.k[1, 1]
    x, y = xd.copy(), yd.copy()
    k1, k2, p1, p2, k3 = camera.d
    for _ in range(60):
        r2 = x * x + y * y
        radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3))
        tx = 2 * p1 * x * y + p2 * (r2 + 2 * x * x)
        ty = p1 * (r2 + 2 * y * y) + 2 * p2 * x * y
        x, y = (xd - tx) / radial, (yd - ty) / radial
    check_x, check_y = distort_normalized(x, y, camera.d)
    residual = np.hypot((check_x - xd) * camera.k[0, 0], (check_y - yd) * camera.k[1, 1])
    if not np.isfinite(residual).all() or residual.max() > 1e-5:
        raise ValueError("synthetic inversion did not converge; use milder demo parameters")
    return as_uint8(sample_bilinear(ideal, x * camera.k[0, 0] + camera.k[0, 2] - ideal_origin[0],
                                   y * camera.k[1, 1] + camera.k[1, 2] - ideal_origin[1])[0])


def run_demo(camera, out_dir, step=32, frac_bits=8):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    width, height = camera.size
    ideal = Image.new("RGB", camera.size, (235, 235, 235))
    draw = ImageDraw.Draw(ideal)
    for x in range(0, width, 64):
        draw.line((x, 0, x, height - 1), fill=(40, 65, 95), width=2)
    for y in range(0, height, 64):
        draw.line((0, y, width - 1, y), fill=(40, 65, 95), width=2)
    draw.line((width // 2, 0, width // 2, height - 1), fill=(210, 50, 40), width=3)
    ideal_array = np.asarray(ideal)
    distorted = demo_distorted_input(ideal_array, camera)
    mx, my = build_map(camera)
    corrected, valid = sample_bilinear(distorted, mx, my)
    corrected = as_uint8(corrected)
    ideal.save(out_dir / "01_ideal.png")
    Image.fromarray(distorted).save(out_dir / "02_distorted_synthetic.png")
    Image.fromarray(corrected).save(out_dir / "03_corrected.png")
    Image.fromarray(valid.astype(np.uint8) * 255).save(out_dir / "valid_mask.png")
    panel = Image.new("RGB", (width * 3, height + 32), "white")
    labels = ["IDEAL / synthetic target", "INPUT / synthetic lens distortion", "OUTPUT / corrected reference"]
    for i, (array, label) in enumerate(zip([ideal_array, distorted, corrected], labels)):
        panel.paste(Image.fromarray(array), (i * width, 32))
        ImageDraw.Draw(panel).text((i * width + 8, 8), label, fill="black")
    panel.save(out_dir / "comparison.png")
    np.savez_compressed(out_dir / "reference_maps.npz", map_x=mx, map_y=my, valid=valid)
    metadata = export_grid(camera, out_dir, step, frac_bits)
    print(json.dumps({"out_dir": str(out_dir.resolve()), "synthetic_only": True,
                      "lut_bytes": metadata["memory_bytes"],
                      "grid_error_max_px": metadata["max_coordinate_error_px"]}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("demo", "remap", "export"):
        p = sub.add_parser(command)
        p.add_argument("--camera", type=Path, required=True)
        p.add_argument("--out", type=Path, required=True)
        if command == "remap":
            p.add_argument("--image", type=Path, required=True)
        else:
            p.add_argument("--step", type=int, default=32)
            p.add_argument("--frac-bits", type=int, default=8)
    args = parser.parse_args()
    camera = Camera.load(args.camera)
    if args.command == "demo":
        run_demo(camera, args.out, args.step, args.frac_bits)
    elif args.command == "export":
        print(json.dumps(export_grid(camera, args.out, args.step, args.frac_bits), indent=2))
    else:
        image = Image.open(args.image).convert("RGB")
        if image.size != camera.size:
            parser.error("input image size differs from calibration; do not silently resize or reuse intrinsics")
        mx, my = build_map(camera)
        corrected, valid = sample_bilinear(np.asarray(image), mx, my)
        args.out.mkdir(parents=True, exist_ok=True)
        Image.fromarray(as_uint8(corrected)).save(args.out / "corrected.png")
        Image.fromarray(valid.astype(np.uint8) * 255).save(args.out / "valid_mask.png")
        np.savez_compressed(args.out / "reference_maps.npz", map_x=mx, map_y=my, valid=valid)
        print(f"Output: {args.out.resolve()}")


if __name__ == "__main__":
    main()
