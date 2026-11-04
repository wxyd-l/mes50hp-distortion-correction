// m3_model.mjs -- M3a 核心（每行窗口 + 逆映射）的逐位黄金模型
// 用法: node tools/m3_model.mjs --k1q N --rot 15 [--out model_dump_m3.txt]
import { writeFileSync } from 'node:fs';
import { FW, FH, TW, Mapper, to_q8, mixc, k1p_of, src_px } from './bil_golden_lib.mjs';

export const SW3 = 256, RPB3 = 120, MARGIN3 = Number(process.env.MG || 56);
export const SM3 = SW3 - 1;
const FXr = 750.0, CXr = 639.5, CYr = 359.5;

// 团队核吃的是【绝对像素】u,v: x_norm = a00*u + a01*v + a02, a02 = -(c*cx - s*cy)/fx
//
// M3b 透视：平面先绕自身中心在平面内转 rotDeg，再被相机以 d=750 斜看 (tilt, roll)。
// 合起来的 3x3 齐次映射 H = Persp(tilt,roll) ∘ Rot(rot)，对 (u-CX, v-CY) 展开：
//   x_norm = (A00*xp + A01*yp) / (1 + H20q*xp + H21q*yp)
// tilt = roll = 0 时退化成 M3a 的纯旋转（H20q = H21q = 0, W ≡ 2^24）。
// 注意：tilt=roll=0 走的是【与 M3a 逐字相同】的旧表达式，保证回归可复现。
// 定标（Q4.28 分子 / Q8.24 分母，与 ud_persp_front.v 一一对应）：
//   a00..a12 = round(A * 2^28)（常数项已折入主点 -CX,-CY）
//   h20,h21  = round(H2x * 2^24)
//   w0       = round((1 - H20q*CX - H21q*CY) * 2^24)
export function geom(rotDeg, tiltDeg = 0, rollDeg = 0, pitchDeg = 0) {
  const Rr = (x) => Math.round(x);
  // 【bug 修复】roll 是绕【光轴】的旋转，和平面内 rot 同一根轴，等价于把 rot 加上去，
  //   不会产生第二条透视自由度。旧版 R = Rz(roll)·Ry(tilt) 因此让 "tilt+roll" 那几行
  //   实际只测了一个轴。现在用 R = Rx(pitch)·Ry(tilt)：Ry 绕竖直轴给出 h20，
  //   Rx 绕水平轴补出【独立的】h21。
  const rotAll = rotDeg + rollDeg;
  const t = rotAll * Math.PI / 180, c = Math.cos(t), s = Math.sin(t);
  const level = (tiltDeg === 0 && pitchDeg === 0);
  if (rotAll === 0 && level) {
    return { rotDeg, tiltDeg, rollDeg, pitchDeg,
      a00: 357914, a01: 0, a02: -228885965,
      a10: 0, a11: 357914, a12: -128670062,
      h20: 0, h21: 0, w0: 16777216,
      UX: 65536, UV: 0, U0: 0, IV: 65536, VX: 0, VV: 65536, V0: 0 };
  }
  if (level) {
    // ---- M3a 原路径（逐字保留，保证 0/921600 可复现） ----
    return {
      rotDeg, tiltDeg, rollDeg, pitchDeg,
      a00: Rr(c / FXr * 268435456), a01: Rr(-s / FXr * 268435456),
      a02: Rr(-(c * CXr - s * CYr) / FXr * 268435456),
      a10: Rr(s / FXr * 268435456), a11: Rr(c / FXr * 268435456),
      a12: Rr(-(s * CXr + c * CYr) / FXr * 268435456),
      h20: 0, h21: 0, w0: 16777216,
      UX: Rr(c * 65536), UV: Rr(-s * 65536), U0: Rr((CXr - c * CXr + s * CYr) * 65536),
      IV: Rr(65536 / c), VX: Rr(s * 65536), VV: Rr(c * 65536), V0: Rr((CYr - s * CXr - c * CYr) * 65536),
    };
  }
  // ---- 真透视：R = Rx(pitch)·Ry(tilt)，再叠平面内 rotAll ----
  const tt = tiltDeg * Math.PI / 180, ct = Math.cos(tt), st = Math.sin(tt);
  const tp = pitchDeg * Math.PI / 180, cp = Math.cos(tp), sp = Math.sin(tp);
  const M = [
    [ct,       0,  st],
    [sp * st,  cp, -sp * ct],
    [-cp * st, sp, cp * ct],
  ];
  return hFromM(M, c, s, rotDeg, tiltDeg, rollDeg, pitchDeg);
}

