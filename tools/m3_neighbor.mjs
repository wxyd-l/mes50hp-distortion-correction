// m3_neighbor.mjs -- 验证"水平混合用的是别的 token 的竖向样本"这一假设
import { readFileSync } from 'node:fs';
import { FW, FH, TW, Mapper, to_q8, mixc, src_px } from './bil_golden_lib.mjs';
import { geom, lo_of, base_of, RPB3 } from './m3_model.mjs';
const K1Q = Number(process.env.K1Q || -2248147);
const ROT = Number(process.env.ROT || 20);
const k1r = K1Q / 16777216.0;
const chR = (p) => (p >> 11) & 31, chG = (p) => (p >> 5) & 63, chB = (p) => p & 31;
function load(path, hex) {
  const img = new Int32Array(FW * FH);
  const txt = readFileSync(path, 'ascii');
  for (const line of txt.split(/\r?\n/)) { if (!line) continue; const a = line.split(/\s+/); if (a.length < 3) continue;
    img[+a[0] * FW + +a[1]] = hex ? parseInt(a[2], 16) : +a[2]; }
  return img;
}
const R = load('bisect/rtl_mg56-r' + ROT + '.txt', true);
const M2 = load('bisect/model_mg56-r' + ROT + '.txt', false);
const mapper = new Mapper(750.0, 639.5, 359.5, k1r);
const g = geom(ROT);
const k1p = (function (k) { const F = 562500; return k >= 0 ? Math.floor((k + F / 2) / F) : -Math.floor(((-k) + F / 2) / F); })(K1Q);

function tokenOf(u, v) {
  const ax = g.a00 * u + g.a01 * v + g.a02, ay = g.a10 * u + g.a11 * v + g.a12;
  const sp = mapper.fromNorm(Math.floor(ax / 16), Math.floor(ay / 16));
  const q = to_q8(sp[0]), r = to_q8(sp[1]);
  const v1 = Math.min(r[0], FH - 1);
  return { uc: q[0], wx: q[1], v1: v1, wy: r[1], x0: Math.floor(u / TW) * TW, u: u, v: v };
}
function vert(t, uc) {
  const v2 = Math.min(t.v1 + 1, FH - 1);
  const wb1 = lo_of(g, k1p, t.x0, t.v1), wb2 = lo_of(g, k1p, t.x0, v2);
  const base = base_of(g, k1p, t.v, t.x0);
  const rc1 = Math.max(0, Math.min(255, uc - wb1)), rc2 = Math.max(0, Math.min(255, uc - wb2));
  const ra = src_px(t.v1, wb1 + rc1), rb = src_px(v2, wb2 + rc2);
  const rb_ok = (v2 !== t.v1) && (v2 >= base) && (v2 < base + RPB3);
  const rbE = rb_ok ? rb : ra;
  return ((mixc((ra >> 11) & 31, (rbE >> 11) & 31, t.wy) & 0x1F) << 11) |
         ((mixc((ra >> 5) & 63, (rbE >> 5) & 63, t.wy) & 0x3F) << 5) |
         (mixc(ra & 31, rbE & 31, t.wy) & 0x1F);
}
function hblend(a, b, w) {
  return ((mixc((a >> 11) & 31, (b >> 11) & 31, w) & 0x1F) << 11) |
         ((mixc((a >> 5) & 63, (b >> 5) & 63, w) & 0x3F) << 5) |
         (mixc(a & 31, b & 31, w) & 0x1F);
}
// 收集 diff 大的 in-frame 像素
const cand = [];
for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++) {
  const rv = R[v * FW + u], mv = M2[v * FW + u];
  if (rv !== mv) continue;
  const t = tokenOf(u, v);
  const corr = hblend(vert(t, t.uc), vert(t, t.uc + 1), t.wx);      // 正确：同一 v1/wy
  const d = Math.max(Math.abs(chR(rv) - chR(corr)), Math.abs(chG(rv) - chG(corr)), Math.abs(chB(rv) - chB(corr)));
  if (d > 10) cand.push({ t: t, corr: corr, rv: rv, d: d });
}
console.log('in-frame pixels where RTL(!=correct) diff>10: ' + cand.length + ' / 921600');
let hitNeighbor = 0;
for (const c of cand.slice(0, 200)) {
  let best = null, bestD = 1e9;
  for (let du = -6; du <= 6; du++) {
    if (du === 0) continue;
    const t2 = tokenOf(c.t.u + du, c.t.v);
    if (t2.uc !== c.t.uc + 1) continue;
    const val = hblend(vert(c.t, c.t.uc), vert(t2, t2.uc), c.t.wx);
    const d = Math.abs(val - c.rv);
    if (d < bestD) { bestD = d; best = t2; }
  }
  if (bestD === 0) hitNeighbor++;
}
console.log('of first 200: neighbor-token hypothesis reproduces RTL exactly: ' + hitNeighbor);
for (const c of cand.slice(0, 4)) {
  const t2 = tokenOf(c.t.u + 1, c.t.v);
  console.log(' (v=' + c.t.v + ',u=' + c.t.u + ') rtl=' + c.rv.toString(16) + ' correct=' + c.corr.toString(16) +
    ' | this token v1=' + c.t.v1 + ' wy=' + c.t.wy + ' | neighbor u+1 v1=' + t2.v1 + ' wy=' + t2.wy + ' uc=' + t2.uc);
}
