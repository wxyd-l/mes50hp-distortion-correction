# -*- coding: utf-8 -*-
r"""
calib_pipeline.py -- 标定一条龙：量裁剪框 -> 批量裁 1280x720 -> 标定 -> 换算成 RTL 整数

第 1 步（只做一次，每个批次一张）：量屏幕显示区
    python tools\calib_pipeline.py --pick raw2
    弹出该批第一张图，用鼠标拖一个框把【屏幕显示区】框住，松手后回车。
    程序会把它写进 calib_raw\crops.txt（同一批手机没动，所以整批通用）。

第 2 步：一条命令跑完
    python tools\calib_pipeline.py
    会依次：按 crops.txt 裁剪+缩放到 1280x720 -> 检查棋盘格 -> 标定 -> 打印 RTL 整数

批次：raw2 / raw3 / raw4 / raw5 / raw7（已筛过：切边的已剔除，raw6_far 不用）
"""
import argparse
import glob
import json
import os
import subprocess
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BATCHES = ['raw2', 'raw3', 'raw4', 'raw5', 'raw7']
CROPS = os.path.join(ROOT, 'calib_raw', 'crops.txt')
OUTDIR = os.path.join(ROOT, 'calib_raw', 'crop')
OUTW, OUTH = 1280, 720
PATTERN = (11, 8)
K1_APPLIED_Q24 = -2248147          # 板上已经施加的 k1（J/I 版）


def read_crops():
    d = {}
    if os.path.exists(CROPS):
        for ln in open(CROPS, encoding='utf-8'):
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            p = ln.replace(',', ' ').split()
            if len(p) == 5:
                d[p[0]] = tuple(int(v) for v in p[1:5])
    return d


def write_crop(batch, rect):
    d = read_crops()
    d[batch] = rect
    with open(CROPS, 'w', encoding='utf-8') as f:
        f.write('# batch  x  y  w  h   （屏幕显示区在照片里的裁剪框）\n')
        for b in BATCHES:
            if b in d:
                f.write('%s %d %d %d %d\n' % ((b,) + d[b]))
    print('已写入 %s' % CROPS)


def pick(batch):
    files = sorted(glob.glob(os.path.join(ROOT, 'calib_raw', batch, '*.jpg')))
    if not files:
        raise SystemExit('没有找到 calib_raw/%s/*.jpg' % batch)
    img = cv2.imread(files[0])
    h, w = img.shape[:2]
    sc = min(1.0, 1400.0 / w)
    show = cv2.resize(img, None, fx=sc, fy=sc) if sc < 1.0 else img.copy()
    state = {'p0': None, 'p1': None, 'drag': False}

    def on_mouse(ev, x, y, flags, param):
        if ev == cv2.EVENT_LBUTTONDOWN:
            state['p0'] = (x, y); state['drag'] = True
        elif ev == cv2.EVENT_MOUSEMOVE and state['drag']:
            state['p1'] = (x, y)
        elif ev == cv2.EVENT_LBUTTONUP:
            state['p1'] = (x, y); state['drag'] = False

    win = 'drag SCREEN AREA (%s) then press ENTER' % batch
    cv2.namedWindow(win, cv2.WINDOW_AUTOSIZE)
    cv2.setMouseCallback(win, on_mouse)
    while True:
        vis = show.copy()
        if state['p0'] and state['p1']:
            cv2.rectangle(vis, state['p0'], state['p1'], (0, 0, 255), 2)
        cv2.imshow(win, vis)
        k = cv2.waitKey(20) & 0xFF
        if k in (13, 10) and state['p0'] and state['p1']:
            break
        if k == 27:
            cv2.destroyAllWindows()
            raise SystemExit('取消')
    cv2.destroyAllWindows()
    x0, y0 = state['p0']; x1, y1 = state['p1']
    x = int(min(x0, x1) / sc); y = int(min(y0, y1) / sc)
    ww = int(abs(x1 - x0) / sc); hh = int(abs(y1 - y0) / sc)
    ar = ww / max(hh, 1)
    print('%s 裁剪框 = %d %d %d %d   (宽高比 %.3f，屏幕应该是 1.600~1.780)' % (batch, x, y, ww, hh, ar))
    if not (1.45 <= ar <= 1.95):
        print('  [!] 宽高比偏离 16:9 较多，可能没框准；屏幕若还是"铺满"模式，实际比例会是 1.78（1:1）或 1.60（铺满 1280x800）')
    write_crop(batch, (x, y, ww, hh))


def read_quads():
    p = os.path.join(ROOT, 'calib_raw', 'quads.json')
    if not os.path.exists(p):
        return {}
    import json as _j
    try:
        return _j.load(open(p))
    except Exception:
        return {}


