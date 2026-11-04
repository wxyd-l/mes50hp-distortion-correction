# -*- coding: utf-8 -*-
r"""棋盘格标定 -> 真实畸变参数 -> FPGA 可用的定点参数 + 行缓存深度估算。

用法:
    set PYTHONPATH=D:\ai文档\.pylibs
    python calibrate.py <img1> [img2 ...]  [--pattern 9x6] [--square 30] [--out params.json]

输出:
    params.json  含 fx,fy,cx,cy,k1,k2,p1,p2、像素域系数 K1/K2、|dv|max、建议行缓存深度
"""
import glob, json, math, os, sys
import numpy as np
import cv2

IMG_W, IMG_H = 1280, 720        # 目标输出分辨率(= 采集分辨率)


# ---------------------------------------------------------------- 标定
def object_points(pattern, square):
    nx, ny = pattern
    objp = np.zeros((nx * ny, 3), np.float32)
    objp[:, :2] = np.mgrid[0:nx, 0:ny].T.reshape(-1, 2) * float(square)
    return objp


def find_corners(gray, pattern):
    flags = (cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE)
    ok, corners = cv2.findChessboardCorners(gray, pattern, flags)
    if not ok:
        try:
            ok, corners = cv2.findChessboardCornersSB(
                gray, pattern, flags=cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY)
        except Exception:
            ok = False
    if not ok:
        return None
    corners = np.asarray(corners, np.float32).reshape(-1, 1, 2)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 80, 1e-5)
    return cv2.cornerSubPix(gray, corners, (11, 11), (-1, -1), crit)


def calibrate(paths, pattern, square):
    objp = object_points(pattern, square)
    obj_pts, img_pts, used, failed = [], [], [], []
    for p in paths:
        img = cv2.imread(p, cv2.IMREAD_GRAYSCALE)
        if img is None:
            failed.append((p, "unreadable")); continue
        c = find_corners(img, pattern)
        if c is None:
            failed.append((p, "corners not found")); continue
        obj_pts.append(objp)
        img_pts.append(c)
        used.append(p)
    if not used:
        raise SystemExit("没有一张图能找到棋盘格角点。请检查 --pattern（内角点数）和图像清晰度。")
    if len(used) == 1:
        print("[warn] 只有 1 张有效图，标定结果不稳定；建议 >=5 张多姿态图像。")

    flags = (cv2.CALIB_FIX_K3 | cv2.CALIB_ZERO_TANGENT_DIST) if len(used) < 3 else cv2.CALIB_FIX_K3
    h0, w0 = cv2.imread(used[0], cv2.IMREAD_GRAYSCALE).shape[:2]
    rms, K, dist, rvecs, tvecs = cv2.calibrateCamera(
        obj_pts, img_pts, (w0, h0), None, None, flags=flags)

    # 逐图重投影误差
    per_img = []
    for i, p in enumerate(used):
        proj, _ = cv2.projectPoints(obj_pts[i], rvecs[i], tvecs[i], K, dist)
        e = cv2.norm(img_pts[i], proj, cv2.NORM_L2) / math.sqrt(len(proj))
        per_img.append({"image": os.path.basename(p), "rms_px": round(float(e), 4)})
    return dict(rms=float(rms), K=K, dist=dist, used=used, failed=failed, per_img=per_img)


# ------------------------------------------------- 畸变位移与行缓存深度
def displacement(fx, fy, cx, cy, k1, k2, p1, p2, w=IMG_W, h=IMG_H):
    """对每个输出像素求其源坐标, 返回 |dv|,|du| 的极值(像素)。"""
    u = np.arange(w, dtype=np.float64)[None, :]
    v = np.arange(h, dtype=np.float64)[:, None]
    xn = (u - cx) / fx
    yn = (v - cy) / fy
    r2 = xn * xn + yn * yn
    rad = 1.0 + k1 * r2 + k2 * r2 * r2
    xd = xn * rad + 2.0 * p1 * xn * yn + p2 * (r2 + 2.0 * xn * xn)
    yd = yn * rad + p1 * (r2 + 2.0 * yn * yn) + 2.0 * p2 * xn * yn
    ud = fx * xd + cx
    vd = fy * yd + cy
    dv = np.abs(vd - v)
    du = np.abs(ud - u)
    return float(dv.max()), float(du.max())