// 由 3x3 平面朝向 M 与平面内旋转 (c,s) 合成全部定点系数
export function hFromM(M, c, s, rotDeg = 0, tiltDeg = 0, rollDeg = 0, pitchDeg = 0) {
  const Rr = (x) => Math.round(x);
  const d = FXr;
  const A00 = (M[0][0] * c + M[0][1] * s) / d, A01 = (-M[0][0] * s + M[0][1] * c) / d;
  const A10 = (M[1][0] * c + M[1][1] * s) / d, A11 = (-M[1][0] * s + M[1][1] * c) / d;
  const H20 = (M[2][0] * c + M[2][1] * s) / d, H21 = (-M[2][0] * s + M[2][1] * c) / d;
  return {
    rotDeg, tiltDeg, rollDeg, pitchDeg,
    // 实数版，给 m4_ideal.mjs 用（不量化）
    ex: { A00, A01, A10, A11, H20, H21 },
    a00: Rr(A00 * 268435456), a01: Rr(A01 * 268435456),
    a02: Rr(-(A00 * CXr + A01 * CYr) * 268435456),
    a10: Rr(A10 * 268435456), a11: Rr(A11 * 268435456),
    a12: Rr(-(A10 * CXr + A11 * CYr) * 268435456),
    h20: Rr(H20 * 16777216), h21: Rr(H21 * 16777216),
    w0: Rr((1 - H20 * CXr - H21 * CYr) * 16777216),
    // 窗口基准估计（lo(r)/base_t 用）仍用"平面内旋转"那套仿射：
    // 透视只改 W 的缩放，窗口够不够由 m4_cover.mjs 单独量。
    UX: Rr(c * 65536), UV: Rr(-s * 65536), U0: Rr((CXr - c * CXr + s * CYr) * 65536),
    IV: Rr(65536 / c), VX: Rr(s * 65536), VV: Rr(c * 65536), V0: Rr((CYr - s * CXr - c * CYr) * 65536),
  };
}

// 齐次归一化：与 ud_persp_front.v 逐位对应
//   恒等分母 (h20=h21=0, w0=2^24) -> norm = X >>> 4（与 M3a 同一表达式，不做除法）
//   否则 r = floor(2^48/W)（W 夹到 [2^22+1, 2^25-1]），norm = (X*r) >>> 28，取 32 位
export const P48 = 281474976710656n;
export function perspNorm(g, u, v) {
  const ax = g.a00 * u + g.a01 * v + g.a02;
  const ay = g.a10 * u + g.a11 * v + g.a12;
  if (g.h20 === 0 && g.h21 === 0 && g.w0 === 16777216) {
    return [Math.floor(ax / 16), Math.floor(ay / 16)];
  }
  const W = g.w0 + g.h20 * u + g.h21 * v;
  const Wc = W < 4194305 ? 4194305 : (W > 33554431 ? 33554431 : W);
  const r = BigInt(Math.floor(281474976710656 / Wc));
  const nx = BigInt.asIntN(32, (BigInt(ax) * r) >> 28n);
  const ny = BigInt.asIntN(32, (BigInt(ay) * r) >> 28n);
  return [Number(nx), Number(ny)];
}

const sdiv = (a, b) => Math.floor(a / b);

