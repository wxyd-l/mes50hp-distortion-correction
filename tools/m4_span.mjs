// m4_span.mjs -- M3b: 透视下"每个(分块, 源行)到底需要多宽的源列窗口"
//
// m4_cover 只回答"现在的 lo(r) 够不够"；这里回答更根本的问题：
// 就算 lo(r) 定位完全正确，SW=256 到底装不装得下？
//   span = max(uc) - min(uc)  （同一分块、同一源行内）
//   需要 (span + 1) <= SW，因为读数要 uc 与 uc+1 两列。
//
// 同时给出"当前 lo(r) 相对理想 lo 的偏差"，用来判断是定位错还是窗口窄。
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, perspNorm, lo_of, SW3 } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const MG = Number(process.env.MG || 56);
const ROLL = Number(process.env.ROLL || 0);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const k1p = k1p_of(K1Q);
const CASES = (process.env.CASES || '0/0/0, 0/20/0, 0/20/20, 15/20/0, 15/20/20, 20/30/20')
  .split(',').map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NTILE = FW / TW;

console.log('rot tilt pitch |  最大span  超SW的(块,行)数  |  lo(r) 偏差 min/max  (像素)');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch);
  const lo = new Int32Array(NTILE * FH).fill(1 << 30);
  const hi = new Int32Array(NTILE * FH).fill(-(1 << 30));
  for (let v = 0; v < FH; v++) {
    for (let u = 0; u < FW; u++) {
      const t = Math.floor(u / TW);
      const [s1x, s1y] = perspNorm(g, u, v);
      const sp = mapper.fromNorm(s1x, s1y);
      const uc = to_q8(sp[0])[0], vrn = to_q8(sp[1])[0];
      const rows = [Math.min(vrn, FH - 1), Math.min(Math.min(vrn, FH - 1) + 1, FH - 1)];
      for (const r of rows) {
        const k = t * FH + r;
        if (uc < lo[k]) lo[k] = uc;
        if (uc > hi[k]) hi[k] = uc;
      }
    }
  }
  let maxSpan = -1, over = 0, dmin = 1e9, dmax = -1e9;
  for (let t = 0; t < NTILE; t++) {
    for (let r = 0; r < FH; r++) {
      const k = t * FH + r;
      if (hi[k] < lo[k]) continue;
      const sp = hi[k] - lo[k];
      if (sp > maxSpan) maxSpan = sp;
      if (sp + 1 > SW3) over++;
      // 当前 lo(r) 与"理想定位"的差：理想 lo 应 <= lo[k] 且尽量贴近
      const cur = lo_of(g, k1p, t * TW, r);
      const d = cur - lo[k];
      if (d < dmin) dmin = d;
      if (d > dmax) dmax = d;
    }
  }
  console.log(
    String(rot).padStart(3) + String(tilt).padStart(5) + String(pitch).padStart(6) + ' | ' +
    String(maxSpan).padStart(8) + String(over).padStart(14) + '  |  ' +
    String(dmin).padStart(6) + ' / ' + String(dmax).padStart(6));
}