def parse_args(argv):
    args, opts, i = [], {}, 1
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            body = a[2:]
            if "=" in body:
                k, v = body.split("=", 1)
            else:
                k = body
                if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                    i += 1
                    v = argv[i]
                else:
                    v = "1"
            opts[k] = v
        else:
            args.append(a)
        i += 1
    return args, opts


def main(argv):
    args, opts = parse_args(argv)

    pattern = tuple(int(x) for x in str(opts.get("pattern", "9x6")).lower().split("x"))
    square = float(opts.get("square", 30))
    out_path = str(opts.get("out", "params.json"))

    paths = []
    for a in args:
        paths.extend(sorted(glob.glob(a)) or [a])
    if not paths:
        raise SystemExit(__doc__)

    r = calibrate(paths, pattern, square)
    fx, fy = r["K"][0, 0], r["K"][1, 1]
    cx, cy = r["K"][0, 2], r["K"][1, 2]
    k1, k2, p1, p2 = r["dist"].ravel()[:4]

    dv_max, du_max = displacement(fx, fy, cx, cy, k1, k2, p1, p2)
    rows = int(math.ceil(dv_max)) + 2          # 双线性需要 +1, 余 +1
    # 720p RGB565: 一行 = 1280*16 = 20480 bit -> 2 块 GTP_DRM18K (=36864 bit)
    dram_per_row = 2
    dram_avail = 115
    rows_bram_cap = dram_avail // dram_per_row

    params = {
        "source": "real-camera calibration",
        "tool": "OpenCV %s calibrateCamera" % cv2.__version__,
        "pattern_inner": list(pattern),
        "square_mm": square,
        "image_size": [IMG_W, IMG_H],
        "K": {"fx": round(float(fx), 4), "fy": round(float(fy), 4),
              "cx": round(float(cx), 4), "cy": round(float(cy), 4)},
        "dist": {"k1": round(float(k1), 6), "k2": round(float(k2), 6),
                 "p1": round(float(p1), 6), "p2": round(float(p2), 6)},
        "rms_reprojection_px": round(r["rms"], 4),
        "per_image_rms": r["per_img"],
        "failed": r["failed"],
        "fpga_pixel_domain": {
            "K1": float(k1) / fx ** 2,
            "K2": float(k2) / fx ** 4,
            "note": "u_d=(u-cx)*(1+K1*Rp2+K2*Rp4)+cx ; Rp2=(u-cx)^2+(v-cy)^2",
        },
        "line_buffer": {
            "dv_max_px": round(dv_max, 2),
            "du_max_px": round(du_max, 2),
            "rows_needed": rows,
            "dram18k_per_row": dram_per_row,
            "dram18k_needed": rows * dram_per_row,
            "dram18k_available": dram_avail,
            "fits_in_bram": bool(rows * dram_per_row <= dram_avail),
            "fallback": "" if rows * dram_per_row <= dram_avail else "改用 DDR3 行缓存",
        },
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(params, f, indent=2, ensure_ascii=False)

    # ---------------- 打印 ----------------
    print("=" * 62)
    print("标定结果   RMS 重投影误差 = %.3f px   (图 %d 张, 失败 %d)"
          % (r["rms"], len(r["used"]), len(r["failed"])))
    print("  fx=%.2f  fy=%.2f   cx=%.2f  cy=%.2f" % (fx, fy, cx, cy))
    print("  k1=%.6f  k2=%.6f  p1=%.6f  p2=%.6f" % (k1, k2, p1, p2))
    print("  像素域: K1=%.6e   K2=%.6e" % (k1 / fx ** 2, k2 / fx ** 4))
    for d in r["per_img"]:
        print("    %-18s rms=%.3f px" % (d["image"], d["rms_px"]))
    for p, why in r["failed"]:
        print("    [skip] %-18s %s" % (os.path.basename(p), why))
    print("-" * 62)
    print("位移  |dv|max=%.1f px   |du|max=%.1f px" % (dv_max, du_max))
    print("行缓存  需要 %d 行 -> %d 块 DRM18K (可用 %d)   %s"
          % (rows, rows * dram_per_row, dram_avail,
             "OK 放得下" if rows * dram_per_row <= dram_avail else "超出, 需改 DDR 行缓存"))
    print("已写出 %s" % out_path)
    print("=" * 62)


if __name__ == "__main__":
    main(sys.argv)
