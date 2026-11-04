// compare.mjs -- Node 版三方对拍 + 误差归因（等价移植自 tools/compare.py）
// 用法: node tools/compare.mjs [rtl_dump.txt] [model_dump.txt]
import { readFileSync } from 'node:fs';
import { FW, FH, TW, SW, NT, Mapper, to_q8, k1p_of, xs_of, src_px } from './bil_golden_lib.mjs';

const TOL = 3;

function loadDump(path, asHex) {
  const txt = readFileSync(path, 'ascii');
  const v = [], u = [], val = [], xm = [];
  for (const line of txt.split(/\r?\n/)) {
    if (!line) continue;
    const a = line.split(/\s+/);
    if (a.length < 3) continue;
    v.push(+a[0]); u.push(+a[1]);
    if (asHex) {
      if (/^[0-9a-fA-F]+$/.test(a[2])) { val.push(parseInt(a[2], 16)); xm.push(0); }
      else { val.push(0); xm.push(1); }
    } else {
      val.push(+a[2]); xm.push(0);
    }
  }
  return { v, u, val, xm };
}

function dense(D) {
  const img = new Int32Array(FW * FH);
  for (let i = 0; i < D.v.length; i++) img[D.v[i] * FW + D.u[i]] = D.val[i];
  return img;
}

const chR = (p) => (p >> 11) & 31;
const chG = (p) => (p >> 5) & 63;
const chB = (p) => p & 31;

function blend(a, b, w, hi) {
  const t = a + (b - a) * w;
  let r = Math.trunc(t + 0.5);
  if (r < 0) r = 0; if (r > hi) r = hi;
  return r;
}

function idealBilinear(k1r, rotDeg) {
  // 实数理想：先把输出坐标按 rot 旋转回源坐标系，再做 Brown-Conrady 反畸变 + 双线性
  const t = (rotDeg || 0) * Math.PI / 180.0;
  const ca = Math.cos(t), sa = Math.sin(t);
  const img = new Int32Array(FW * FH);
  for (let v = 0; v < FH; v++) {
    const y = (v - 359.5) / 750.0;
    for (let u = 0; u < FW; u++) {
      const x = (u - 639.5) / 750.0;
      const xr = ca * x - sa * y, yr = sa * x + ca * y;
      const r2 = xr * xr + yr * yr;
      const sx = xr * (1.0 + k1r * r2) * 750.0 + 639.5;
      const sy = yr * (1.0 + k1r * r2) * 750.0 + 359.5;
      let ix = Math.trunc(sx); ix = sx < 0 ? 0 : (sx > FW - 1 ? FW - 1 : ix);
      let iy = Math.trunc(sy); iy = sy < 0 ? 0 : (sy > FH - 1 ? FH - 1 : iy);
      const ix1 = Math.min(ix + 1, FW - 1), iy1 = Math.min(iy + 1, FH - 1);
      let ax = sx - ix; ax = ax < 0 ? 0 : (ax > 1 ? 1 : ax);
      let ay = sy - iy; ay = ay < 0 ? 0 : (ay > 1 ? 1 : ay);
      const p00 = src_px(iy, ix), p01 = src_px(iy, ix1);
      const p10 = src_px(iy1, ix), p11 = src_px(iy1, ix1);
      const r5 = blend(blend((p00 >> 11) & 31, (p10 >> 11) & 31, ay, 31), blend((p01 >> 11) & 31, (p11 >> 11) & 31, ay, 31), ax, 31);
      const g6 = blend(blend((p00 >> 5) & 63, (p10 >> 5) & 63, ay, 63), blend((p01 >> 5) & 63, (p11 >> 5) & 63, ay, 63), ax, 63);
      const b5 = blend(blend(p00 & 31, p10 & 31, ay, 31), blend(p01 & 31, p11 & 31, ay, 31), ax, 31);
      img[v * FW + u] = (r5 << 11) | (g6 << 5) | b5;
    }
  }
  return img;
}

const rtlPath = process.argv[2] || 'rtl_dump.txt';
const modPath = process.argv[3] || 'model_dump.txt';

console.log('loading...');
const R = loadDump(rtlPath, true);
const rtl = dense(R);
const xmask = new Uint8Array(FW * FH);
for (let i = 0; i < R.v.length; i++) if (R.xm[i]) xmask[R.v[i] * FW + R.u[i]] = 1;

