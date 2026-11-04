// m3a_geom.mjs -- M3a 几何核算：任意角度下源列窗口需要多宽
// 模型 (实数, 与 RTL 的定点近似无关, 只用来定参数)
//   x = a00*u + a01*v + a02 ,  y = a10*u + a11*v + a12     (归一化)
//   r2 = x^2 + y^2 ,  sx = x*(1+k1*r2)*fx + cx
import { FW, FH, TW, NT } from './bil_golden_lib.mjs';

const FX = 750.0, CX = 639.5, CY = 359.5;

function rotAffine(deg) {
  const t = deg * Math.PI / 180;
  const c = Math.cos(t), s = Math.sin(t);
  // 归一化坐标: x' = (u-cx)/fx, y' = (v-cy)/fx ; 旋转后
  const a00 = c / FX, a01 = -s / FX;
  const a10 = s / FX, a11 = c / FX;
  const a02 = -(c * CX - s * CY) / FX;
  const a12 = -(s * CX + c * CY) / FX;
  return { a00, a01, a02, a10, a11, a12 };
}

function srcX(A, k1, u, v) {
  const x = A.a00 * u + A.a01 * v + A.a02;
  const y = A.a10 * u + A.a11 * v + A.a12;
  const r2 = x * x + y * y;
  return x * (1 + k1 * r2) * FX + CX;
}

function analyse(deg, k1, SW, LDA, RPB) {
  const A = rotAffine(deg);
  // 逐 (tile,row) 的行内跨度 —— 这才是"一行要多大窗口"
  let needRow = 0;
  for (let v = 0; v < FH; v++) {
    for (let t = 0; t < NT; t++) {
      let lo = 1e9, hi = -1e9;
      for (let u = t * TW; u < t * TW + TW; u++) {
        const sx = srcX(A, k1, u, v);
        if (sx < lo) lo = sx; if (sx > hi) hi = sx;
      }
      const w = Math.ceil(hi) - Math.floor(lo) + 1;
      if (w > needRow) needRow = w;
    }
  }
  // 每 tile 的整帧跨度
  let needCache = 0;
  const perTile = [];
  for (let t = 0; t < NT; t++) {
    const u0 = t * TW, u1 = u0 + TW;
    let lo = 1e9, hi = -1e9;
    for (let v = 0; v < FH; v++) {
      for (let u = u0; u < u1; u++) {
        const sx = srcX(A, k1, u, v);
        if (sx < lo) lo = sx; if (sx > hi) hi = sx;
      }
    }
    perTile.push([Math.floor(lo), Math.ceil(hi), Math.ceil(hi) - Math.floor(lo) + 1]);
    if (hi - lo + 1 > needCache) needCache = hi - lo + 1;
  }
  // 加载宽度需求: 一行加载 LDA 列, 该行在其驻留 RPB 行内被读取
  const drift = Math.abs(A.a01) * FX;   // 每行源列漂移
  const needLoad = needRow + 2 * Math.ceil(drift * RPB) + 32;
  return { deg, k1, needRow, needCache, drift, needLoad, spanOverRPB: needRow + Math.ceil(drift * RPB) };
}

const cases = [
  [0, -0.134], [10, -0.134], [20, -0.134], [30, -0.134],
  [45, -0.134], [20, 0], [20, 0.05],
];
console.log('deg   k1      needRow  needCache  drift/row  needLoad(+2*RPB drift+32)');
for (const [d, k] of cases) {
  const r = analyse(d, k, 512, 256, 74);
  console.log(
    String(d).padStart(3) + '  ' + String(k).padStart(6) +
    '  ' + String(r.needRow).padStart(7) +
    '  ' + String(r.needCache).padStart(9) +
    '  ' + r.drift.toFixed(3).padStart(10) +
    '  ' + String(r.needLoad).padStart(6));
}
