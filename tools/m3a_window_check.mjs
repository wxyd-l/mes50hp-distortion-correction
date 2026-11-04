// m3a_window_check.mjs -- 验证"像素域仿射 + 径向修正"的每行加载窗口是否覆盖所有读取
//
// 目标公式 (准备写进 RTL):
//   u_aff(v)  = a00*x0 + a01*v + a02  (归一化) * FX + CX      // 仿射源列
//   au2 = 2*(u_aff - CX) ; A2 = au2^2/4
//   b2  = 2v - 2CY       ; B2 = b2^2/4
//   lo(v) = floor16( u_aff + du_of(A2+B2, au2) )
// 覆盖条件: 源行 r 被读到的列 ∈ [lo(r), lo(r)+LDA-1]
import { FW, FH, TW, NT } from './bil_golden_lib.mjs';

const FX = 750.0, CX = 639.5, CY = 359.5;
const CY2V = 719, LDA = 256, MARGIN = 20;

function rotAffine(deg) {
  const t = deg * Math.PI / 180, c = Math.cos(t), s = Math.sin(t);
  return { a00: c / FX, a01: -s / FX, a10: s / FX, a11: c / FX };
}
function srcX(A, k1, u, v) {
  const x = A.a00 * u + A.a01 * v + A.a02;
  const y = A.a10 * u + A.a11 * v + A.a12;
  const r2 = x * x + y * y;
  return x * (1 + k1 * r2) * FX + CX;
}
// 与 RTL ud_tile_core_bil 一致: K1P = round(K1CFG / FX2V), du = (K1P*R2*au2)>>25
function du_of(r2, au2, k1p) { return Math.floor((k1p * r2 * au2) / 33554432); }

function check(deg, k1q) {
  const k1 = k1q / 16777216;
  const A = rotAffine(deg);
  const k1p = Math.round(k1q / (FX * FX));
  A.a02 = -(A.a00 * CX + A.a01 * CY);
  A.a12 = -(A.a10 * CX + A.a11 * CY);
  const { a02 } = A;
  let miss = 0, worstL = 0, worstR = 0, minMargin = 1e9;
  for (let t = 0; t < NT; t++) {
    const x0 = t * TW;
    for (let r = 0; r < FH; r++) {
      let lo = 1e9, hi = -1e9;
      for (let v = Math.max(0, r - 2); v <= Math.min(FH - 1, r + 2); v++) {
        for (let u = x0; u < x0 + TW; u++) {
          const sx = srcX(A, k1, u, v);
          if (sx < lo) lo = sx; if (sx > hi) hi = sx;
        }
      }
      const uAff = (A.a00 * x0 + A.a01 * r + a02) * FX + CX;
      const au2 = 2 * (uAff - CX);
      const A2 = Math.floor(au2 * au2 / 4);
      const b2 = 2 * r - CY2V;
      const B2 = Math.floor(b2 * b2 / 4);
      const loF = Math.floor((uAff + du_of(A2 + B2, au2, k1p) - MARGIN) / 16) * 16;
      const leftSlack = lo - loF;
      const rightSlack = (loF + LDA - 1) - hi;
      if (leftSlack < 0 || rightSlack < 0) miss++;
      if (-leftSlack > worstL) worstL = -leftSlack;
      if (-rightSlack > worstR) worstR = -rightSlack;
      if (Math.min(leftSlack, rightSlack) < minMargin) minMargin = Math.min(leftSlack, rightSlack);
    }
  }
  return { k1, miss, worstL, worstR, minMargin };
}

console.log('deg    k1        misses  left_short  right_short  min_margin');
for (const d of [0, 5, 10, 15, 20, 25, 30, 45]) {
  for (const k of [-2248147, 0, 838860, -838860]) {
    const r = check(d, k);
    console.log(String(d).padStart(3) + '  ' + r.k1.toFixed(3).padStart(7) +
      '  ' + String(r.miss).padStart(6) + '  ' + String(r.worstL).padStart(10) +
      '  ' + String(r.worstR).padStart(11) + '  ' + String(r.minMargin).padStart(10));
  }
}
