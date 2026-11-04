// bil_golden_lib.mjs -- 16 位列条双线性核心的定点几何/工具库（Node 移植自 tile_bil_model.py）
// 纯函数，无副作用；tile_bil_model.mjs 与 compare.mjs 共用，避免出现第二份真值。

export const FW = 1280, FH = 720, TW = 160, SW = 192, RPB = 24;
export const MARGIN = 8, LEAD = 2, LAG = 20, XEXT = 24, XMAR = 20, LATCG = 12, NT = 8;
export const HALF = Math.floor(RPB / 2), SWM8 = SW - 1, VWD = SW + 2;
export const RLEN = TW + XEXT + 8;

export const CX2V = 1279, CY2V = 719, FX2V = 750 * 750;
export const B2MAX = (719 * 719) >> 2;

const P32 = 4294967296;
const P47 = 140737488355328;
const P48 = 281474976710656;

export function mod(a, m) { const r = a % m; return r < 0 ? r + m : r; }
export function s32(x) { return mod(x + 2147483648, P32) - 2147483648; }
export function s48(x) { return mod(x + P47, P48) - P47; }
export function s24(x) { return mod(x + 8388608, 16777216) - 8388608; }
export function q24(p) { return s32(Math.floor(p / 16777216)); }

// Python 3 round(): 四舍六入五成双
export function pyRound(x) {
  const f = Math.floor(x), d = x - f;
  if (d > 0.5) return f + 1;
  if (d < 0.5) return f;
  return (f % 2 === 0) ? f : f + 1;
}

export class Mapper {
  constructor(fx, cx, cy, k1, k2 = 0.0, p1 = 0.0, p2 = 0.0) {
    this.a00 = pyRound(2 ** 28 / fx);
    this.a02 = pyRound(-cx / fx * 2 ** 28);
    this.a12 = pyRound(-cy / fx * 2 ** 28);
    this.k1 = pyRound(k1 * 2 ** 24);
    this.k2 = pyRound(k2 * 2 ** 24);
    this.p1 = pyRound(p1 * 2 ** 24);
    this.p2 = pyRound(p2 * 2 ** 24);
    this.fx = pyRound(fx * 65536);
    this.cx = pyRound(cx * 65536);
    this.cy = pyRound(cy * 65536);
  }
  src(u, v) {
    const ax = this.a00 * u + this.a02;
    const ay = this.a00 * v + this.a12;
    const s1x = s32(Math.floor(ax / 16));
    const s1y = s32(Math.floor(ay / 16));
    return this.fromNorm(s1x, s1y);
  }
  // NORMALIZED_INPUT=1 入口：直接从 Q8.24 归一化坐标进 Brown-Conrady 链
  fromNorm(s1x, s1y) {
    const s2xx = s1x * s1x, s2yy = s1y * s1y, s2xy = s1x * s1y;
    const s3xx = q24(s2xx), s3yy = q24(s2yy), s3xy = q24(s2xy);
    const s3r2 = s32(Math.floor(s2xx / 16777216) + Math.floor(s2yy / 16777216));
    const s4r4 = s3r2 * s3r2;
    const s4k1 = this.k1 * s3r2;
    const s4p1 = this.p1 * s3xy;
    const s4p2 = this.p2 * s3xy;
    const s5r4 = q24(s4r4), s5k1 = q24(s4k1), s5p1 = q24(s4p1), s5p2 = q24(s4p2);
    const s6k2r4 = this.k2 * s5r4;
    const tx = s32(s3r2 + 2 * s3xx);
    const ty = s32(s3r2 + 2 * s3yy);
    const s6p2tx = this.p2 * s32(tx);
    const s6p1ty = this.p1 * s32(ty);
    const scale = s32(2 ** 24 + s5k1 + q24(s6k2r4));
    const tanx = s32(2 * s5p1 + q24(s6p2tx));
    const tany = s32(q24(s6p1ty) + 2 * s5p2);
    const s8xr = s1x * scale;
    const s8yr = s1y * scale;
    const s9xd = s32(Math.floor(s8xr / 16777216) + tanx);
    const s9yd = s32(Math.floor(s8yr / 16777216) + tany);
    const sx = s32(Math.floor((s9xd * this.fx) / 16777216) + this.cx);
    const sy = s32(Math.floor((s9yd * this.fx) / 16777216) + this.cy);
    return [sx, sy];
  }
}

export function to_q8(s, bias = 128) {
  let t = s < 0 ? 0 : s;
  if (t > 2147450880) t = 2147483647; else t = t + bias;
  return [(t >> 16) & 0x7FF, (t >> 8) & 0xFF];
}

export function mixc(x0, x1, w) {
  const acc = x0 * 256 + (x1 - x0) * w;
  return Math.floor(acc / 256) & 0x3F;
}

export function k1p_of(k1q) {
  if (k1q >= 0) return Math.floor((k1q + Math.floor(FX2V / 2)) / FX2V);
  return -Math.floor(((-k1q) + Math.floor(FX2V / 2)) / FX2V);
}

export function base_t_of(row_v, tile_x0, k1p, rpb = RPB, margin = MARGIN) {
  const b2 = 2 * row_v - CY2V;
  const au2c = 2 * tile_x0 + TW - CX2V;
  const a2c = Math.floor((au2c * au2c) / 4);
  const b2n = Math.floor((b2 * b2) / 4);
  const r2 = a2c + b2n;
  const dvc = Math.floor(s48(k1p * r2 * b2) / 33554432);
  const vcH = s24(b2 + (dvc * 2) + CY2V);
  const vcS = Math.floor(s24(vcH) / 2);
  const bsel = vcS - margin - LEAD;
  if (bsel < 0) return 0;
  if (bsel > FH - rpb) return FH - rpb;
  return bsel;
}

export function du_of(r2f, au2f, k1p) {
  return Math.floor(s48(r2f * au2f * k1p) / 33554432);
}

export function xs_of(tile_x0, k1p) {
  const au2l = 2 * tile_x0 - CX2V;
  const a2l = Math.floor((au2l * au2l) / 4);
  const xl0 = tile_x0 + du_of(a2l, au2l, k1p);
  const xl1 = tile_x0 + du_of(a2l + B2MAX, au2l, k1p);
  const xlmin = Math.min(xl0, xl1);
  const xsn = Math.floor((xlmin - XMAR) / 16) * 16;
  if (xsn < 0) return 0;
  if (xsn > FW - SW) return FW - SW;
  return xsn;
}

export function src_px(r, c) {
  return ((((r + c) & 31) << 11) | (((r * 3 + c) & 63) << 5) | ((r ^ c) & 31));
}
