// m3b_persp_check.mjs -- M3b 选型验证：透视走 distortion_mapper(NORMALIZED_INPUT=1)
//
// 路线:  (u,v) --H--> (X/W, Y/W) --Q8.24--> Brown-Conrady --> fx,cx,cy --> src
//        除法用 24 级全流水倒数 r = 2^48 / W_q24（x、y 共用同一个 r）
// 要回答: (1) 定点误差多少像素  (2) 源列窗口还要不要加宽/行窗口够不够
import { FW, FH, TW, NT, Mapper, to_q8, src_px } from './bil_golden_lib.mjs';

const FX = 750.0, CX = 639.5, CY = 359.5;

// 平面 (X,Y,0) 被相机在距离 d 外看，相机姿态 (yaw 俯仰/倾斜, roll 旋转)
// 屏幕平面绕自己的中心转 (roll 绕光轴, tilt 绕竖直轴), 相机在距离 d 处正对平面中心。
// 这样主光线永远打在平幕中心 -> 没有额外平移项, 和真实"斜拍屏幕"一致。
function planeHomography(tiltDeg, rollDeg) {
  const t = tiltDeg * Math.PI / 180, r = rollDeg * Math.PI / 180;
  const ct = Math.cos(t), st = Math.sin(t), cr = Math.cos(r), sr = Math.sin(r);
  // R = Rz(roll) * Ry(tilt)
  const R = [
    [cr * ct, -sr, cr * st],
    [sr * ct,  cr, sr * st],
    [-st,       0,  ct],
  ];
  const d = FX;
  return {
    a00: R[0][0] / d, a01: R[0][1] / d, a02: 0,
    a10: R[1][0] / d, a11: R[1][1] / d, a12: 0,
    h20: R[2][0] / d, h21: R[2][1] / d,
  };
}

// 精确（实数）参考
function exact(H, k1, u, v) {
  const xp = u - CX, yp = v - CY;          // 以主点为原点
  const A = H.a00 * xp + H.a01 * yp + H.a02;
  const B = H.a10 * xp + H.a11 * yp + H.a12;
  const W = 1 + H.h20 * xp + H.h21 * yp;
  const xn = A / W, yn = B / W;
  const r2 = xn * xn + yn * yn;
  const s = 1 + k1 * r2;
  return [xn * s * FX + CX, yn * s * FX + CY];
}

// 定点（照 RTL 走）
function fixed(H, k1q, u, v, mapper) {
  const A = Math.round((H.a00 * u + H.a01 * v + (H.a02 - H.a00 * CX - H.a01 * CY)) * 2 ** 28);
  const B = Math.round((H.a10 * u + H.a11 * v + (H.a12 - H.a10 * CX - H.a11 * CY)) * 2 ** 28);
  const W = Math.round((1 + H.h20 * (u - CX) + H.h21 * (v - CY)) * 2 ** 24);
  const r = Math.floor(2 ** 48 / W);                 // Q8.24 倒数
  const nx = Math.floor((A * r) / 2 ** 28);
  const ny = Math.floor((B * r) / 2 ** 28);
  return mapper.fromNorm(nx, ny);                    // 后半段就是现有团队核
}

function runCase(yaw, roll, k1q) {
  const H = planeHomography(yaw, roll);
  const k1 = k1q / 16777216;
  const mapper = new Mapper(FX, CX, CY, k1);
  let maxErr = 0, over = 0, n = 0;
  let rowSpan = 0, vertSpan = 0;
  const step = 2;
  for (let t = 0; t < NT; t++) {
    const u0 = t * TW, u1 = u0 + TW;
    for (let v = 0; v < FH; v += step) {
      let xlo = 1e9, xhi = -1e9, ylo = 1e9, yhi = -1e9;
      for (let u = u0; u < u1; u++) {
        const [ex, ey] = exact(H, k1, u, v);
        if (ex < xlo) xlo = ex; if (ex > xhi) xhi = ex;
        if (ey < ylo) ylo = ey; if (ey > yhi) yhi = ey;
        if ((u % 4) === 0) {
          const [fx2, fy2] = fixed(H, k1q, u, v, mapper);
          const d = Math.max(Math.abs(fx2 / 65536 - ex), Math.abs(fy2 / 65536 - ey));
          if (d > maxErr) maxErr = d;
          if (d > 1) over++;
          n++;
        }
      }
      if (xhi - xlo > rowSpan) rowSpan = xhi - xlo;
      if (yhi - ylo > vertSpan) vertSpan = yhi - ylo;
    }
  }
  // 溢出/合法性: |x_n|,|y_n| 要远小于 128（Q8.24 8.24），W 必须为正
  let maxN = 0, minW = 1e9, maxW = -1e9;
  for (let v = 0; v < FH; v += 8) {
    for (let u = 0; u < FW; u += 8) {
      const A = H.a00 * (u - CX) + H.a01 * (v - CY) + H.a02;
      const B = H.a10 * (u - CX) + H.a11 * (v - CY) + H.a12;
      const W = 1 + H.h20 * (u - CX) + H.h21 * (v - CY);
      if (W < minW) minW = W; if (W > maxW) maxW = W;
      maxN = Math.max(maxN, Math.abs(A / W), Math.abs(B / W));
    }
  }
  return { maxErr, over, n, rowSpan, vertSpan, maxN, minW, maxW };
}

console.log('tilt  roll   max|err_px|  >1px%  row_span  vert_span  SW256 RPB128  max|norm|   W range');
for (const yaw of [0, 10, 20, 30, 40]) {
  for (const roll of [0, 20]) {
    const r = runCase(yaw, roll, -2248147);
    console.log(
      String(yaw).padStart(3) + '  ' + String(roll).padStart(4) +
      '  ' + r.maxErr.toFixed(5).padStart(10) + '  ' + (100 * r.over / r.n).toFixed(2).padStart(6) +
      '  ' + r.rowSpan.toFixed(1).padStart(8) + '  ' + r.vertSpan.toFixed(1).padStart(9) +
      '  ' + (r.rowSpan < 200 ? 'ok ' : 'NO ').padStart(5) +
      '  ' + (r.vertSpan < 110 ? 'ok' : 'NO').padStart(6) +
      '  ' + r.maxN.toFixed(3).padStart(9) +
      '  ' + ('[' + r.minW.toFixed(2) + ',' + r.maxW.toFixed(2) + ']').padStart(14));
  }
}
