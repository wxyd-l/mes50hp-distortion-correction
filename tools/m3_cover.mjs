// m3_cover.mjs -- 行窗口 / 列窗口覆盖率：采样点落在窗口外 = 取到陈旧值（RTL 与模型一起错）
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, lo_of, base_of, SW3, RPB3 } from './m3_model.mjs';
const K1Q = Number(process.env.K1Q || -2248147);
const MG = Number(process.env.MG || 56);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const k1p = k1p_of(K1Q);
const rots = (process.env.ROTS || '0,5,10,15,20,25,30').split(',').map(Number);
console.log('rot |  rowMiss   colMiss   either   (of 921600)');
for (const rot of rots) {
  const g = geom(rot);
  let rowMiss = 0, colMiss = 0, either = 0;
  for (let v = 0; v < FH; v++) {
    for (let u = 0; u < FW; u++) {
      const x0 = Math.floor(u / TW) * TW;
      const ax = g.a00 * u + g.a01 * v + g.a02;
      const ay = g.a10 * u + g.a11 * v + g.a12;
      const sp = mapper.fromNorm(Math.floor(ax / 16), Math.floor(ay / 16));
      const uc = to_q8(sp[0])[0], vrn = to_q8(sp[1])[0];
      const v1 = Math.min(vrn, FH - 1), v2 = Math.min(v1 + 1, FH - 1);
      const base = base_of(g, k1p, v, x0);
      const wb1 = lo_of(g, k1p, x0, v1), wb2 = lo_of(g, k1p, x0, v2);
      let rm = !(v1 >= base && v1 < base + RPB3);
      const rbBad = (v2 !== v1) && !(v2 >= base && v2 < base + RPB3);
      const c1 = uc - wb1, c2 = uc + 1 - wb1, c3 = uc - wb2, c4 = uc + 1 - wb2;
      let cm = !(c1 >= 0 && c1 <= 255 && c2 >= 0 && c2 <= 255 && c3 >= 0 && c3 <= 255 && c4 >= 0 && c4 <= 255);
      if (rm || rbBad) rowMiss++;
      if (cm) colMiss++;
      if (rm || rbBad || cm) either++;
    }
  }
  console.log(String(rot).padStart(3) + ' | ' + String(rowMiss).padStart(7) + '  ' + String(colMiss).padStart(7) +
    '  ' + String(either).padStart(7) + '   (' + (100 * either / (FW * FH)).toFixed(3) + '%)');
}
