// m4_ideal.mjs -- RTL(M4) vs 实数理想（含透视），按"源坐标是否在画内"分组
//
// 这是 M3b 的主力尺子: 黄金模型 m3_model.mjs 和 RTL 是同一套定点算法，能一起错；
// 这里用实数算 homography + Brown-Conrady + 双线性，是不共享任何定点实现的独立参考。
//
// 用法: node tools/m4_ideal.mjs
//   CASES="0/0/0,0/20/0,0/20/20,15/20/0"   rot/tilt/pitch   （roll 默认 0）
//   MG=56 K1Q=-2248147 TOL=3
import { readFileSync } from 'node:fs';
import { src_px } from './bil_golden_lib.mjs';
import { geom } from './m3_model.mjs';

const FW = 1280, FH = 720;
const FXr = 750.0, CXr = 639.5, CYr = 359.5;
const K1Q = Number(process.env.K1Q || -2248147);
const TOL = Number(process.env.TOL || 3);
const MG = Number(process.env.MG || 56);
const ROLL = Number(process.env.ROLL || 0);
const tagOf = (rot, tilt, pitch) => 'm4_mg' + MG + '-r' + rot + '-t' + tilt + '-p' + pitch;

function load(path) {
  const img = new Int32Array(FW * FH);
  const txt = readFileSync(path, 'ascii');
  for (const line of txt.split(/\r?\n/)) {
    if (!line) continue;
    const a = line.split(/\s+/);
    if (a.length < 3) continue;
    img[+a[0] * FW + +a[1]] = parseInt(a[2], 16);
  }
  return img;
}
function blend(a, b, w, hi) {
  let r = Math.trunc(a + (b - a) * w + 0.5);
  if (r < 0) r = 0; if (r > hi) r = hi;
  return r;
}
const chR = (p) => (p >> 11) & 31, chG = (p) => (p >> 5) & 63, chB = (p) => p & 31;

// 实数 homography 系数（不量化）。level 情形直接退化成 M3a 的纯旋转。
function coeffs(rot, tilt, pitch) {
  const g = geom(rot, tilt, ROLL, pitch);
  if (g.ex) return g.ex;
  const t = (rot + ROLL) * Math.PI / 180, c = Math.cos(t), s = Math.sin(t);
  return { A00: c / FXr, A01: -s / FXr, A10: s / FXr, A11: c / FXr, H20: 0, H21: 0 };
}

function idealImg(C, k1r) {
  const img = new Int32Array(FW * FH), oob = new Uint8Array(FW * FH);
  for (let v = 0; v < FH; v++) {
    const yp = v - CYr;
    for (let u = 0; u < FW; u++) {
      const xp = u - CXr;
      const W = 1 + C.H20 * xp + C.H21 * yp;
      const xn = (C.A00 * xp + C.A01 * yp) / W;
      const yn = (C.A10 * xp + C.A11 * yp) / W;
      const r2 = xn * xn + yn * yn;
      const sc = 1.0 + k1r * r2;
      const sx = xn * sc * FXr + CXr;
      const sy = yn * sc * FXr + CYr;
      const i = v * FW + u;
      if (!(sx >= 0 && sx <= FW - 1 && sy >= 0 && sy <= FH - 1)) oob[i] = 1;
      let ix = Math.trunc(sx); ix = sx < 0 ? 0 : (sx > FW - 1 ? FW - 1 : ix);
      let iy = Math.trunc(sy); iy = sy < 0 ? 0 : (sy > FH - 1 ? FH - 1 : iy);
      const ix1 = Math.min(ix + 1, FW - 1), iy1 = Math.min(iy + 1, FH - 1);
      let ax = sx - ix; ax = ax < 0 ? 0 : (ax > 1 ? 1 : ax);
      let ay = sy - iy; ay = ay < 0 ? 0 : (ay > 1 ? 1 : ay);
      const p00 = src_px(iy, ix), p01 = src_px(iy, ix1), p10 = src_px(iy1, ix), p11 = src_px(iy1, ix1);
      const r5 = blend(blend(chR(p00), chR(p10), ay, 31), blend(chR(p01), chR(p11), ay, 31), ax, 31);
      const g6 = blend(blend(chG(p00), chG(p10), ay, 63), blend(chG(p01), chG(p11), ay, 63), ax, 63);
      const b5 = blend(blend(chB(p00), chB(p10), ay, 31), blend(chB(p01), chB(p11), ay, 31), ax, 31);
      img[i] = (r5 << 11) | (g6 << 5) | b5;
    }
  }
  return { img: img, oob: oob };
}

const cases = (process.env.CASES || '0/0/0, 0/20/0, 0/20/20, 15/20/0, 15/20/20, 20/30/20')
  .split(',').map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const k1r = K1Q / 16777216.0;

console.log('rot tilt pitch |  画内 over_tol / 画内像素  (比例)   maxdiff |  画外像素  画外 over_tol  (比例)');
for (const [rot, tilt, pitch] of cases) {
  const f = 'bisect/rtl_' + tagOf(rot, tilt, pitch) + '.txt';
  let R;
  try { R = load(f); } catch (e) { console.log((rot + '/' + tilt + '/' + pitch).padEnd(13) + ' (no dump ' + f + ')'); continue; }
  const I = idealImg(coeffs(rot, tilt, pitch), k1r);
  let nin = 0, badIn = 0, mxIn = 0, nout = 0, badOut = 0, mxOut = 0;
  for (let i = 0; i < FW * FH; i++) {
    const d = Math.max(Math.abs(chR(R[i]) - chR(I.img[i])),
                       Math.abs(chG(R[i]) - chG(I.img[i])),
                       Math.abs(chB(R[i]) - chB(I.img[i])));
    if (I.oob[i]) { nout++; if (d > TOL) badOut++; if (d > mxOut) mxOut = d; }
    else { nin++; if (d > TOL) badIn++; if (d > mxIn) mxIn = d; }
  }
  console.log(
    String(rot).padStart(3) + String(tilt).padStart(5) + String(pitch).padStart(6) + ' | ' +
    String(badIn).padStart(7) + ' / ' + String(nin).padStart(7) + ' (' + (nin ? (100 * badIn / nin).toFixed(3) : '-') + '%)' +
    String(mxIn).padStart(6) + ' | ' +
    String(nout).padStart(7) + '   ' + String(badOut).padStart(7) + ' (' + (nout ? (100 * badOut / nout).toFixed(2) : '-') + '%)' +
    String(mxOut).padStart(6));
}