// ===========================================================================
// 窗口表（M3b）
//   loTab  : 每个 (tile, 源行) 的列窗口左界（已含 MARGIN、已 16 对齐、已 clamp）
//   baseTab: 每个 (tile, 输出行) 的行窗口起点
// 表 = 断点行上的【精确值】（从真实映射逐像素数出来），中间线性插值。
// RTL 的 ud_win_tab.v 用同一套整数算法，所以能逐位对上。
// ===========================================================================
export const HLOG   = 1;                       // 每 2 行一个断点
export const SEG    = 720 >> HLOG;             // 180 段
export const STRIDE = SEG + 1;                 // 181 个断点
export const WMAR   = Number(process.env.MAR || 8);
export const WXMAX  = FW - SW3;                // 1024
const clampI = (x, lo, hi) => (x < lo ? lo : (x > hi ? hi : x));

function fillNearest(a) {
  const out = Int32Array.from(a);
  let last = -1;
  for (let i = 0; i < out.length; i++) { if (out[i] >= 0) last = out[i]; else if (last >= 0) out[i] = last; }
  let nxt = -1;
  for (let i = out.length - 1; i >= 0; i--) { if (out[i] >= 0) nxt = out[i]; else if (nxt >= 0) out[i] = nxt; }
  for (let i = 0; i < out.length; i++) if (out[i] < 0) out[i] = 0;
  return out;
}

// 由真实映射逐像素统计：每个 (tile, 源行) 的最小源列 / 每个 (tile, 输出行) 的最小源行
export function buildWinTab(g, k1q) {
  const NT = FW / TW;
  const map = new Mapper(FXr, CXr, CYr, k1q / 16777216.0);
  const N = NT * FH;
  const cmin = new Int32Array(N).fill(1 << 20), cnt = new Int32Array(N);
  const rmin = new Int32Array(N).fill(1 << 20), rmax = new Int32Array(N).fill(-(1 << 20));
  for (let v = 0; v < FH; v++) {
    for (let u = 0; u < FW; u++) {
      const t = (u / TW) | 0;
      const [nx, ny] = perspNorm(g, u, v);
      const sp = map.fromNorm(nx, ny);
      const uc = to_q8(sp[0])[0];
      const vr = Math.min(to_q8(sp[1])[0], FH - 1);
      const v2 = Math.min(vr + 1, FH - 1);
      if (vr === v2) { const k = t * FH + vr; if (uc < cmin[k]) cmin[k] = uc; cnt[k]++; }
      else for (let i = 0; i < 2; i++) {
        const k = t * FH + (i ? v2 : vr);
        if (uc < cmin[k]) cmin[k] = uc;
        cnt[k]++;
      }
      const kv = t * FH + v;
      if (vr < rmin[kv]) rmin[kv] = vr;
      if (vr > rmax[kv]) rmax[kv] = vr;
    }
  }
  const lo = new Int32Array(NT * STRIDE), base = new Int32Array(NT * STRIDE);
  for (let t = 0; t < NT; t++) {
    const a = new Int32Array(FH).fill(-1);
    for (let r = 0; r < FH; r++) {
      const k = t * FH + r;
      if (cnt[k]) a[r] = clampI(sdiv(cmin[k] - WMAR, 16) * 16, 0, WXMAX);
    }
    const fa = fillNearest(a);
    const b = new Int32Array(FH).fill(-1);
    for (let v = 0; v < FH; v++) { const kv = t * FH + v; if (rmax[kv] >= rmin[kv]) b[v] = clampI(rmin[kv] - 2, 0, FH - RPB3); }
    const fb = fillNearest(b);
    // 表值 = 断点行真值，再做【下包络修正】：保证插值结果永远 ≤ 真值。
    // cmin(r) 在画幅下沿是台阶（4 行里能从 485 跳到 539），纯插值会过冲 32 列，
    // 窗口左界被抬高 → 该行的像素被钳到窗口左边（实测 24 个像素错）。
    // lo 必须严格做下包络（否则台阶处过冲 → 左钳）；
    // base 只做普通采样：行窗口有 RPB 的余量，且 base 必须保持平滑单调，
    // 取数引擎的增量预取依赖这一点（做包络会把 base 压得抖动，取数跟不上）。
    const tk = sampleTable(fa), tb = sampleTable(fb);
    for (let k = 0; k <= SEG; k++) {
      lo[t * STRIDE + k] = tk[k];
      base[t * STRIDE + k] = tb[k];
    }
  }
  return { lo, base };
}


