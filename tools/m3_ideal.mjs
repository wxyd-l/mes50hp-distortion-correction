// m3_ideal.mjs -- RTL vs 实数理想，按"源坐标是否在画内"分组，剔除出画边界的干扰
import { readFileSync } from 'node:fs';
import { src_px } from './bil_golden_lib.mjs';
const FW = 1280, FH = 720;
const K1Q = Number(process.env.K1Q || -2248147);
const TOL = 3;
function load(path, hex) {
  const img = new Int32Array(FW * FH);
  const txt = readFileSync(path, 'ascii');
  for (const line of txt.split(/\r?\n/)) {
    if (!line) continue;
    const a = line.split(/\s+/);
    if (a.length < 3) continue;
    img[+a[0] * FW + +a[1]] = hex ? parseInt(a[2], 16) : +a[2];
  }
  return img;
}
function blend(a, b, w, hi) {
  let r = Math.trunc(a + (b - a) * w + 0.5);
  if (r < 0) r = 0; if (r > hi) r = hi;
  return r;
}
const chR = (p) => (p >> 11) & 31, chG = (p) => (p >> 5) & 63, chB = (p) => p & 31;
function idealImg(k1r, rotDeg) {
  const t = rotDeg * Math.PI / 180, ca = Math.cos(t), sa = Math.sin(t);
  const img = new Int32Array(FW * FH), oob = new Uint8Array(FW * FH);
  for (let v = 0; v < FH; v++) {
    const y = (v - 359.5) / 750.0;
    for (let u = 0; u < FW; u++) {
      const x = (u - 639.5) / 750.0;
      const xr = ca * x - sa * y, yr = sa * x + ca * y;
      const r2 = xr * xr + yr * yr;
      const sx = xr * (1.0 + k1r * r2) * 750.0 + 639.5;
      const sy = yr * (1.0 + k1r * r2) * 750.0 + 359.5;
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
const k1r = K1Q / 16777216.0;
const rots = (process.env.ROTS || '0,5,10,15,20').split(',').map(Number);
console.log('rot  |  in-frame over_tol   maxdiff   |  out-frame px   over_tol(out)');
for (const rot of rots) {
  const f = 'bisect/rtl_mg56-r' + rot + '.txt';
  let R;
  try { R = load(f, true); } catch (e) { console.log(rot + '  (no dump)'); continue; }
  const I = idealImg(k1r, rot);
  let nin = 0, badIn = 0, mxIn = 0, nout = 0, badOut = 0;
  for (let i = 0; i < FW * FH; i++) {
    const dR = Math.abs(chR(R[i]) - chR(I.img[i]));
    const dG = Math.abs(chG(R[i]) - chG(I.img[i]));
    const dB = Math.abs(chB(R[i]) - chB(I.img[i]));
    const d = Math.max(dR, dG, dB);
    if (I.oob[i]) { nout++; if (d > TOL) badOut++; }
    else { nin++; if (d > TOL) { badIn++; if (d > mxIn) mxIn = d; } }
  }
  const pctIn = nin ? (100 * badIn / nin).toFixed(2) : '-';
  const pctOut = nout ? (100 * badOut / nout).toFixed(2) : '-';
  console.log(String(rot).padStart(3) + '  |  ' + String(badIn).padStart(7) + ' / ' + String(nin).padStart(7) +
    ' (' + pctIn + '%)  ' + String(mxIn).padStart(3) + '    |  ' + String(nout).padStart(6) +
    ' (' + pctOut + '%)  ' + String(badOut).padStart(6));
}
