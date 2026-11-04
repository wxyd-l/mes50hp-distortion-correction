// m4_win3.mjs -- 可实现的估计器：每输出行采两个端点，窗口内按 r 线性插值
//
// RTL 能做到的形态：
//   每输出行开始时，用同一条透视流水探 (x0, row_v) 与 (x0+TW+XEXT, row_v) 两点，
//   得 (uc_L, vr_L)、(uc_R, vr_R)；
//     base = min(vr_L, vr_R) - LEAD
//     lo(r) = uc_L + (uc_R-uc_L)*(r-vr_L)/(vr_R-vr_L) - MARGIN , 再 floor16 钳位
// 这里量这个方案能不能把 colMiss/rowMiss 清到 0。
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, perspNorm, SW3, RPB3 } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const ROLL= Number(process.env.ROLL|| 0);
const MAR = Number(process.env.MAR || 8);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const CASES = (process.env.CASES || '0/20/0, 0/20/20, 15/20/0, 15/20/20, 20/30/20').split(',')
  .map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NT = FW / TW;
const XEXT = 24;
const PROBE_U1 = (t) => t * TW + TW + XEXT;      // 右端点（覆盖 XEXT 尾巴）

function probe(g, u, v) {
  const [s1x, s1y] = perspNorm(g, u, v);
  const sp = mapper.fromNorm(s1x, s1y);
  return [to_q8(sp[0])[0], Math.min(to_q8(sp[1])[0], FH - 1)];
}

console.log('rot tilt pitch |  colMiss(端点插值)  colMiss(MARGIN+4)  |  rowMiss(端点)  |  最大竖向span  RPB 余量');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch);
  let colA = 0, colB = 0, rowA = 0, vsMax = 0;
  for (let v = 0; v < FH; v++) {
    for (let t = 0; t < NT; t++) {
      const x0 = t * TW;
      const [ucL, vrL] = probe(g, x0, v);
      const [ucR, vrR] = probe(g, PROBE_U1(t), v);
      const rlo = Math.min(vrL, vrR), rhi = Math.max(vrL, vrR);
      const vs = rhi - rlo + 1;
      if (vs > vsMax) vsMax = vs;
      const base = Math.max(0, Math.min(rlo - 2, FH - RPB3));
      const den = vrR - vrL;
      const slope = den === 0 ? 0 : (ucR - ucL) / den;
      const loOf = (r) => {
        const e = Math.round(ucL + slope * (r - vrL)) - MAR;
        let x = e < 0 ? 0 : e;
        x = Math.floor(x / 16) * 16;
        return x > 1024 ? 1024 : x;
      };
      for (let u = x0; u < x0 + TW; u++) {
        const [uc, vr] = probe(g, u, v);
        const v2 = Math.min(vr + 1, FH - 1);
        const inW = (lo, r) => (uc - lo >= 0 && uc - lo <= SW3 - 1 && uc + 1 - lo >= 0 && uc + 1 - lo <= SW3 - 1);
        if (!(inW(loOf(vr), vr) && (v2 === vr || inW(loOf(v2), v2)))) colA++;
        const loOfB = (r) => {
          const e = Math.round(ucL + slope * (r - vrL)) - MAR - 4;
          let x = e < 0 ? 0 : e; x = Math.floor(x / 16) * 16; return x > 1024 ? 1024 : x;
        };
        if (!(inW(loOfB(vr), vr) && (v2 === vr || inW(loOfB(v2), v2)))) colB++;
        if (!(vr >= base && vr < base + RPB3 && v2 >= base && v2 < base + RPB3)) rowA++;
      }
    }
  }
  console.log(String(rot).padStart(3)+String(tilt).padStart(5)+String(pitch).padStart(6)+' |'+
    String(colA).padStart(17)+String(colB).padStart(19)+'  |'+String(rowA).padStart(14)+'  |'+
    String(vsMax).padStart(12)+String(RPB3 - vsMax).padStart(9));
}
