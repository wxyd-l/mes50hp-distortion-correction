// m4_winp.mjs -- 正规做法：窗口由【投影求逆的闭式解】给出，不用仿射近似
//
// 前向（像素域，主点已折入常数项）:
//   xn = (A00*u + A01*v + A02) / (W0 + H20*u + H21*v)
//   yn = (A10*u + A11*v + A12) / (W0 + H20*u + H21*v)
// 列窗口 lo(r)：输出列固定 u = x0、源行 r -> 解出 v，再直接得 xn -> 源列 sx = xn*fx + cx
//     v  = (yn*W0 - A12 - (A10 - yn*H20)*x0) / (A11 - yn*H21)
//     xn = (A00*x0 + A01*v + A02) / (W0 + H20*x0 + H21*v)
// 行窗口 base：输出行固定 v = row、在 u = x0 与 u = x0+TW+XEXT 两点求 yn -> sy，取 min/max
// 桶形畸变沿用现有 du / dvc 位移项（与 M3a 同一套）。
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, perspNorm, lo_of, base_of, SW3, RPB3 } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const ROLL = Number(process.env.ROLL || 0);
const MAR = Number(process.env.MAR || 8);
const XEXT = 24, CXr = 639.5, CYr = 359.5, FXr = 750;
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const k1p = k1p_of(K1Q);
const CASES = (process.env.CASES || '0/20/0, 0/20/20, 15/20/0, 15/20/20, 20/30/20').split(',')
  .map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NTT = FW / TW;
const sdiv = (a, b) => Math.floor(a / b);

function co(g) {
  return {
    A00: g.a00 / 2 ** 28, A01: g.a01 / 2 ** 28, A02: g.a02 / 2 ** 28,
    A10: g.a10 / 2 ** 28, A11: g.a11 / 2 ** 28, A12: g.a12 / 2 ** 28,
    W0: g.w0 / 2 ** 24, H20: g.h20 / 2 ** 24, H21: g.h21 / 2 ** 24,
  };
}

// 列窗口：u = x0 固定，源行 r -> 源列（pinhole），再叠桶形 du
function loP(C, x0, r) {
  const yn = (r - CYr) / FXr;
  const d2 = C.A11 - yn * C.H21;
  if (Math.abs(d2) < 1e-12) return 0;
  const v = (yn * C.W0 - C.A12 - (C.A10 - yn * C.H20) * x0) / d2;
  const dn = C.W0 + C.H20 * x0 + C.H21 * v;
  const xn = (C.A00 * x0 + C.A01 * v + C.A02) / dn;
  const uAff = xn * FXr + CXr;
  const au2 = 2 * Math.round(uAff) - 1279;
  const A2 = sdiv(au2 * au2, 4);
  const b2 = 2 * r - 719;
  const B2 = sdiv(b2 * b2, 4);
  const du = sdiv(k1p * (A2 + B2) * au2, 33554432);
  let lo = Math.round(uAff) + du - MAR;
  if (lo < 0) lo = 0;
  lo = Math.floor(lo / 16) * 16;
  if (lo > 1024) lo = 1024;
  return lo;
}
// 行窗口：输出行 v 固定，在 tile 两端求 sy，取 min
function baseP(C, v, x0) {
  const uL = x0, uR = x0 + TW + XEXT;
  const syAt = (u) => {
    const W = C.W0 + C.H20 * u + C.H21 * v;
    const yn = (C.A10 * u + C.A11 * v + C.A12) / W;
    return yn * FXr + CYr;
  };
  const s1 = Math.round(syAt(uL)), s2 = Math.round(syAt(uR));
  const va = Math.min(s1, s2);
  const vaC = va < 0 ? 0 : (va > FH - 1 ? FH - 1 : va);
  const b2 = 2 * vaC - 719;
  const au2c = 2 * x0 + TW - 1279;
  const a2c = sdiv(au2c * au2c, 4);
  const r2 = a2c + sdiv(b2 * b2, 4);
  const dvc = sdiv(k1p * r2 * b2, 33554432);
  const vcs = sdiv(b2 + 2 * dvc + 719, 2);
  const bsel = vcs - MAR - 2;
  if (bsel < 0) return 0;
  if (bsel > FH - RPB3) return FH - RPB3;
  return bsel;
}

console.log('rot tilt pitch |  当前col 投影col |  当前row 投影row |  span  |  投影base 竖向余量');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch);
  const C = co(g);
  let colCur = 0, colPro = 0, rowCur = 0, rowPro = 0, spanMax = 0, vsMax = 0;
  const loCache = new Map(), baseCache = new Map();
  const loC = (x0, r) => { const k = x0 * 1000 + r; if (!loCache.has(k)) loCache.set(k, loP(C, x0, r)); return loCache.get(k); };
  const baseC = (v, x0) => { const k = x0 * 1000 + v; if (!baseCache.has(k)) baseCache.set(k, baseP(C, v, x0)); return baseCache.get(k); };
  for (let v = 0; v < FH; v++) {
    for (let t = 0; t < NTT; t++) {
      const x0 = t * TW;
      const bC = base_of(g, k1p, v, x0), bP = baseC(v, x0);
      for (let u = x0; u < x0 + TW; u++) {
        const [s1x, s1y] = perspNorm(g, u, v);
        const sp = mapper.fromNorm(s1x, s1y);
        const uc = to_q8(sp[0])[0], vr = Math.min(to_q8(sp[1])[0], FH - 1);
        const v2 = Math.min(vr + 1, FH - 1);
        const inW = (lo) => (uc - lo >= 0 && uc - lo <= SW3 - 1 && uc + 1 - lo >= 0 && uc + 1 - lo <= SW3 - 1);
        if (!(inW(lo_of(g, k1p, x0, vr)) && (v2 === vr || inW(lo_of(g, k1p, x0, v2))))) colCur++;
        if (!(inW(loC(x0, vr)) && (v2 === vr || inW(loC(x0, v2))))) colPro++;
        const ok = (b) => (vr >= b && vr < b + RPB3 && v2 >= b && v2 < b + RPB3);
        if (!ok(bC)) rowCur++;
        if (!ok(bP)) rowPro++;
      }
      const d = Math.abs(bP - bC);
      if (d > vsMax) vsMax = d;
      spanMax = Math.max(spanMax, 0);
    }
  }
  console.log(String(rot).padStart(3) + String(tilt).padStart(5) + String(pitch).padStart(6) + ' |' +
    String(colCur).padStart(9) + String(colPro).padStart(8) + ' |' + String(rowCur).padStart(9) + String(rowPro).padStart(8) +
    ' |' + String(spanMax).padStart(6) + '  |' + String(vsMax).padStart(10));
}
