# -*- coding: utf-8 -*-
r"""
check_calib_shots.py -- 标定照片体检：哪些能用、覆盖了相机画面的哪些区域

为什么需要：findChessboardCorners 要求【整个棋盘】可见，被画面边缘切掉一张就废。
每拍一批就跑一遍，不用人工看图猜。

用法：
    python tools\check_calib_shots.py calib_raw\rect2\*_1280x720.png
    python tools\check_calib_shots.py calib_raw\raw3\*.jpg --rect --out calib_raw\rect3

    --rect   输入是原始照片（还没做屏幕校正），先调 rectify_screen 的自动检测
    --out    配合 --rect：校正好图存这里
    --save   把检测到的角点画在图上，存 <name>_corner.png 便于核对

输出：
    每张一行：OK/FAIL + 棋盘中心(占画面百分比) + 占画面面积% + 所在九宫格位置
    末尾：有效张数、五个关键区域（四角+中心）的覆盖情况、还缺什么
"""
import argparse
import glob
import os
import sys

import cv2
import numpy as np

PATTERN = (11, 8)          # 内角点 11x8，和 calibrate.py 保持一致
ZONES = ['左上', '上', '右上', '左', '中', '右', '左下', '下', '右下']
KEY = ['左上', '右上', '左下', '右下', '中']   # 畸变标定必须覆盖的 5 个区域


def flags():
    f = 0
    if hasattr(cv2, 'CALIB_CB_EXHAUSTIVE'):
        f |= cv2.CALIB_CB_EXHAUSTIVE
    if hasattr(cv2, 'CALIB_CB_ACCURACY'):
        f |= cv2.CALIB_CB_ACCURACY
    return f


def zone_of(cxn, cyn):
    """cxn/cyn 是 0~1 归一化中心位置；九宫格归类。"""
    cx_i = 0 if cxn < 1 / 3 else (2 if cxn > 2 / 3 else 1)
    cy_i = 0 if cyn < 1 / 3 else (2 if cyn > 2 / 3 else 1)
    return ZONES[cy_i * 3 + cx_i]


def detect(img):
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return cv2.findChessboardCorners(gray, PATTERN, flags())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('images', nargs='+')
    ap.add_argument('--rect', action='store_true', help='输入是原始照片，先做屏幕透视校正')
    ap.add_argument('--out', default='calib_raw/rect_chk')
    ap.add_argument('--save', action='store_true', help='存角点标注图')
    a = ap.parse_args()

    files = []
    for pat in a.images:
        files.extend(sorted(glob.glob(pat)) if any(c in pat for c in '*?[') else [pat])
    if not files:
        raise SystemExit('没有匹配到图片')

    rectify = None
    if a.rect:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import rectify_screen as R
        rectify = R
        os.makedirs(a.out, exist_ok=True)

    good = []
    zones_hit = {}
    for f in files:
        img = cv2.imread(f)
        if img is None:
            print('SKIP(读不出) %s' % f)
            continue
        name = os.path.splitext(os.path.basename(f))[0]
        if rectify is not None:
            quad = rectify.auto_quad(img)
            if quad is None:
                print('FAIL %-10s 屏幕四角检测失败（该张需要 --manual）' % name)
                continue
            img = rectify.rectify(img, quad)
            dst = os.path.join(a.out, name + '_1280x720.png')
            cv2.imwrite(dst, img)

        ok, corners = detect(img)
        h, w = img.shape[:2]
        if not ok:
            print('FAIL %-10s 棋盘不完整 / 找不到角点' % name)
            continue

        pts = corners.reshape(-1, 2)
        cxn, cyn = pts[:, 0].mean() / w, pts[:, 1].mean() / h
        (_, _), (bw, bh), _ = cv2.minAreaRect(pts)
        area_pct = 100.0 * bw * bh / (w * h)
        margin = min(pts[:, 0].min(), pts[:, 1].min(), w - 1 - pts[:, 0].max(), h - 1 - pts[:, 1].max())
        z = zone_of(cxn, cyn)
        warn = '' if margin > 20 else '  <-- 贴边(%0.0fpx)，不建议用' % margin
        print('OK   %-10s 中心(%3.0f%%,%3.0f%%) 占画面%4.0f%% 位置=%s%s' %
              (name, cxn * 100, cyn * 100, area_pct, z, warn))
        if margin > 20:
            good.append(name)
            zones_hit[z] = zones_hit.get(z, 0) + 1
        if a.save:
            vis = img.copy()
            cv2.drawChessboardCorners(vis, PATTERN, corners, ok)
            cv2.imwrite(os.path.join(a.out if rectify else os.path.dirname(f) or '.', name + '_corner.png'), vis)

    print('\n=== 汇总 %d 张输入，有效 %d 张 ===' % (len(files), len(good)))
    print('区域覆盖：' + ('、'.join('%s x%d' % (k, zones_hit[k]) for k in ZONES if k in zones_hit) or '无'))
    miss = [k for k in KEY if k not in zones_hit]
    if miss:
        print('还缺：' + '、'.join(miss) + '  —— 补拍时把棋盘放到相机画面的这些区域')
    if len(good) < 10:
        print('张数不足：有效 %d 张 < 10' % len(good))
    else:
        print('张数 OK（>=10），可以跑 calibrate.py')
    if good:
        print('\n可以直接喂给 calibrate.py 的这些：\n  ' + ' '.join(good))


if __name__ == '__main__':
    sys.exit(main())
