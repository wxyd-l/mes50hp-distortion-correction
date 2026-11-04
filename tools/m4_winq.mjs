// m4_winq.mjs -- 鎶曞奖姹傞€嗙殑鍑犵鍙栫鏂瑰紡瀵规瘮锛堜竴娆¤窇瀹岋級
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, perspNorm, lo_of, base_of, SW3, RPB3 } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const ROLL = Number(process.env.ROLL || 0);
const MAR = Number(process.env.MAR || 8);
const XEXT = 24, CXr = 639.5, CYr = 359.5, FXr = 750;
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const k1p = k1p_of(K1Q);
const CASES = (process.env.CASES || '0/20/0, 0/20/20, 15/20/0, 15/20/20').split(',')
  .map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NTT = FW / TW;
const sdiv = (a, b) => Math.floor(a / b);
const co = (g) => ({
  A00: g.a00 / 2**28, A01: g.a01 / 2**28, A02: g.a02 / 2**28,
  A10: g.a10 / 2**28, A11: g.a11 / 2**28, A12: g.a12 / 2**28,
  W0: g.w0 / 2**24, H20: g.h20 / 2**24, H21: g.h21 / 2**24 });

// 婧愯 r銆佽緭鍑哄垪 u -> 婧愬垪锛坧inhole 闂紡锛夛紝鍐嶅彔妗跺舰 du
function srcColAtIt(C, u, r, iters) {
  let yn = (r - CYr) / FXr;
  let out = null;
  for (let k = 0; k <= iters; k++) {
    out = srcColAtYn(C, u, yn);
    if (!out) return null;
    if (k === iters) break;
    const r2 = out.xn * out.xn + yn * yn;
    const sc = 1 + (Number(process.env.K1R || -0.134)) * r2;
    yn = (r - CYr) / (FXr * sc);
  }
  return out.sx;
}
function srcColAt(C, u, r) {
  const q = srcColAtYn(C, u, (r - CYr) / FXr);
  return q ? q.sx : null;
}
function srcColAtYn(C, u, yn) {
  const d2 = C.A11 - yn * C.H21;
  if (Math.abs(d2) < 1e-9) return null;
  const v = (yn * C.W0 - C.A12 - (C.A10 - yn * C.H20) * u) / d2;
  const dn = C.W0 + C.H20 * u + C.H21 * v;
  if (Math.abs(dn) < 1e-9) return null;
  const xn = (C.A00 * u + C.A01 * v + C.A02) / dn;
  return { xn: xn, sx: xn * FXr + CXr };
}
function addDu(C, ua0, r) {
  const ua = Math.round(ua0);
  const au2 = 2 * ua - 1279, A2 = sdiv(au2 * au2, 4);
  const b2 = 2 * r - 719, B2 = sdiv(b2 * b2, 4);
  return ua + sdiv(k1p * (A2 + B2) * au2, 33554432);
}
function loOf(C, x0, r, mode, mar) {
  const it = Number(process.env.IT || 0);
  const a = srcColAtIt(C, x0, r, it), b = srcColAtIt(C, x0 + TW - 1, r, it), c = srcColAtIt(C, x0 + TW + XEXT, r, it);
  let e;
  if (mode === 'left') e = a;
  else if (mode === 'minLR') e = Math.min(a, b);
  else if (mode === 'min3') e = Math.min(a, Math.min(b, c));
  else e = a;
  if (e === null) e = 0;
  e = addDu(C, e, r);
  let lo = e - mar;
  if (lo < 0) lo = 0;
  lo = Math.floor(lo / 16) * 16;
  return lo > 1024 ? 1024 : lo;
}
// 琛岀獥鍙ｏ細涓ょ鍙樹綋
function baseOf2(C, v, x0, withDvc) {
  const syAt = (u) => {
    const W = C.W0 + C.H20 * u + C.H21 * v;
    const yn = (C.A10 * u + C.A11 * v + C.A12) / W;
    return yn * FXr + CYr;
  };
  const s1 = Math.round(syAt(x0)), s2 = Math.round(syAt(x0 + TW + XEXT));
  const va = Math.min(s1, s2);
  const vaC = va < 0 ? 0 : (va > FH - 1 ? FH - 1 : va);
  if (!withDvc) {
    const b = vaC - 2;
    return b < 0 ? 0 : (b > FH - RPB3 ? FH - RPB3 : b);
  }
  const b2 = 2 * vaC - 719;
  const au2c = 2 * x0 + TW - 1279;
  const r2 = sdiv(au2c * au2c, 4) + sdiv(b2 * b2, 4);
  const dvc = sdiv(k1p * r2 * b2, 33554432);
  const vcs = sdiv(b2 + 2 * dvc + 719, 2);
  const bsel = vcs - MAR - 2;
  if (bsel < 0) return 0;
  return bsel > FH - RPB3 ? FH - RPB3 : bsel;
}

console.log('rot tilt pitch | colCur  lo:left  lo:minLR  lo:min3 | rowCur  base:dvc  base:plain');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch), C = co(g);
  const res = { colCur: 0, left: 0, minLR: 0, min3: 0, rowCur: 0, dvc: 0, plain: 0 };
  for (let v = 0; v < FH; v++) for (let t = 0; t < NTT; t++) {
    const x0 = t * TW;
    const bC = base_of(g, k1p, v, x0), bD = baseOf2(C, v, x0, true), bP = baseOf2(C, v, x0, false);
    for (let u = x0; u < x0 + TW; u++) {
      const [s1x, s1y] = perspNorm(g, u, v);
      const sp = mapper.fromNorm(s1x, s1y);
      const uc = to_q8(sp[0])[0], vr = Math.min(to_q8(sp[1])[0], FH - 1), v2 = Math.min(Math.min(to_q8(sp[1])[0], FH - 1) + 1, FH - 1);
      const inW = (lo) => (uc - lo >= 0 && uc - lo <= SW3 - 1 && uc + 1 - lo >= 0 && uc + 1 - lo <= SW3 - 1);
      if (!(inW(lo_of(g, k1p, x0, vr)) && inW(lo_of(g, k1p, x0, v2)))) res.colCur++;
      for (const m of ['left', 'minLR', 'min3']) {
        if (!(inW(loOf(C, x0, vr, m, MAR)) && inW(loOf(C, x0, v2, m, MAR)))) res[m]++;
      }
      const ok = (b) => (vr >= b && vr < b + RPB3 && v2 >= b && v2 < b + RPB3);
      if (!ok(bC)) res.rowCur++;
      if (!ok(bD)) res.dvc++;
      if (!ok(bP)) res.plain++;
    }
  }
  console.log(String(rot).padStart(3)+String(tilt).padStart(5)+String(pitch).padStart(6)+' |'+
    String(res.colCur).padStart(7)+String(res.left).padStart(9)+String(res.minLR).padStart(10)+String(res.min3).padStart(10)+' |'+
    String(res.rowCur).padStart(7)+String(res.dvc).padStart(10)+String(res.plain).padStart(12));
}

