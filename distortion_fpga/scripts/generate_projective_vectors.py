"""Synthetic projective coordinate/frame and divider vectors, never calibration."""
from pathlib import Path
import copy
import json
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from software.geometry import pose_config, projective_parameters
from software.reference import bilinear_fixed, fixed_map, float_map, synthetic_config, synthetic_image


def write_hex(path, values, width=8):
    path.write_text("".join(f"{int(value)&((1<<(4*width))-1):0{width}x}\n" for value in values), encoding="ascii")


def generate(source=None, destination=None):
    out = Path(destination) if destination is not None else ROOT / "build" / "projective"
    out.mkdir(parents=True, exist_ok=True)
    base = synthetic_config()
    identity = copy.deepcopy(base)
    identity["camera_matrix"] = [[64,0,32],[0,64,24],[0,0,1]]
    identity["distortion"] = [0,0,0,0]
    identity["output_to_ideal"] = np.eye(3).tolist()
    pose = pose_config(base, yaw_degrees=13, pitch_degrees=-9, roll_degrees=7)
    negative = copy.deepcopy(pose)
    negative["projective_positive_depth"] = False
    negative["output_to_ideal"] = (-np.array(negative["output_to_ideal"])).tolist()
    plane = copy.deepcopy(base)
    plane["output_to_ideal"] = [[1.02,-.07,2.4],[.04,.98,-1.8],[.0012,-.0007,1.]]
    cases = [identity, pose, negative, plane]
    image = synthetic_image() if source is None else np.asarray(source, dtype=np.uint8)
    if image.shape != (48,64,3):
        raise ValueError("projective vectors require a 64x48 RGB source")
    params, pixels, coords, errors = [], [], [], []
    for config in cases:
        params.extend(projective_parameters(config).values())
        x,y = fixed_map(config)
        fx,fy = float_map(config)
        errors.append(float(max(np.max(np.abs(x/65536-fx)), np.max(np.abs(y/65536-fy)))))
        pixels.extend(bilinear_fixed(image,x,y).reshape(-1,3))
        coords.extend(((int(a)&0xffffffff)<<32)|(int(b)&0xffffffff) for a,b in zip(x.flat,y.flat))
    # Runtime bad configuration: all-zero denominator must retire every pixel,
    # mark overflow and perform no source reads. Strict software export rejects it.
    bad = list(projective_parameters(identity).values())
    bad[-3:] = [0,0,0]
    params.extend(bad)
    pixels.extend(np.zeros((64*48,3), dtype=np.uint8))
    write_hex(out/"parameters.mem", params)
    write_hex(out/"input_rgb.mem", (int(r)<<16|int(g)<<8|int(b) for r,g,b in image.reshape(-1,3)), 6)
    write_hex(out/"expected_rgb.mem", (int(r)<<16|int(g)<<8|int(b) for r,g,b in pixels), 6)
    write_hex(out/"coordinates.mem", coords, 16)
    (out/"cases.json").write_text(json.dumps({"provenance":"synthetic", "cases":cases,
        "runtime_failure_case":"zero denominator", "fixed_max_error_pixels":errors}, indent=2), encoding="utf-8")
    generate_divider(out)
    print(f"Generated synthetic projective vectors in {out}; max coordinate errors {errors}")
    return out


def generate_divider(out):
    rng = np.random.default_rng(93250)
    # Each row: u,a00,a02,a10,a12,a20,a22 (v terms zero), then expected error,x,y.
    rows = [
        [0,0,1<<28,0,-(1<<27),0,3<<27],  # positive and negative noninteger quotients
        [0,0,1<<28,0,-(1<<27),0,-(3<<27)],
        [0,0,1<<28,0,0,0,0],             # zero denominator
        [0,0,1<<28,0,-(1<<28),0,16],     # smallest represented positive depth -> overflow
        [16,-(1<<31),0,0,0,0,1<<28],     # exactly INT_MIN output is legal
        [16,-(1<<31),0,0,0,0,-(1<<28)],   # +128 exceeds signed Q8.24
        [65535,(1<<31)-1,0,0,0,0,1<<28],  # homogeneous sum overflow
        [0,0,-17,0,17,0,1<<28],          # negative pre-division arithmetic-shift rounding
    ]
    for _ in range(248):
        rows.append([int(rng.integers(0,32)), *map(int, rng.integers(-(1<<30), 1<<30, size=6))])
    packed=[]
    guarded_errors=[]
    for u,a00,a02,a10,a12,a20,a22 in rows:
        x,y,z = [(a*u+b)>>4 for a,b in ((a00,a02),(a10,a12),(a20,a22))]
        bad = any(v<-(1<<31) or v>=(1<<31) for v in (x,y,z)) or z==0
        qx=qy=0
        if not bad:
            qx = (abs(x)<<24)//abs(z) * (-1 if (x<0)!=(z<0) else 1)
            qy = (abs(y)<<24)//abs(z) * (-1 if (y<0)!=(z<0) else 1)
            bad = any(v<-(1<<31) or v>=(1<<31) for v in (qx,qy))
        # Check coordinates only for a valid quotient; failed result is retired.
        packed.extend([u,a00,a02,a10,a12,a20,a22,int(bad),qx if not bad else 0,qy if not bad else 0])
        guarded_errors.append(int(bad or z<0))
    write_hex(out/"divider.mem", packed)
    write_hex(out/"guarded_errors.mem", guarded_errors)


if __name__ == "__main__":
    generate()