def crop_all():
    crops = read_crops()
    quads = read_quads()
    os.makedirs(OUTDIR, exist_ok=True)
    total = 0
    for b in BATCHES:
        if b not in crops and b not in quads:
            print('[skip] %s 还没有四角（先跑 --pick %s）' % (b, b))
            continue
        x, y, w, h = crops.get(b, (0, 0, 1, 1))
        q = None
        if b in quads and 'quad' in quads[b]:
            q = np.array(quads[b]['quad'], np.float32)
        files = sorted(glob.glob(os.path.join(ROOT, 'calib_raw', b, '*.jpg')))
        n = 0
        for f in files:
            img = cv2.imread(f)
            if img is None:
                continue
            H, W = img.shape[:2]
            if q is not None:
                dst = np.array([[0, 0], [OUTW - 1, 0], [OUTW - 1, OUTH - 1], [0, OUTH - 1]], np.float32)
                M = cv2.getPerspectiveTransform(q, dst)
                out = cv2.warpPerspective(img, M, (OUTW, OUTH), flags=cv2.INTER_CUBIC)
            else:
                x0, y0 = max(0, x), max(0, y)
                x1, y1 = min(W, x + w), min(H, y + h)
                if x1 - x0 < 100 or y1 - y0 < 60:
                    continue
                out = cv2.resize(img[y0:y1, x0:x1], (OUTW, OUTH), interpolation=cv2.INTER_AREA)
            cv2.imwrite(os.path.join(OUTDIR, '%s_%s.png' % (b, os.path.splitext(os.path.basename(f))[0])), out)
            n += 1
        print('%-6s 裁剪 %d 张' % (b, n))
        total += n
    print('共 %d 张 -> %s\n' % (total, OUTDIR))
    return total


def detect_and_calib():
    files = sorted(glob.glob(os.path.join(OUTDIR, '*.png')))
    ok_files = []
    flags = cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY
    for f in files:
        img = cv2.imread(f)
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        found, corners = cv2.findChessboardCorners(gray, PATTERN, flags)
        if found:
            pts = corners.reshape(-1, 2)
            h, w = gray.shape
            mg = min(pts[:, 0].min(), pts[:, 1].min(), w - 1 - pts[:, 0].max(), h - 1 - pts[:, 1].max())
            cx, cy = pts[:, 0].mean() / w * 100, pts[:, 1].mean() / h * 100
            print('OK   %-24s 中心(%3.0f%%,%3.0f%%) 贴边 %.0fpx' % (os.path.basename(f), cx, cy, mg))
            ok_files.append(f)
        else:
            print('FAIL %-24s 棋盘不完整' % os.path.basename(f))
    print('\n可用 %d / %d 张\n' % (len(ok_files), len(files)))
    if len(ok_files) < 6:
        print('可用张数太少（<6），先补拍/修裁剪框')
        return None
    out_json = os.path.join(ROOT, 'calib_raw', 'params_final.json')
    cmd = [sys.executable, os.path.join(ROOT, 'tools', 'calibrate.py')] + ok_files + \
          ['--pattern', '11x8', '--square', '30', '--out', out_json]
    print('跑标定 ...')
    subprocess.run(cmd, check=False)
    return out_json


def report(js):
    if not js or not os.path.exists(js):
        return
    d = json.load(open(js, encoding='utf-8'))
    K = d['K']; dist = d['dist']
    fx, fy, cx, cy = K['fx'], K['fy'], K['cx'], K['cy']
    k1, k2, p1, p2 = dist['k1'], dist['k2'], dist['p1'], dist['p2']
    k1q_meas = int(round(k1 * (1 << 24)))
    k1q_true = k1q_meas + K1_APPLIED_Q24          # 加上板上已经施加的那一份
    print('=' * 66)
    print('标定结果   RMS = %.3f px' % d.get('rms_reprojection_px', -1))
    print('  fx=%.2f  fy=%.2f  cx=%.2f  cy=%.2f' % (fx, fy, cx, cy))
    print('  k1=%+.6f  k2=%+.6f  p1=%+.6f  p2=%+.6f' % (k1, k2, p1, p2))
    print('  fx/fy = %.3f  (合格 0.97~1.03；≈1.11 说明屏幕还在拉伸)' % (fx / fy if fy else 0))
    print('-' * 66)
    print('屏幕上是【残余畸变】，真实镜头值 = 残余 + 板上已施加(k1=-2248147)')
    print('  k1 残余 = %+.6f  ->  k1q 残余(%d) + 已施加(%d) = %d' % (k1, k1q_meas, K1_APPLIED_Q24, k1q_true))
    print('-' * 66)
    print('RTL 整数（按真实值）:')
    print('  K1CFG  = %d' % k1q_true)
    print('  P_FX   = %d' % int(round(fx * 65536)))
    print('  P_CX   = %d' % int(round(cx * 65536)))
    print('  P_CY   = %d' % int(round(cy * 65536)))
    print('  cfg_a00= %d' % int(round((1 << 28) / fx)))
    lb = d.get('line_buffer')
    if lb:
        print('-' * 66)
        print('行窗口需求: dv_max=%.1f px du_max=%.1f px -> rows_needed=%s' %
              (lb.get('dv_max_px', -1), lb.get('du_max_px', -1), lb.get('rows_needed')))
    print('=' * 66)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pick', metavar='BATCH', help='量某个批次的裁剪框（raw2/raw3/raw4/raw5/raw7）')
    ap.add_argument('--crop-only', action='store_true')
    a = ap.parse_args()
    if a.pick:
        pick(a.pick)
        return
    if crop_all() == 0:
        raise SystemExit('没有可裁剪的图，先跑 --pick')
    if a.crop_only:
        return
    js = detect_and_calib()
    report(js)


if __name__ == '__main__':
    sys.exit(main())
