// m3_geomerr.mjs -- 管线实际采样坐标 vs 实数理想采样坐标（源像素单位）
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom } from './m3_model.mjs';
const K1Q = Number(process.env.K1Q || -2248147);
const k1r = K1Q / 16777216.0;
const mapper = new Mapper(750.0, 639.5, 359.5, k1r);
const rots = (process.env.ROTS || '0,5,10,15,20').split(',').map(Number);
console.log('rot |  mean|err|   p99|err|   max|err|   >0.05px   >0.5px   (in-frame, source px)');
for (const rot of rots) {
  const g = geom(rot);
  const t = rot * Math.PI / 180, ca = Math.cos(t), sa = Math.sin(t);
  let n = 0, sum = 0, mx = 0, c05 = 0, c5 = 0;
  const errs = [];
  for (let v = 0; v < FH; v++) {
    const y = (v - 359.5) / 750.0;
    for (let u = 0; u < FW; u++) {
      const x = (u - 639.5) / 750.0;
      const xr = ca * x - sa * y, yr = sa * x + ca * y;
      const r2 = xr * xr + yr * yr;
      const sx = xr * (1.0 + k1r * r2) * 750.0 + 639.5;
      const sy = yr * (1.0 + k1r * r2) * 750.0 + 359.5;
      if (!(sx >= 1 && sx <= FW - 2 && sy >= 1 && sy <= FH - 2)) continue;
      const ax = g.a00 * u + g.a01 * v + g.a02;
      const ay = g.a10 * u + g.a11 * v + g.a12;
      const sp = mapper.fromNorm(Math.floor(ax / 16), Math.floor(ay / 16));
      const q = to_q8(sp[0]), r = to_q8(sp[1]);
      const pxs = q[0] + q[1] / 256, pys = r[0] + r[1] / 256;
      const e = Math.hypot(pxs - sx, pys - sy);
      n++; sum += e; if (e > mx) mx = e;
      if (e > 0.05) c05++;
      if (e > 0.5) c5++;
      if (errs.length < 500000) errs.push(e);
    }
  }
  errs.sort((a, b) => a - b);
  const p99 = errs.length ? errs[Math.floor(errs.length * 0.99)] : 0;
  console.log(String(rot).padStart(3) + ' |  ' + (sum / n).toFixed(5) + '   ' + p99.toFixed(4) + '   ' +
    mx.toFixed(4) + '   ' + c05 + '   ' + c5 + '   (n=' + n + ')');
}
