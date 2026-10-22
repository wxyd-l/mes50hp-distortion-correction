"""Brown-Conrady inverse sampling; no precomputed map is used by RTL.

The floating model is independent of OpenCV's map builder. The fixed model
implements the published RTL arithmetic, including truncation after each multiply.
"""
from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np

Q = 24
ONE = 1 << Q


def validate(config):
    size = config["image_size"]
    if len(size) != 2 or any(type(v) is not int or not 1 <= v <= 65535 for v in size):
        raise ValueError("image_size must be [width, height], positive integers <= 65535")
    for name in ("camera_matrix", "output_camera_matrix"):
        k = np.asarray(config.get(name, config["camera_matrix"]), dtype=float)
        if k.shape != (3, 3) or not np.isfinite(k).all():
            raise ValueError(f"invalid {name}")
        if k[0, 0] <= 0 or k[1, 1] <= 0 or not np.allclose(k[[0, 1, 2, 2, 2], [1, 0, 0, 1, 2]], [0, 0, 0, 0, 1]):
            raise ValueError("only positive-focal-length, zero-skew pinhole matrices are supported")
    d = np.asarray(config["distortion"], dtype=float)
    if d.shape != (4,) or not np.isfinite(d).all():
        raise ValueError("distortion must be [k1,k2,p1,p2]; k3 is fixed to zero")
    t = np.asarray(config.get("output_to_ideal", [[1, 0, 0], [0, 1, 0]]), dtype=float)
    if t.shape not in ((2, 3), (3, 3)) or not np.isfinite(t).all():
        raise ValueError("output_to_ideal must be an invertible 2x3 affine or 3x3 projective transform")
    full = np.vstack([t, [0, 0, 1]]) if t.shape == (2, 3) else t
    if np.linalg.matrix_rank(full) != 3:
        raise ValueError("output_to_ideal must be invertible")
    if type(config.get("projective_positive_depth", False)) is not bool:
        raise ValueError("projective_positive_depth must be boolean")
    return config


def load_config(path):
    return validate(json.loads(Path(path).read_text(encoding="utf-8")))


def is_projective(config):
    return np.asarray(config.get("output_to_ideal", [[1, 0, 0], [0, 1, 0]])).shape == (3, 3)


def normalized_homography(config):
    validate(config)
    ko = np.asarray(config.get("output_camera_matrix", config["camera_matrix"]), dtype=float)
    t = np.asarray(config.get("output_to_ideal", [[1, 0, 0], [0, 1, 0]]), dtype=float)
    if t.shape == (2, 3):
        t = np.vstack([t, [0, 0, 1]])
    return np.linalg.inv(ko) @ t


def normalized_affine(config):
    return normalized_homography(config)[:2]


def check_projective_depth(z, config):
    if np.any(z == 0) or (np.min(z) < 0 < np.max(z)):
        raise ValueError("projective denominator reaches or crosses the horizon; adjust pose / output field of view")
    if config.get("projective_positive_depth", False) and np.any(z <= 0):
        raise ValueError("pose points behind the source camera (nonpositive depth)")


def float_map(config):
    a = normalized_homography(config)
    w, h = config["image_size"]
    u, v = np.meshgrid(np.arange(w, dtype=float), np.arange(h, dtype=float))
    z = a[2, 0] * u + a[2, 1] * v + a[2, 2]
    check_projective_depth(z, config)
    x, y = ((a[i, 0] * u + a[i, 1] * v + a[i, 2])/z for i in range(2))
    k1, k2, p1, p2 = config["distortion"]
    r2 = x*x + y*y
    s = 1 + k1*r2 + k2*r2*r2
    xd = x*s + 2*p1*x*y + p2*(r2 + 2*x*x)
    yd = y*s + p1*(r2 + 2*y*y) + 2*p2*x*y
    k = np.asarray(config["camera_matrix"])
    return xd*k[0, 0]+k[0, 2], yd*k[1, 1]+k[1, 2]


def opencv_map(config):
    """OpenCV ground truth, including the same inverse affine transform."""
    validate(config)
    k = np.asarray(config["camera_matrix"], dtype=float)
    ko = np.asarray(config.get("output_camera_matrix", k), dtype=float)
    t = ko @ normalized_homography(config)
    # initUndistortRectifyMap applies inverse(newK * R). R below therefore
    # yields inverse(newK) * T, exactly the desired normalized inverse map.
    r = np.linalg.inv(ko) @ np.linalg.inv(t) @ ko
    return cv2.initUndistortRectifyMap(k, np.r_[config["distortion"], 0.0], r, ko,
                                     tuple(config["image_size"]), cv2.CV_32FC1)


