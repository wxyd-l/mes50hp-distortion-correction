// m3_forensic.mjs -- 对不等像素做"扰动假设"测试：RTL 到底用了什么
import { readFileSync } from 'node:fs';
import { FW, FH, TW, Mapper, to_q8, k1p_of, mixc, src_px } from './bil_golden_lib.mjs';
import { geom, lo_of, base_of, SW3, RPB3 } from './m3_model.mjs';

const MG  = Number(process.env.MG  || 56);
const K1Q = Number(process.env.K1Q || -2248147);
const ROT = Number(process.env.ROT || 15);
const LIMIT = Number(process.env.LIMIT || 40);

function load(path, hex) {
  const img = new Int32Array(FW * FH), pres = new Uint8Array(FW * FH);
  const txt = readFileSync(path, 'ascii');
  for (const line of txt.split(/\r?\n/)) {
    if (!line) continue;
    const a = line.split(/\s+/);
    if (a.length < 3) continue;
    const v = +a[0], u = +a[1];
    img[v * FW + u] = hex ? parseInt(a[2], 16) : +a[2];
    pres[v * FW + u] = 1;
  }
  return { img: img, pres: pres };
}
const R = load(process.argv[2], true), M = load(process.argv[3], false);
const g = geom(ROT), k1p = k1p_of(K1Q);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);

// 复刻像素合成：给定 (uc, v1, wx, wy, base) 求输出
function verticalAt(uc, v1, wy, base) {
  const v2 = Math.min(v1 + 1, FH - 1);
  const wb1 = lo_of(g, k1p, Math.floor(uc / TW) * TW, v1);   // 用该像素所属 tile
  const wb2 = lo_of(g, k1p, Math.floor(uc / TW) * TW, v2);
  const rc1 = Math.max(0, Math.min(255, uc - wb1));
  const rc2 = Math.max(0, Math.min(255, uc - wb2));
  const ra = src_px(v1, wb1 + rc1);
  const rb = src_px(v2, wb2 + rc2);
  const rb_ok = (v2 >= base) && (v2 < base + RPB3);
  const rbE = rb_ok ? rb : ra;
  return ((mixc((ra >> 11) & 31, (rbE >> 11) & 31, wy) & 0x1F) << 11) |
         ((mixc((ra >> 5) & 63, (rbE >> 5) & 63, wy) & 0x3F) << 5) |
         ((mixc(ra & 31, rbE & 31, wy)) & 0x1F);
}
function pixAt(uc, v1, wx, wy, base) {
  const a = verticalAt(uc, v1, wy, base);
  const b = verticalAt(uc + 1, v1, wy, base);
  return ((mixc((a >> 11) & 31, (b >> 11) & 31, wx) & 0x1F) << 11) |
         ((mixc((a >> 5) & 63, (b >> 5) & 63, wx) & 0x3F) << 5) |
         (mixc(a & 31, b & 31, wx) & 0x1F);
}

const H = {
  'base(model)':      0, 'v1-1': 0, 'v1+1': 0, 'uc-1': 0, 'uc+1': 0,
  'wx-1': 0, 'wx+1': 0, 'wy-1': 0, 'wy+1': 0, 'wx&wy+1': 0
};
let tested = 0, none = 0;
const rows = [];
for (let v = 0; v < FH && tested < LIMIT; v++) {
  for (let u = 0; u < FW && tested < LIMIT; u++) {
    const i = v * FW + u;
    if (R.img[i] === M.img[i]) continue;
    tested++;
    const x0 = Math.floor(u / TW) * TW;
    const ax = g.a00 * u + g.a01 * v + g.a02;
    const ay = g.a10 * u + g.a11 * v + g.a12;
    const sp = mapper.fromNorm(Math.floor(ax / 16), Math.floor(ay / 16));
    const q = to_q8(sp[0]), r = to_q8(sp[1]);
    const uc = q[0], wx = q[1], vrn = r[0], wy = r[1];
    const v1 = Math.min(vrn, FH - 1);
    const base = base_of(g, k1p, v, x0);
    const t = R.img[i];
    const cand = [
      ['base(model)', pixAt(uc, v1, wx, wy, base)],
      ['v1-1',   pixAt(uc, v1 - 1, wx, wy, base)],
      ['v1+1',   pixAt(uc, v1 + 1, wx, wy, base)],
      ['uc-1',   pixAt(uc - 1, v1, wx, wy, base)],
      ['uc+1',   pixAt(uc + 1, v1, wx, wy, base)],
      ['wx-1',   pixAt(uc, v1, (wx + 255) & 0xFF, wy, base)],
      ['wx+1',   pixAt(uc, v1, (wx + 1) & 0xFF, wy, base)],
      ['wy-1',   pixAt(uc, v1, wx, (wy + 255) & 0xFF, base)],
      ['wy+1',   pixAt(uc, v1, wx, (wy + 1) & 0xFF, base)],
    ];
    let hit = null;
    for (const c of cand) if (c[1] === t) { hit = c[0]; break; }
    if (hit) H[hit] = (H[hit] || 0) + 1; else none++;
    if (rows.length < 10) {
      rows.push('(v=' + v + ',u=' + u + ') rtl=' + t.toString(16) + ' mdl=' + M.img[i].toString(16) +
        ' uc=' + uc + ' wx=' + wx + ' v1=' + v1 + ' wy=' + wy + ' base=' + base + ' -> ' + (hit || 'NONE'));
    }
  }
}
console.log('tested=' + tested + '  hits: ' + JSON.stringify(H) + '  none=' + none);
for (const r of rows) console.log('  ' + r);
