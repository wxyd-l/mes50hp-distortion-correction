// m4_win4.mjs -- 便宜的替代路线评估：只改 SW 与 MARGIN（不动估计器公式）能到哪
//
// 固定现行 lo_of() 的结构，扫 SW in {256,320,384,512} x MARGIN in 0..240，
// 对每个 case 找"能清零 colMiss 的 MARGIN 区间"。若同一角度区间存在公共 MARGIN，
// 那 M3b 就可以用一个参数解决，不必重写估计器。
import { FW, FH, TW, Mapper, to_q8 } from './bil_golden_lib.mjs';
import { geom, perspNorm, lo_of } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const ROLL= Number(process.env.ROLL|| 0);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const CASES = (process.env.CASES || '0/20/0, 0/20/20, 15/20/0, 15/20/20').split(',')
  .map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NTT = FW / TW;
const SWS = [256, 320, 384, 512];

// 预算每个像素相对"本行真正需要的 cmin"的偏移：need = uc - cmin(r)
// 现行 lo 与 cmin 的差 d = lo_cur - cmin，则窗口够用的条件是 need - (lo_cur - cmin - MG) ∈ [0, SW-1]
// 直接把 lo_cur 里 MARGIN 的部分剥掉（lo_of 用 MG=0 生成），后面扫 MG 即可。
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch);
  // 收集 (cminBin, uc) 对：用源行分箱得到 cmin
  const cmin = new Int32Array(NTT * FH).fill(1 << 30);
  const px = [];
  for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++) {
    const t = (u / TW) | 0;
    const [s1x, s1y] = perspNorm(g, u, v);
    const sp = mapper.fromNorm(s1x, s1y);
    const uc = to_q8(sp[0])[0], vr = Math.min(to_q8(sp[1])[0], FH - 1);
    const v2 = Math.min(vr + 1, FH - 1);
    for (const r of (vr === v2 ? [vr] : [vr, v2])) { const k = t * FH + r; if (uc < cmin[k]) cmin[k] = uc; }
    px.push([t, uc, vr, v2]);
  }
  // lo_cur0(r, t) = 现行公式但 MARGIN 取 0（MG=0 → MARGIN3=0）
  process.env.MG = '0';
  const lo0 = new Float64Array(NTT * FH);
  for (let t = 0; t < NTT; t++) for (let r = 0; r < FH; r++) lo0[t * FH + r] = lo_of(g, k1pOf(), t * TW, r);
  const row = [];
  for (const SW of SWS) {
    let bestMG = -1, bestMiss = Infinity, loMG = 1e9, hiMG = -1e9;
    for (let MG = 0; MG <= 240; MG++) {
      let miss = 0;
      for (const [t, uc, vr, v2] of px) {
        const l1 = Math.floor(Math.max(0, lo0[t * FH + vr] - MG) / 16) * 16;
        const l2 = Math.floor(Math.max(0, lo0[t * FH + v2] - MG) / 16) * 16;
        const ok = (lo) => (uc - lo >= 0 && uc - lo <= SW - 1 && uc + 1 - lo >= 0 && uc + 1 - lo <= SW - 1);
        if (!(ok(l1) && (v2 === vr || ok(l2)))) miss++;
      }
      if (miss < bestMiss) { bestMiss = miss; bestMG = MG; }
      if (miss === 0) { if (MG < loMG) loMG = MG; if (MG > hiMG) hiMG = MG; }
    }
    row.push({ SW, bestMiss, bestMG, loMG, hiMG });
  }
  process.env.MG = '56';
  console.log('rot=' + rot + ' tilt=' + tilt + ' pitch=' + pitch);
  for (const q of row) {
    console.log('   SW=' + String(q.SW).padStart(4) + '  bestMiss=' + String(q.bestMiss).padStart(7) +
      '  @MG=' + String(q.bestMG).padStart(3) +
      (q.hiMG > -1 ? '   清零MG区间=[' + q.loMG + ',' + q.hiMG + ']' : '   无法清零'));
  }
}
function k1pOf() { return -Math.floor(((-K1Q) + Math.floor(562500 / 2)) / 562500); }
