# -*- coding: utf-8 -*-
r"""
rectify_screen.py -- 把"拍屏幕"的照片还原成 1280x720 的相机原始帧

为什么需要：板子输出 1280x720，但屏幕是 1280x800 且当前是【拉伸铺满】模式
（垂直 x1.111），直接标定会把 k1 带偏约 9%。把屏幕显示区的四个角映射回
1280x720 矩形，等于同时做掉：① 拉伸 ② 手机拍屏幕的透视。
之后 calibrate.py 看到的就是"正交、等比"的相机帧。

用法：
    # 自动检测四角（屏幕显示区是最亮的大矩形）
    python rectify_screen.py calib_raw\new\*.jpg --out calib_raw\rect

    # 自动检测失败时，手动点四角（顺序：左上 右上 右下 左下，点完按 Enter）
    python rectify_screen.py calib_raw\new\p1.jpg --out calib_raw\rect --manual

输出：calib_raw\rect\<原名>_1280x720.png
检查：每张输出都必须是 1280x720；若四角没框准，图会歪/缺边，重拍或用 --manual
"""
import argparse
import glob
import os
import sys

import cv2
import numpy as np

OUT_W, OUT_H = 1280, 720


def order_quad(pts):
    """把 4 个点排成 左上 右上 右下 左下。"""
    pts = np.asarray(pts, dtype=np.float32).reshape(4, 2)
    s = pts.sum(axis=1)
    d = np.diff(pts, axis=1).ravel()
    tl = pts[np.argmin(s)]
    br = pts[np.argmax(s)]
    tr = pts[np.argmin(d)]
    bl = pts[np.argmax(d)]
    return np.array([tl, tr, br, bl], dtype=np.float32)


