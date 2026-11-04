// m3_worst.mjs -- 找出 in-frame 最差的像素并完整展开
import { readFileSync } from 'node:fs';
import { FW, FH, TW, Mapper, to_q8, mixc, src_px } from './bil_golden_lib.mjs';
import { geom } from './m3_model.mjs';
const K1Q = Number(process.env.K1Q || -2248147);
const ROT = Number(process.env.ROT || 20);
const k1r = K1Q / 16777216.0;
const chR = (p) => (p >> 11) & 31, chG = (p) => (p >> 5) & 63, chB = (p) => p & 31;
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
const R = load('bisect/rtl_mg56-r' + ROT + '.txt', true);
const mapper = new Mapper(750.0, 639.5, 359.5, k1r);
const g = geom(ROT);
const t = ROT * Math.PI / 180, ca = Math.cos(t), sa = Math.sin(t);
function blend(a, b, w, hi) { let r = Math.trunc(a + (b - a) * w + 0.5); if (r < 0) r = 0; if (r > hi) r = hi; return r; }
const worst = [];
for (let v = 0; v < FH; v++) {
  const y = (v - 359.5) / 750.0;
  for (let u = 0; u < FW; u++) {
    const x = (u - 639.5) / 750.0;
    const xr = ca * x - sa * y, yr = sa * x + ca * y;
    const r2 = xr * xr + yr * yr;
    const sx = xr * (1.0 + k1r * r2) * 750.0 + 639.5;
    const sy = yr * (1.0 + k1r * r2) * 750.0 + 359.5;
    if (!(sx >= 1 && sx <= FW - 2 && sy >= 1 && sy <= FH - 2)) continue;
    const ix = Math.trunc(sx), iy = Math.trunc(sy);
    const ix1 = Math.min(ix + 1, FW - 1), iy1 = Math.min(iy + 1, FH - 1);
    const ax = sx - ix, ay = sy - iy;
    const p00 = src_px(iy, ix), p01 = src_px(iy, ix1), p10 = src_px(iy1, ix), p11 = src_px(iy1, ix1);
    const r5 = blend(blend(chR(p00), chR(p10), ay, 31), blend(chR(p01), chR(p11), ay, 31), ax, 31);
    const g6 = blend(blend(chG(p00), chG(p10), ay, 63), blend(chG(p01), chG(p11), ay, 63), ax, 63);
    const b5 = blend(blend(chB(p00), chB(p10), ay, 31), blend(chB(p01), chB(p11), ay, 31), ax, 31);
    const idv = (r5 << 11) | (g6 << 5) | b5;
    const rv = R[v * FW + u];
    const d = Math.max(Math.abs(chR(rv) - r5), Math.abs(chG(rv) - g6), Math.abs(chB(rv) - b5));
    if (d > 10) worst.push({ u: u, v: v, d: d, rv: rv, idv: idv, sx: sx, sy: sy, ix: ix, iy: iy, ax: ax, ay: ay });
  }
}
worst.sort((a, b) => b.d - a.d);
console.log('pixels with diff>10 (in-frame): ' + worst.length);
for (const w of worst.slice(0, 8)) {
  const ax = g.a00 * w.u + g.a01 * w.v + g.a02, ay = g.a10 * w.u + g.a11 * w.v + g.a12;
  const sp = mapper.fromNorm(Math.floor(ax / 16), Math.floor(ay / 16));
  const q = to_q8(sp[0]), r = to_q8(sp[1]);
  console.log(' (v=' + w.v + ',u=' + w.u + ') diff=' + w.d + ' rtl=' + w.rv.toString(16) + ' ideal=' + w.idv.toString(16) +
    '  sx=' + w.sx.toFixed(3) + ' sy=' + w.sy.toFixed(3) + '  pipe uc=' + q[0] + ' wx=' + q[1] + ' v1=' + r[0] + ' wy=' + r[1]);
  console.log('     corners ix=' + w.ix + ' iy=' + w.iy + ' frac=(' + w.ax.toFixed(3) + ',' + w.ay.toFixed(3) + ')  pipe frac px=(' +
    ((q[0] + q[1] / 256) - w.ix).toFixed(4) + ',' + ((r[0] + r[1] / 256) - w.iy).toFixed(4) + ')');
}