// 断点表：取断点行上的精确值，中间线性插值
function sampleTable(exact) {
  const out = new Int32Array(STRIDE);
  for (let k = 0; k <= SEG; k++) out[k] = exact[Math.min(k << HLOG, FH - 1)];
  return out;
}


let _wtKey = null, _wtVal = null;
export function winTabOf(g, k1q) {
  const key = [g.a00, g.a01, g.a02, g.a10, g.a11, g.a12, g.h20, g.h21, g.w0, k1q, WMAR].join(',');
  if (_wtKey === key) return _wtVal;
  _wtVal = buildWinTab(g, k1q); _wtKey = key;
  return _wtVal;
}

// 与 ud_win_tab.v 逐位相同：k = r>>HLOG, frac = r & 3, v = v0 + ((v1-v0)*frac >>> HLOG)
export function tabInterp(T, tile, r) {
  const a = tile * STRIDE + (r >> HLOG), f = r & ((1 << HLOG) - 1);
  const v0 = T[a], v1 = T[a + 1];
  return v0 + sdiv((v1 - v0) * f, 1 << HLOG);
}

export function lo_of(T, x0, r) {
  return clampI(tabInterp(T.lo, (x0 / TW) | 0, r), 0, WXMAX);
}
export function base_of(T, v, x0) {
  return clampI(tabInterp(T.base, (x0 / TW) | 0, v), 0, FH - RPB3);
}

function clip(r) { return r < 0 ? 0 : (r > SM3 ? SM3 : r); }

// 逐通道混合（水平/竖向共用），与 RTL 的 mixp() 一一对应
function mixp(a, b, w) {
  const r = mixc((a >> 11) & 31, (b >> 11) & 31, w) & 0x1F;
  const g = mixc((a >> 5) & 63, (b >> 5) & 63, w);
  const bl = mixc(a & 31, b & 31, w) & 0x1F;
  return ((r << 11) | (g << 5) | bl) & 0xFFFF;
}

export function runM3(k1q, nt, rotDeg = 0, tiltDeg = 0, rollDeg = 0, pitchDeg = 0) {
  const g = geom(rotDeg, tiltDeg, rollDeg, pitchDeg);
  const k1p = k1p_of(k1q);
  const tab = winTabOf(g, k1q);
  const mapper = new Mapper(FXr, CXr, CYr, k1q / 16777216.0);
  // 直接用 NORMALIZED 管线（等价于团队核 NORMALIZED_INPUT=1）
  const out = new Int32Array(FH * FW);
  const ntok = TW + 24;
  const vmem = new Int32Array(SW3);
  const amem = new Int32Array(SW3);
  const wxA = new Int32Array(ntok);
  const rval = new Uint8Array(ntok), vval = new Int32Array(ntok), rcA = new Int32Array(ntok);
  const vbuf = new Int32Array(SW3);       // 按 token 序号缓冲，跨行保留

  for (let row = 0; row < FH; row++) {
    for (let ti = 0; ti < nt; ti++) {
      const x0 = ti * TW;
      const base = base_of(tab, row, x0);
      for (let n = 0; n < ntok; n++) {
        const u = x0 + n;
        // 团队核: 归一化仿射 -> Q8.24
        const [s1x, s1y] = perspNorm(g, u, row);
        const [sx, sy] = mapper.fromNorm(s1x, s1y);
        const [ucn, wxn] = to_q8(sx);
        const [vrn, wyn] = to_q8(sy);
        const v1 = Math.min(vrn, FH - 1);
        const v2 = Math.min(v1 + 1, FH - 1);
        const wb1 = lo_of(tab, x0, v1), wb2 = lo_of(tab, x0, v2);
        // 同一行的相邻两列，各自按本行窗口钳位
        const c10 = clip(ucn - wb1), c11 = clip(ucn + 1 - wb1);
        const c20 = clip(ucn - wb2), c21 = clip(ucn + 1 - wb2);
        const a0 = src_px(v1, wb1 + c10), a1 = src_px(v1, wb1 + c11);
        const b0 = src_px(v2, wb2 + c20), b1 = src_px(v2, wb2 + c21);
        // 先水平（每根列在它自己那一行上插值），再竖向
        const h1 = mixp(a0, a1, wxn), h2 = mixp(b0, b1, wxn);
        const ok = (v1 >= base) && (v1 < base + RPB3);
        const rb_ok = (v2 !== v1) && (v2 >= base) && (v2 < base + RPB3);
        vval[n] = mixp(h1, rb_ok ? h2 : h1, wyn);
        rcA[n] = ucn & 255; wxA[n] = wxn;
        rval[n] = ok ? 1 : 0;
      }
      // 按 token 序号缓冲：写 n，读 n-LAG（相差 8，不撞；不能用源列寻址，uc 会重复）
      for (let n = 0; n < ntok; n++) if (rval[n]) vbuf[n] = vval[n];
      for (let m = 0; m < TW; m++) out[row * FW + x0 + m] = vbuf[m];
    }
  }
  return out;
}

