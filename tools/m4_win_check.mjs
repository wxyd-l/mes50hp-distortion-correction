
// m4_win_check.mjs -- 窗口表体检：用【真正喂给 RTL 的那张表】逐像素数缺口
//   1) lo(r) 相对精确目标 cmin(r)-MAR 的过冲（>0 = 会左钳，必须 ≤0）
//   2) 画内 colMiss / rowMiss（与 m4_cover.mjs 同口径，只算 in-frame）
import { FW, FH, TW, Mapper, to_q8 } from './bil_golden_lib.mjs';
import { geom, perspNorm, winTabOf, lo_of, base_of, STRIDE } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const CASES = (process.env.CASES || '0/0/0, 0/20/0, 0/20/20, 15/20/0, 15/20/20, 20/0/0, 25/0/0')
  .split(',').map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NT = FW / TW, SW = 256, RPB = 120;

console.log('rot tilt pitch | lo过冲max | lo低估max | 画内 colMiss (左/右)  rowMiss');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, 0, pitch);
  const T = winTabOf(g, K1Q);
  const map = new Mapper(750, 639.5, 359.5, K1Q / 16777216);
  const cmin = new Int32Array(NT * FH).fill(1 << 20), cnt = new Int32Array(NT * FH);
  const rmin = new Int32Array(NT * FH).fill(1 << 20), rmax = new Int32Array(NT * FH).fill(-(1 << 20));
  const N = FW * FH;
  const UC = new Int32Array(N), V1 = new Int32Array(N), V2 = new Int32Array(N), INF = new Uint8Array(N);
  let idx = 0;
  for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++, idx++) {
    const t = (u / TW) | 0;
    const [nx, ny] = perspNorm(g, u, v);
    const sp = map.fromNorm(nx, ny);
    const uc = to_q8(sp[0])[0], vr = Math.min(to_q8(sp[1])[0], FH - 1);
    const v2 = Math.min(vr + 1, FH - 1);
    UC[idx] = uc; V1[idx] = vr; V2[idx] = v2;
    INF[idx] = (sp[0] >= 0 && sp[0] <= (FW - 1) * 65536 && sp[1] >= 0 && sp[1] <= (FH - 1) * 65536) ? 1 : 0;
    for (const r of (vr === v2 ? [vr] : [vr, v2])) { const k = t * FH + r; if (uc < cmin[k]) cmin[k] = uc; cnt[k]++; }
    const kv = t * FH + v;
    if (vr < rmin[kv]) rmin[kv] = vr;
    if (vr > rmax[kv]) rmax[kv] = vr;
  }
  // lo 过冲 / 低估（相对 cmin-MAR，仅被采样行）
  let over = 0, under = 0;
  for (let t = 0; t < NT; t++) for (let r = 0; r < FH; r++) {
    const k = t * FH + r; if (!cnt[k]) continue;
    const e = lo_of(T, t * TW, r) - (cmin[k] - 8);
    if (e > over) over = e;
    if (e < under) under = e;
  }
  let colMiss = 0, mL = 0, mR = 0, rowMiss = 0;
  idx = 0;
  for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++, idx++) {
    if (!INF[idx]) continue;
    const t = (u / TW) | 0, x0 = t * TW, uc = UC[idx];
    const l1 = lo_of(T, x0, V1[idx]), l2 = lo_of(T, x0, V2[idx]);
    const ok = (lo) => (uc - lo >= 0 && uc + 1 - lo <= SW - 1);
    if (!(ok(l1) && (V2[idx] === V1[idx] || ok(l2)))) {
      colMiss++;
      if (uc - l1 < 0 || (V2[idx] !== V1[idx] && uc - l2 < 0)) mL++; else mR++;
    }
    const b = base_of(T, v, x0), a = V1[idx], c = V2[idx];
    if (!(a >= b && a < b + RPB && (c === a || (c >= b && c < b + RPB)))) rowMiss++;
  }
  console.log(String(rot).padStart(3) + String(tilt).padStart(5) + String(pitch).padStart(6) +
    ' | ' + String(over).padStart(8) + ' | ' + String(under).padStart(9) + ' | ' +
    String(colMiss).padStart(7) + ' (' + mL + '/' + mR + ')' + String(rowMiss).padStart(8));
}
