// m3a_rot_check.mjs -- 带旋转时 M3a 两个窗口是否覆盖所有读取
// 方案 1: lo(r) 用逆映射 v_out = CY + (r-CY)*cfg_iv 取仿射（cfg_iv = 1/(a11*FX)）
import { FW, FH, TW, NT } from './bil_golden_lib.mjs';

const FX = 750.0, CX = 639.5, CY = 359.5;
const CY2V = 719, CX2V = 1279;
const SW = 256, RPB = 128;
const MARGIN = Number(process.env.MG || 48), LEAD = 2;
const K1Q = -2248147;
const k1p = Math.round(K1Q / (FX * FX));
const k1 = K1Q / 16777216;
const USE_IV = process.env.IV !== '0';

function rotAffine(deg) {
  const t = deg * Math.PI / 180, c = Math.cos(t), s = Math.sin(t);
  return { a00: c / FX, a01: -s / FX, a10: s / FX, a11: c / FX, a02: 0, a12: 0 };
}
function normXY(A, u, v) {
  const x = A.a00 * (u - CX) + A.a01 * (v - CY) + A.a02;
  const y = A.a10 * (u - CX) + A.a11 * (v - CY) + A.a12;
  const r2 = x * x + y * y;
  const s = 1 + k1 * r2;
  return [x * s * FX + CX, y * s * FX + CY];
}
function du_of(r2, au2) { return Math.floor((k1p * r2) * au2 / 33554432); }

let A, IV;
function lo_px(x0, r) {
  const vOut = USE_IV ? (CY + (r - CY) * IV) : r;
  const uAff = CX + FX * (A.a00 * (x0 - CX) + A.a01 * (vOut - CY));
  const au2 = 2 * (uAff - CX);
  const A2 = Math.floor(au2 * au2 / 4);
  const b2 = 2 * r - CY2V;
  const B2 = Math.floor(b2 * b2 / 4);
  return Math.max(0, Math.floor((uAff + du_of(A2 + B2, au2) - MARGIN) / 16) * 16);
}
function base_new(v, x0) {
  const tc = x0 + TW / 2;
  const vAff = CY + FX * (A.a10 * (tc - CX) + A.a11 * (v - CY));
  const b2 = Math.round(2 * vAff) - CY2V;
  const au2c = 2 * x0 + TW - CX2V;
  const a2c = Math.floor(au2c * au2c / 4);
  const r2 = a2c + Math.floor(b2 * b2 / 4);
  const dvc = Math.floor((k1p * r2) * b2 / 33554432);
  const vcs = Math.floor((b2 + 2 * dvc + CY2V) / 2);
  const bsel = vcs - MARGIN - LEAD;
  return bsel < 0 ? 0 : (bsel > FH - RPB ? FH - RPB : bsel);
}

function check(deg) {
  A = rotAffine(deg);
  IV = 1 / (A.a11 * FX);
  let missC = 0, wC = 0, missR = 0, wR = 0;
  for (let t = 0; t < NT; t++) {
    const x0 = t * TW;
    for (let v = 0; v < FH; v++) {
      const b = base_new(v, x0);
      for (let u = x0; u < x0 + TW; u += 2) {
        const [sx, sy] = normXY(A, u, v);
        if (sy < 0 || sy > FH - 1 || sx < 0 || sx > FW - 1) continue;   // 出图钳位, 窗口无关
        const uc = Math.floor(sx);
        const v1 = Math.min(Math.max(Math.floor(sy), 0), FH - 1);
        const lo = lo_px(x0, v1);
        if (uc < lo) { missC++; if (lo - uc > wC) wC = lo - uc; }
        if (uc > lo + SW - 1) { missC++; if (uc - lo - SW + 1 > wC) wC = uc - lo - SW + 1; }
        if (v1 < b) { missR++; if (b - v1 > wR) wR = b - v1; }
        if (v1 > b + RPB - 1) { missR++; if (v1 - b - RPB + 1 > wR) wR = v1 - b - RPB + 1; }
      }
    }
  }
  return { deg, missC, wC, missR, wR };
}

console.log('IV=' + (USE_IV ? 'on' : 'off') + '  MARGIN=' + MARGIN);
console.log('rot  col_miss  worst  row_miss  worst');
for (const d of [0, 5, 10, 15, 20, 25, 30]) {
  const r = check(d);
  console.log(String(d).padStart(3) + '  ' + String(r.missC).padStart(8) + '  ' + String(r.wC).padStart(5) +
    '  ' + String(r.missR).padStart(8) + '  ' + String(r.wR).padStart(6));
}