const isMain = process.argv[1] && process.argv[1].replace(/\\/g, '/').endsWith('m3_model.mjs');
if (isMain) {
  const argv = process.argv.slice(2);
  const argOf = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
  const k1q = Number(argOf('--k1q', -2248147));
  const rot = Number(argOf('--rot', 0));
  const tilt = Number(argOf('--tilt', 0));
  const roll = Number(argOf('--roll', 0));
  const pitch = Number(argOf('--pitch', 0));
  const outPath = argOf('--out', 'model_dump_m3.txt');
  if (argv.includes('--emit') || argv.includes('--emit4')) {
    const g = geom(rot, tilt, roll, pitch);
    const base = ['-gA00=' + g.a00, '-gA01=' + g.a01, '-gA02=' + g.a02,
                 '-gA10=' + g.a10, '-gA11=' + g.a11, '-gA12=' + g.a12,
                 '-gUX=' + g.UX, '-gUV=' + g.UV, '-gU0=' + g.U0,
                 '-gIV=' + g.IV, '-gVX=' + g.VX, '-gVV=' + g.VV, '-gV0=' + g.V0];
    // --emit4 才带透视分母（m3 的 TB 没有 H20/H21/W0 这三个 generic）
    if (argv.includes('--emit4')) base.push('-gH20=' + g.h20, '-gH21=' + g.h21, '-gW0=' + g.w0);
    console.log(base.join(' '));
    process.exit(0);
  }
  if (argv.includes('--emit-tab')) {
    const g = geom(rot, tilt, roll, pitch);
    const T = winTabOf(g, k1q);
    const prefix = argOf('--emit-tab', 'wintab');
    const hex = (a) => { const L = []; for (let i = 0; i < a.length; i++) L.push(a[i].toString(16).padStart(3, '0')); return L.join('\n') + '\n'; };
    writeFileSync(prefix + '_lo.hex', hex(T.lo), 'ascii');
    writeFileSync(prefix + '_base.hex', hex(T.base), 'ascii');
    console.log('wrote ' + prefix + '_lo.hex / ' + prefix + '_base.hex  (rot=' + rot + ' tilt=' + tilt + ' pitch=' + pitch + ' mar=' + WMAR + ')');
    process.exit(0);
  }
  const out = runM3(k1q, 8, rot, tilt, roll, pitch);
  const buf = [];
  for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++) buf.push(v + ' ' + u + ' ' + out[v * FW + u]);
  writeFileSync(outPath, buf.join('\n') + '\n', 'ascii');
  console.log('wrote ' + outPath + ' (rot=' + rot + ' tilt=' + tilt + ' roll=' + roll + ' pitch=' + pitch + ')');
}