def checked32(value, stage):
    value = np.asarray(value, dtype=np.int64)
    if np.any(value < -(1 << 31)) or np.any(value >= (1 << 31)):
        raise ValueError(f"signed32 overflow at {stage}; reduce field of view / transform extent")
    return value


def quantize(value, frac, name):
    value = np.asarray(value, dtype=float)
    if not np.isfinite(value).all() or np.any(np.abs(value) > 2**(32-frac)):
        raise ValueError(f"invalid fixed-point value: {name}")
    # Ties to even, used only for coefficient export. Runtime uses arithmetic shifts.
    return checked32(np.rint(value * (1 << frac)).astype(np.int64), name)


def fixed_parameters(config):
    a = quantize(normalized_affine(config), 28, "normalized affine Q4.28")
    d = quantize(config["distortion"], 24, "distortion Q8.24")
    k = np.asarray(config["camera_matrix"])
    intrinsics = quantize([k[0, 0], k[1, 1], k[0, 2], k[1, 2]], 16, "intrinsics Q16.16")
    result = {**{f"a{i}{j}": int(a[i,j]) for i in range(2) for j in range(3)},
            **dict(zip(("k1", "k2", "p1", "p2"), map(int, d))),
            **dict(zip(("fx", "fy", "cx", "cy"), map(int, intrinsics)))}
    if is_projective(config):
        bottom = quantize(normalized_homography(config)[2], 28, "homogeneous denominator Q4.28")
        result.update({f"a2{j}": int(bottom[j]) for j in range(3)})
    return result


def fixed_map(config):
    p = fixed_parameters(config)
    w, h = config["image_size"]
    u, v = np.meshgrid(np.arange(w, dtype=np.int64), np.arange(h, dtype=np.int64))
    def add(a, b, label):
        return checked32(a+b, label)
    def mul(a, b, label):
        return checked32((a*b) >> 24, label)
    x, y = (checked32((p[f"a{i}0"]*u+p[f"a{i}1"]*v+p[f"a{i}2"]) >> 4, f"xy{i}") for i in range(2))
    if is_projective(config):
        z = checked32((p["a20"]*u+p["a21"]*v+p["a22"]) >> 4, "homogeneous denominator")
        check_projective_depth(z, config)
        # RTL restoring division truncates toward zero. The numerator shift
        # fits signed64 because each input has first been checked as signed32.
        def divide(n):
            magnitude = (np.abs(n) << 24) // np.abs(z)
            return checked32(np.where((n < 0) != (z < 0), -magnitude, magnitude), "homogeneous quotient")
        x, y = divide(x), divide(y)
    x2, y2, xy = mul(x,x,"x2"), mul(y,y,"y2"), mul(x,y,"xy")
    r2 = add(x2,y2,"r2")
    r4 = mul(r2,r2,"r4")
    s = add(add(ONE,mul(p["k1"],r2,"k1r2"),"1+k1r2"),mul(p["k2"],r4,"k2r4"),"scale")
    tx = add(checked32(mul(p["p1"],xy,"p1xy")*2,"2p1xy"),mul(p["p2"],add(r2,checked32(2*x2,"2x2"),"r2+2x2"),"p2tx"),"tx")
    ty = add(mul(p["p1"],add(r2,checked32(2*y2,"2y2"),"r2+2y2"),"p1ty"),checked32(mul(p["p2"],xy,"p2xy")*2,"2p2xy"),"ty")
    xd, yd = add(mul(x,s,"xs"),tx,"xd"), add(mul(y,s,"ys"),ty,"yd")
    sx = add(checked32((xd*p["fx"]) >> 24,"fx*xd"),p["cx"],"source_x")
    sy = add(checked32((yd*p["fy"]) >> 24,"fy*yd"),p["cy"],"source_y")
    return sx, sy


def bilinear_float(image, sx, sy):
    """True floating bilinear with per-neighbor constant-zero border."""
    h, w = image.shape[:2]
    x0, y0 = np.floor(sx).astype(np.int64), np.floor(sy).astype(np.int64)
    dx, dy = sx-x0, sy-y0
    result = np.zeros(sx.shape + image.shape[2:], dtype=float)
    for ox, oy, weight in ((0,0,(1-dx)*(1-dy)),(1,0,dx*(1-dy)),(0,1,(1-dx)*dy),(1,1,dx*dy)):
        xi, yi = x0+ox, y0+oy
        valid = (xi>=0)&(xi<w)&(yi>=0)&(yi<h)
        pixels = image[np.clip(yi,0,h-1),np.clip(xi,0,w-1)].astype(float)
        ww = weight*valid
        result += pixels * (ww[...,None] if image.ndim == 3 else ww)
    return np.clip(np.floor(result+0.5),0,255).astype(np.uint8)


