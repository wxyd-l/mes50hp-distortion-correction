
// 每个 (tile, 输出行) 的竖向跨度 -> 行窗口 RPB 至少要多少
import { FW, FH, TW, Mapper, to_q8 } from './bil_golden_lib.mjs';
import { geom, perspNorm } from './m3_model.mjs';
const K1Q = -2248147;
const CASES = (process.env.CASES || '0/0/0,15/0/0,20/0/0,25/0/0,0/20/0,0/20/20,15/20/0,15/20/20,20/20/20,20/30/20')
  .split(',').map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NT = FW / TW, map = new Mapper(750, 639.5, 359.5, K1Q / 16777216);
console.log('rot tilt pitch | 最大竖向跨度 | 需要的 RPB');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, 0, pitch);
  const rmin = new Int32Array(NT * FH).fill(1 << 20), rmax = new Int32Array(NT * FH).fill(-(1 << 20));
  for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++) {
    const t = (u / TW) | 0;
    const [nx, ny] = perspNorm(g, u, v);
    const sp = map.fromNorm(nx, ny);
    const vr = Math.min(to_q8(sp[1])[0], FH - 1);
    const kv = t * FH + v;
    if (vr < rmin[kv]) rmin[kv] = vr;
    if (vr > rmax[kv]) rmax[kv] = vr;
  }
  let mx = 0;
  for (let i = 0; i < NT * FH; i++) if (rmax[i] >= rmin[i]) mx = Math.max(mx, rmax[i] - rmin[i] + 1);
  console.log(String(rot).padStart(3) + String(tilt).padStart(5) + String(pitch).padStart(6) + ' | ' + String(mx).padStart(12) + ' | ' + String(mx + 2).padStart(10));
}
