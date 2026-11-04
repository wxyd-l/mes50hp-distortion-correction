// m4_winr.mjs -- 精确逆映射求窗口：固定点迭代解 sy(u,v)=r，再取 sx
//
// 前向（与 RTL 同一定点结构）:  W = W0 + H20*u + H21*v
//   xn = (A00*u + A01*v + A02)/W , yn = (A10*u + A11*v + A12)/W
//   s = 1 + k1*(xn^2+yn^2) , sx = xn*s*fx + cx , sy = yn*s*fx + cy
// 逆（求 "输出列 u 上、源行 = r 的那个点的源列"）:
//   1) 先由 pinhole 解 yn=(r-cy)/fx 得初始 v
//   2) 迭代: yn <- (r-cy)/(fx*s(u,v)) ，再由 Möbius 反解 v
//   3) 取最后一点的 sx
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, perspNorm, lo_of, base_of, SW3, RPB3 } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const ROLL = Number(process.env.ROLL || 0);
const MAR = Number(process.env.MAR || 8);
const ITER = Number(process.env.ITER || 3);
const XEXT = 24, CXr = 639.5, CYr = 359.5, FXr = 750;
const k1r = K1Q / 16777216.0;
const mapper = new Mapper(750.0, 639.5, 359.5, k1r);
const CASES = (process.env.CASES || '0/20/0, 0/20/20, 15/20/0, 15/20/20').split(',')
  .map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NTT = FW / TW;
const sdiv = (a, b) => Math.floor(a / b);
const co = (g) => ({
  A00: g.a00/2**28, A01: g.a01/2**28, A02: g.a02/2**28,
  A10: g.a10/2**28, A11: g.a11/2**28, A12: g.a12/2**28,
  W0: g.w0/2**24, H20: g.h20/2**24, H21: g.h21/2**24 });

const fwd = (C, u, v) => {
  const W = C.W0 + C.H20*u + C.H21*v;
  const xn = (C.A00*u + C.A01*v + C.A02)/W;
  const yn = (C.A10*u + C.A11*v + C.A12)/W;
  const s = 1 + k1r*(xn*xn + yn*yn);
  return { xn, yn, s, sx: xn*s*FXr + CXr, sy: yn*s*FXr + CYr };
};
// 给定 u 与目标源行 r，解出 v 并返回 sx
const srcCol = (C, u, r) => {
  let yn = (r - CYr)/FXr;
  let v = (yn*C.W0 - C.A12 - (C.A10 - yn*C.H20)*u) / (C.A11 - yn*C.H21);
  for (let k = 0; k < ITER; k++) {
    const F = fwd(C, u, v);
    if (!(F.s > 0.2 && F.s < 5)) break;
    const yt = (r - CYr)/(FXr*F.s);
    v = (yt*C.W0 - C.A12 - (C.A10 - yt*C.H20)*u) / (C.A11 - yt*C.H21);
  }
  return fwd(C, u, v).sx;
};
const loOf = (C, x0, r) => {
  let e = Math.round(srcCol(C, x0, r));
  let lo = e - MAR;
  if (lo < 0) lo = 0;
  lo = Math.floor(lo/16)*16;
  return lo > 1024 ? 1024 : lo;
};
const baseOf = (C, v, x0) => {
  const s1 = fwd(C, x0, v).sy, s2 = fwd(C, x0 + TW + XEXT, v).sy;
  let b = Math.round(Math.min(s1, s2)) - 2;
  if (b < 0) b = 0;
  return b > FH - RPB3 ? FH - RPB3 : b;
};

console.log('ITER=' + ITER + ' MAR=' + MAR);
console.log('rot tilt pitch | colCur  colNew  | rowCur  rowNew | 竖向span  RPB');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch), C = co(g);
  let colCur = 0, colNew = 0, rowCur = 0, rowNew = 0, vsMax = 0;
  for (let v = 0; v < FH; v++) for (let t = 0; t < NTT; t++) {
    const x0 = t*TW;
    const bC = base_of(g, k1p_of(K1Q), v, x0), bN = baseOf(C, v, x0);
    const smin = Math.min(fwd(C, x0, v).sy, fwd(C, x0+TW+XEXT, v).sy);
    const smax = Math.max(fwd(C, x0, v).sy, fwd(C, x0+TW+XEXT, v).sy);
    if (smax - smin > vsMax) vsMax = smax - smin;
    for (let u = x0; u < x0 + TW; u++) {
      const [s1x, s1y] = perspNorm(g, u, v);
      const sp = mapper.fromNorm(s1x, s1y);
      const uc = to_q8(sp[0])[0], vr = Math.min(to_q8(sp[1])[0], FH - 1);
      const v2 = Math.min(vr+1, FH-1);
      const inW = (lo) => (uc-lo>=0 && uc-lo<=SW3-1 && uc+1-lo>=0 && uc+1-lo<=SW3-1);
      if (!(inW(lo_of(g, k1p_of(K1Q), x0, vr)) && inW(lo_of(g, k1p_of(K1Q), x0, v2)))) colCur++;
      if (!(inW(loOf(C, x0, vr)) && (v2===vr || inW(loOf(C, x0, v2))))) colNew++;
      const ok = (b) => (vr>=b && vr<b+RPB3 && v2>=b && v2<b+RPB3);
      if (!ok(bC)) rowCur++;
      if (!ok(bN)) rowNew++;
    }
  }
  console.log(String(rot).padStart(3)+String(tilt).padStart(5)+String(pitch).padStart(6)+' |'+
    String(colCur).padStart(7)+String(colNew).padStart(8)+' |'+String(rowCur).padStart(8)+String(rowNew).padStart(8)+
    ' |'+vsMax.toFixed(1).padStart(9)+String(RPB3).padStart(5));
}
