import { readFileSync } from 'node:fs';
import { src_px } from './bil_golden_lib.mjs';
const FW = 1280, FH = 720;
const K1Q = Number(process.env.K1Q || -2248147);
const ROT = Number(process.env.ROT || 0);
const k1r = K1Q / 16777216.0;
const chR = (p) => (p >> 11) & 31, chG = (p) => (p >> 5) & 63, chB = (p) => p & 31;
function load(path) {
  const img = new Int32Array(FW * FH);
  const txt = readFileSync(path, 'ascii');
  for (const line of txt.split(/\r?\n/)) { if (!line) continue; const a = line.split(/\s+/); if (a.length < 3) continue;
    img[+a[0] * FW + +a[1]] = parseInt(a[2], 16); }
  return img;
}
const R = load('bisect/rtl_mg56-r' + ROT + '.txt');
const t = ROT * Math.PI / 180, ca = Math.cos(t), sa = Math.sin(t);
function blend(a, b, w, hi) { let r = Math.trunc(a + (b - a) * w + 0.5); if (r < 0) r = 0; if (r > hi) r = hi; return r; }
const byRow = new Int32Array(FH), byCol = new Int32Array(FW);
let bad = 0;
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
    const p00 = src_px(iy, ix), p01 = src_px(iy, ix1), p10 = src_px(iy1, ix), p11 = src_px(iy1, ix1);
    const r5 = blend(blend(chR(p00), chR(p10), ay, 31), blend(chR(p01), chR(p11), ay, 31), ax, 31);
    const g6 = blend(blend(chG(p00), chG(p10), ay, 63), blend(chG(p01), chG(p11), ay, 63), ax, 63);
    const b5 = blend(blend(chB(p00), chB(p10), ay, 31), blend(chB(p01), chB(p11), ay, 31), ax, 31);
    const iv = (r5 << 11) | (g6 << 5) | b5;
    const rv = R[v * FW + u];
    const d = Math.max(Math.abs(chR(rv) - r5), Math.abs(chG(rv) - g6), Math.abs(chB(rv) - b5));
    if (d > 3) { bad++; byRow[v]++; byCol[u % 160]++; }
  }
}
console.log('bad=' + bad);
const rows = Array.from(byRow).map((c, i) => [i, c]).filter(x => x[1] > 0);
console.log('rows hit: ' + rows.length + ' first=' + (rows[0] ? rows[0][0] : -1) + ' last=' + (rows.length ? rows[rows.length - 1][0] : -1));
const cols = Array.from(byCol).map((c, i) => [i, c]).filter(x => x[1] > 0).sort((a, b) => b[1] - a[1]).slice(0, 14);
console.log('top u%160: ' + cols.map(x => x[0] + ':' + x[1]).join('  '));
console.log('u%160 hit count: ' + cols.length + ' of 160');