def synthetic_config(width=64, height=48):
    return {"schema_version": 1, "provenance": {"kind": "synthetic", "warning": "TEST ONLY; not camera calibration"},
            "image_size": [width,height],
            "camera_matrix": [[width*0.8,0,(width-1)/2],[0,width*0.8,(height-1)/2],[0,0,1]],
            "distortion": [-0.18,0.035,0.002,-0.001]}


def synthetic_image(width=64, height=48):
    x,y = np.meshgrid(np.arange(width),np.arange(height))
    return np.stack([(x*7+y*3)%256,((x//4+y//4)%2)*255,(x*3+y*11)%256],axis=-1).astype(np.uint8)


def bilinear_fixed(image, sx_q16, sy_q16):
    """8-bit fractional weights; integer round-to-nearest once after four taps."""
    h,w = image.shape[:2]
    x0,y0 = sx_q16 >> 16,sy_q16 >> 16
    dx,dy = (sx_q16 & 65535) >> 8,(sy_q16 & 65535) >> 8
    result = np.zeros(sx_q16.shape+image.shape[2:],dtype=np.int64)
    for ox,oy,weight in ((0,0,(256-dx)*(256-dy)),(1,0,dx*(256-dy)),(0,1,(256-dx)*dy),(1,1,dx*dy)):
        xi,yi = x0+ox,y0+oy
        valid = (xi>=0)&(xi<w)&(yi>=0)&(yi<h)
        pixels = image[np.clip(yi,0,h-1),np.clip(xi,0,w-1)].astype(np.int64)
        ww = weight*valid
        result += pixels*(ww[...,None] if image.ndim == 3 else ww)
    return ((result+32768) >> 16).astype(np.uint8)


def compare(config, image):
    if list(image.shape[1::-1]) != config["image_size"]:
        raise ValueError("image resolution must exactly match calibration; no implicit resize")
    sx,sy = float_map(config)
    cx,cy = opencv_map(config)
    qx,qy = fixed_map(config)
    fx,fy = qx/65536.,qy/65536.
    float_pixels = bilinear_float(image,sx,sy)
    fixed_pixels = bilinear_fixed(image,qx,qy)
    cv_pixels = cv2.remap(image,cx,cy,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
    def error(a,b):
        e = np.asarray(a,dtype=float)-np.asarray(b,dtype=float)
        return {"max_abs": float(np.max(np.abs(e))), "rms": float(np.sqrt(np.mean(e*e)))}
    center_valid = (sx>=0)&(sx<=image.shape[1]-1)&(sy>=0)&(sy<=image.shape[0]-1)
    # A center rectangle is a conservative, reproducible ROI proposal, not an
    # optimization over arbitrary disconnected validity regions.
    h,w = center_valid.shape
    left,right,top,bottom = 0,w,0,h
    while left < right and top < bottom and not center_valid[top:bottom,left:right].all():
        counts = [np.count_nonzero(~center_valid[top:bottom,left]),np.count_nonzero(~center_valid[top:bottom,right-1]),
                  np.count_nonzero(~center_valid[top,left:right]),np.count_nonzero(~center_valid[bottom-1,left:right])]
        worst = int(np.argmax(counts))
        if not counts[worst]:
            # Interior invalid pixels: no trustworthy rectangle from this heuristic.
            left=right=top=bottom=0
            break
        if worst == 0: left += 1
        elif worst == 1: right -= 1
        elif worst == 2: top += 1
        else: bottom -= 1
    return {"provenance": config.get("provenance", {"kind":"unspecified"}),
            "float_vs_opencv_coordinates_pixels": error(np.stack([sx,sy]),np.stack([cx,cy])),
            "fixed_vs_float_coordinates_pixels": error(np.stack([fx,fy]),np.stack([sx,sy])),
            "fixed_coordinates_vs_float_image_u8": error(fixed_pixels,float_pixels),
            "opencv_vs_float_bilinear_u8": error(cv_pixels,float_pixels),
            "opencv_note": "INTER_LINEAR quantizes interpolation fractions; pixel differences alone do not isolate mapping errors",
            "valid_center_fraction": float(np.mean(center_valid)),
            "suggested_valid_roi_xywh": [left,top,right-left,bottom-top],
            "roi_note": "Conservative greedy rectangle for this configuration; crop changes field of view. Bilinear interpolation cannot reconstruct scene content outside the captured field of view."}, fixed_pixels