def auto_quad(img):
    """屏幕显示区 = 最亮的大矩形：Otsu 阈值 + 最大轮廓 + 多边形逼近。"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    _, th = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    th = cv2.morphologyEx(th, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    cnts, _ = cv2.findContours(th, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return None
    c = max(cnts, key=cv2.contourArea)
    if cv2.contourArea(c) < 0.05 * img.shape[0] * img.shape[1]:
        return None
    peri = cv2.arcLength(c, True)
    for eps in (0.02, 0.03, 0.05, 0.08):
        approx = cv2.approxPolyDP(c, eps * peri, True)
        if len(approx) == 4:
            return order_quad(approx.reshape(4, 2))
    return order_quad(cv2.boxPoints(cv2.minAreaRect(c)))



def auto_quad_texture(img):
    """屏幕显示区 = 画面里【有纹理】的大矩形。
    背景那块白色泡沫板很亮但是平的（局部对比度低），屏幕内容有细节 -> 用纹理区分。"""
    h, w = img.shape[:2]
    sc = 4
    small = cv2.resize(img, (w // sc, h // sc), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    mag = cv2.magnitude(gx, gy)
    mag = cv2.GaussianBlur(mag, (7, 7), 0)
    thr = max(12.0, float(np.percentile(mag, 55)))
    mask = (mag > thr).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    mask = cv2.dilate(mask, np.ones((9, 9), np.uint8))
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return None
    c = max(cnts, key=cv2.contourArea)
    if cv2.contourArea(c) < 0.04 * mask.size:
        return None
    (_, _), (rw, rh), ang = cv2.minAreaRect(c)
    if rw < 40 or rh < 25:
        return None
    quad = cv2.boxPoints(((0, 0), (0, 0), 0))  # placeholder
    box = cv2.boxPoints(cv2.minAreaRect(c)) * sc
    return order_quad(box)



def auto_quad_bezel(img):
    """屏幕 = 被【黑色边框】围住的亮区。
    做法：逐行找最长的连续亮段，并要求亮段两端外侧 8px 内有足够多的暗像素；
    逐列同理，取交集。这样能排除背景那块白泡沫（它两端不是暗的）。"""
    h, w = img.shape[:2]
    sc = 3
    small = cv2.resize(img, (w // sc, h // sc), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    hs, ws = gray.shape
    hi = float(np.percentile(gray, 90))
    lo = float(np.percentile(gray, 25))
    thr_b = max(90.0, (hi + lo) * 0.5)   # 亮
    thr_d = max(45.0, lo * 0.85)         # 暗

    def scan(vals, thr_dark):
        """返回 (起, 止) 或 None：最长亮段且两端有暗"""
        bright = vals > thr_b
        best = (0, -1)
        i = 0
        n = len(vals)
        while i < n:
            if not bright[i]:
                i += 1
                continue
            j = i
            while j < n and bright[j]:
                j += 1
            if j - i > best[1] - best[0]:
                l_dark = int(np.sum(vals[max(0, i - 8):i] < thr_dark)) if i > 0 else 0
                r_dark = int(np.sum(vals[j:min(n, j + 8)] < thr_dark)) if j < n else 0
                if (l_dark >= 2 or i <= 2) and (r_dark >= 2 or j >= n - 2):
                    best = (i, j - 1)
            i = j
        return best if best[1] > best[0] else None

    rows = []
    for y in range(hs):
        r = scan(gray[y, :], thr_d)
        if r:
            rows.append((y, r[0], r[1]))
    if len(rows) < hs // 6:
        return None
    ys = [r[0] for r in rows]
    y0, y1 = min(ys), max(ys)
    # 用中间 60% 的行决定左右边界，避免圆角/反光干扰
    mid = [r for r in rows if y0 + 0.2 * (y1 - y0) < r[0] < y1 - 0.2 * (y1 - y0)]
    if not mid:
        mid = rows
    x0 = int(np.median([r[1] for r in mid]))
    x1 = int(np.median([r[2] for r in mid]))

    cols = []
    for x in range(x0, x1 + 1):
        r = scan(gray[:, x], thr_d)
        if r:
            cols.append((x, r[0], r[1]))
    if len(cols) > 10:
        vy = sorted([r[1] for r in cols] + [r[2] for r in cols])
        y0b = int(np.median([r[1] for r in cols]))
        y1b = int(np.median([r[2] for r in cols]))
        if y1b > y0b:
            y0, y1 = y0b, y1b

    if x1 - x0 < 40 or y1 - y0 < 25:
        return None
    quad = np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], dtype=np.float32) * sc
    return order_quad(quad)



def auto_quad_hough(img):
    """用长直线找屏幕边框（bezel 内沿是强直线边）。
    取最靠上的长横线、最靠下的长横线、最靠左/右的长竖线，组成矩形。"""
    h, w = img.shape[:2]
    sc = 2
    small = cv2.resize(img, (w // sc, h // sc), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(gray, 40, 120)
    edges = cv2.dilate(edges, np.ones((3, 3), np.uint8))
    hs, ws = edges.shape
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, threshold=60,
                            minLineLength=int(0.28 * ws), maxLineGap=int(0.04 * ws))
    if lines is None:
        return None
    horiz, vert = [], []
    for l in lines.reshape(-1, 4):
        x1, y1, x2, y2 = [float(v) for v in l]
        dx, dy = x2 - x1, y2 - y1
        ang = abs(np.degrees(np.arctan2(dy, dx)))
        length = np.hypot(dx, dy)
        if ang < 22 or ang > 158:
            horiz.append((min(y1, y2), length, min(x1, x2), max(x1, x2)))
        elif 68 < ang < 112:
            vert.append((min(x1, x2), length, min(y1, y2), max(y1, y2)))
    if len(horiz) < 2 or len(vert) < 2:
        return None
    ys = np.array([t[0] for t in horiz])
    xs = np.array([t[0] for t in vert])
    # 取 10%/90% 分位，避免噪点线
    y0 = int(np.percentile(ys, 8))
    y1 = int(np.percentile(ys, 92))
    x0 = int(np.percentile(xs, 8))
    x1 = int(np.percentile(xs, 92))
    bw, bh = x1 - x0, y1 - y0
    if bw < 0.25 * ws or bh < 0.15 * hs:
        return None
    ar = bw / max(bh, 1)
    if not (1.15 <= ar <= 2.4):
        return None
    quad = np.array([[x0, y0], [x1, y0], [x1, y1], [x0, y1]], dtype=np.float32) * sc
    return order_quad(quad)


def manual_quad(img):
    """手动点四个角：左上 右上 右下 左下，点完回车。"""
    scaled = img.copy()
    maxw = 1400
    scale = min(1.0, maxw / img.shape[1])
    if scale < 1.0:
        scaled = cv2.resize(img, None, fx=scale, fy=scale)
    pts = []

    def on_mouse(event, x, y, flags, param):
        if event == cv2.EVENT_LBUTTONDOWN and len(pts) < 4:
            pts.append((int(x / scale), int(y / scale)))
            cv2.circle(scaled, (x, y), 6, (0, 0, 255), -1)
            cv2.putText(scaled, str(len(pts)), (x + 8, y - 8),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
            cv2.imshow('click 4 corners: TL TR BR BL, then Enter', scaled)

    cv2.imshow('click 4 corners: TL TR BR BL, then Enter', scaled)
    cv2.setMouseCallback('click 4 corners: TL TR BR BL, then Enter', on_mouse)
    cv2.waitKey(0)
    cv2.destroyAllWindows()
    if len(pts) != 4:
        raise SystemExit('需要正好 4 个点，实际 %d' % len(pts))
    return np.array(pts, dtype=np.float32)


def rectify(img, quad):
    dst = np.array([[0, 0], [OUT_W - 1, 0], [OUT_W - 1, OUT_H - 1], [0, OUT_H - 1]], dtype=np.float32)
    M = cv2.getPerspectiveTransform(quad, dst)
    return cv2.warpPerspective(img, M, (OUT_W, OUT_H), flags=cv2.INTER_CUBIC)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('images', nargs='+')
    ap.add_argument('--out', default='calib_raw/rect')
    ap.add_argument('--manual', action='store_true', help='手动点四角')
    ap.add_argument('--debug', action='store_true', help='把检测到的四角画出来存一份，便于检查')
    ap.add_argument('--method', default='hough', choices=['hough','bezel','texture','bright'], help='屏幕四角检测方法')
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    files = []
    for pat in a.images:
        files.extend(sorted(glob.glob(pat)) if any(ch in pat for ch in '*?[') else [pat])
    if not files:
        raise SystemExit('没有匹配到图片')

    n_ok = 0
    for f in files:
        img = cv2.imread(f)
        if img is None:
            print('SKIP(读不出) ' + f)
            continue
        if a.manual:
            quad = manual_quad(img)
        else:
            if a.method == 'hough':
                quad = auto_quad_hough(img)
            elif a.method == 'bezel':
                quad = auto_quad_bezel(img)
            elif a.method == 'texture':
                quad = auto_quad_texture(img)
            else:
                quad = auto_quad(img)
            if quad is None and a.method != 'bright':
                quad = auto_quad(img)
            if quad is None:
                print('自动检测失败，跳过（可加 --manual）：' + f)
                continue
        out = rectify(img, quad)
        base = os.path.splitext(os.path.basename(f))[0]
        dst = os.path.join(a.out, base + '_1280x720.png')
        cv2.imwrite(dst, out)
        if a.debug:
            dbg = img.copy()
            cv2.polylines(dbg, [quad.astype(np.int32)], True, (0, 0, 255), 3)
            cv2.imwrite(os.path.join(a.out, base + '_quad.png'), dbg)
        n_ok += 1
        print('OK %s -> %s   quad=%s' % (f, dst, quad.astype(int).tolist()))

    print('\n完成 %d / %d 张，输出在 %s' % (n_ok, len(files), a.out))
    if n_ok:
        print('下一步：python tools\\calibrate.py %s\\*_1280x720.png --pattern 11x8 --square 30 --out calib_raw\\params_final.json' % a.out)


if __name__ == '__main__':
    sys.exit(main())
