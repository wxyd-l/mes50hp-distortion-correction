// m4_cover.mjs -- M3b 透视下的行窗口/列窗口覆盖率
// 采样点落在窗口外 = 该像素取到陈旧值（RTL 与黄金模型会一起错，所以必须单独量）。
// 同时报 W 与归一化坐标范围，抓 clamp / 溢出。
//
// 用法: CASES="0/20/0,0/20/20,15/30/20" MG=56 K1Q=-2248147 node tools/m4_cover.mjs
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, perspNorm, winTabOf, lo_of, base_of, SW3, RPB3 } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const MG = Number(process.env.MG || 56);
const ROLL = Number(process.env.ROLL || 0);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const k1p = k1p_of(K1Q);
const CASES = (process.env.CASES || '0/0/0, 0/20/0, 0/20/20, 15/20/0, 15/20/20, 20/30/20')
  .split(',').map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));

console.log('rot tilt pitch |  rowMiss  colMiss   either  (of 921600) |  W range        |  max|norm|   W 越界?');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch);
  const TAB = winTabOf(g, K1Q);
  const persp = !(g.h20 === 0 && g.h21 === 0 && g.w0 === 16777216);
  let rowMiss = 0, colMiss = 0, either = 0, inCol = 0, inRow = 0, inN = 0;
  let wlo = 1e9, whi = -1e9, maxN = 0, wclamp = 0;
  for (let v = 0; v < FH; v++) {
    for (let u = 0; u < FW; u++) {
      const x0 = Math.floor(u / TW) * TW;
      const [s1x, s1y] = perspNorm(g, u, v);
      const sp = mapper.fromNorm(s1x, s1y);
      const uc = to_q8(sp[0])[0], vrn = to_q8(sp[1])[0];
      const v1 = Math.min(vrn, FH - 1), v2 = Math.min(v1 + 1, FH - 1);
      const base = base_of(TAB, v, x0);
      const wb1 = lo_of(TAB, x0, v1), wb2 = lo_of(TAB, x0, v2);
      let rm = !(v1 >= base && v1 < base + RPB3);
      const rbBad = (v2 !== v1) && !(v2 >= base && v2 < base + RPB3);
      const c1 = uc - wb1, c2 = uc + 1 - wb1, c3 = uc - wb2, c4 = uc + 1 - wb2;
      const cm = !(c1 >= 0 && c1 <= SW3 - 1 && c2 >= 0 && c2 <= SW3 - 1 &&
                   c3 >= 0 && c3 <= SW3 - 1 && c4 >= 0 && c4 <= SW3 - 1);
      const inF = (sp[0] >= 0 && sp[0] <= (FW - 1) * 65536 && sp[1] >= 0 && sp[1] <= (FH - 1) * 65536);
      if (inF) { inN++; if (rm || rbBad) inRow++; if (cm) inCol++; }
      if (rm || rbBad) rowMiss++;
      if (cm) colMiss++;
      if (rm || rbBad || cm) either++;
      if (persp) {
        const W = g.w0 + g.h20 * u + g.h21 * v;
        if (W < wlo) wlo = W;
        if (W > whi) whi = W;
        if (W < 4194305 || W > 33554431) wclamp++;
        const n = Math.abs(s1x) > Math.abs(s1y) ? s1x : s1y;
        if (Math.abs(n) > maxN) maxN = Math.abs(n) / 16777216;
      }
    }
  }
  console.log(
    String(rot).padStart(3) + String(tilt).padStart(5) + String(pitch).padStart(6) + ' | ' +
    String(rowMiss).padStart(8) + String(colMiss).padStart(9) + String(either).padStart(9) +
    '   (' + (100 * either / (FW * FH)).toFixed(3) + '%) 画内 col/row=' + inCol + '/' + inRow + ' (' + inN + ' px) | ' +
    (persp ? ('[' + (wlo / 16777216).toFixed(3) + ',' + (whi / 16777216).toFixed(3) + ']') : '  2^24 (恒等)  ') +
    ' | ' + maxN.toFixed(3).padStart(8) + '   ' + (wclamp ? 'CLAMP ' + wclamp : 'ok'));
}