let xn = 0, x0c = FW, x1c = -1, x0r = FH, x1r = -1;
for (let i = 0; i < xmask.length; i++) if (xmask[i]) {
  xn++; const v = Math.floor(i / FW), u = i % FW;
  if (u < x0c) x0c = u; if (u > x1c) x1c = u;
  if (v < x0r) x0r = v; if (v > x1r) x1r = v;
}
console.log('\n=== 0) cold start ===');
console.log('  RTL X pixels: ' + xn + (xn ? '  rows[' + x0r + '..' + x1r + '] cols[' + x0c + '..' + x1c + ']' : ''));

const mod = dense(loadDump(modPath, false));
let neq = 0, compared = 0, mdr = 0, mdg = 0, mdb = 0;
const first = [];
for (let i = 0; i < rtl.length; i++) {
  if (xmask[i]) continue;
  compared++;
  if (rtl[i] !== mod[i]) {
    neq++;
    const dr = Math.abs(chR(rtl[i]) - chR(mod[i]));
    const dg = Math.abs(chG(rtl[i]) - chG(mod[i]));
    const db = Math.abs(chB(rtl[i]) - chB(mod[i]));
    if (dr > mdr) mdr = dr; if (dg > mdg) mdg = dg; if (db > mdb) mdb = db;
    if (first.length < 8) first.push('(v=' + Math.floor(i / FW) + ',u=' + (i % FW) + ')');
  }
}
console.log('\n=== 1) RTL vs golden model (X excluded) ===');
console.log('  unequal: ' + neq + ' / ' + compared);
if (neq) console.log('  max|dR|=' + mdr + ' max|dG|=' + mdg + ' max|dB|=' + mdb + '\n  first 8: ' + first.join(' '));

const k1q = -2248147;
const k1r = k1q / 16777216.0;
const ROT = Number(process.env.ROT || 0);
const ideal = idealBilinear(k1r, ROT);
const badArr = new Uint8Array(FW * FH);
let bad = 0, mx = 0, bad1 = 0;
for (let i = 0; i < rtl.length; i++) {
  const dr = Math.abs(chR(rtl[i]) - chR(ideal[i]));
  const dg = Math.abs(chG(rtl[i]) - chG(ideal[i]));
  const db = Math.abs(chB(rtl[i]) - chB(ideal[i]));
  if (dr > mx) mx = dr; if (dg > mx) mx = dg; if (db > mx) mx = db;
  if (dr > TOL || dg > TOL || db > TOL) { bad++; badArr[i] = 1; if ((i % FW) > 0) bad1++; }
}
console.log('\n=== 2) RTL vs real-ideal ===');
console.log('  over_tol(' + TOL + ') = ' + bad + ' / ' + rtl.length + '  (' + (100 * bad / rtl.length).toFixed(2) + '%)   maxdiff=' + mx);
console.log('  of which x>0 (non-blank column edge): ' + bad1);

// ---- 3) 归因: 源列是否落在窗口外被裁剪 ----
const k1p = k1p_of(k1q);
const xs = []; for (let t = 0; t < NT; t++) xs.push(xs_of(t * TW, k1p));
const mapper = new Mapper(750.0, 639.5, 359.5, k1r);
let clipped = 0, badClip = 0, badNoClip = 0;
const perTile = new Array(NT).fill(0);
for (let v = 0; v < FH; v++) {
  for (let u = 0; u < FW; u++) {
    const [sx] = mapper.src(u, v);
    const [uc] = to_q8(sx);
    const wx = xs[Math.floor(u / TW)];
    const isClipped = (uc < wx) || (uc > wx + SW - 1);
    const i = v * FW + u;
    if (isClipped) { clipped++; perTile[Math.floor(u / TW)]++; if (badArr[i]) badClip++; }
    else if (badArr[i]) badNoClip++;
  }
}
console.log('\n=== 3) attribution ===');
console.log('  source-clipped pixels : ' + clipped);
console.log('  over_tol that were clipped: ' + badClip + ' / ' + bad + '   not clipped: ' + badNoClip);
console.log('  per-tile clipped: [' + perTile.join(', ') + ']');
console.log('  xs = [' + xs.join(', ') + ']');
