// m3_diag.mjs -- 归因 RTL vs 模型的不等像素：空间分布 + 窗口/行窗口越界检查
import { readFileSync } from 'node:fs';
import { FW, FH, TW, Mapper, to_q8, k1p_of, mixc, src_px } from './bil_golden_lib.mjs';
import { geom, lo_of, base_of, SW3, RPB3 } from './m3_model.mjs';

const MG  = Number(process.env.MG  || 56);
const K1Q = Number(process.env.K1Q || -2248147);
const ROT = Number(process.env.ROT || 0);
const rtlPath = process.argv[2] || 'rtl_dump_m3.txt';
const mdlPath = process.argv[3] || 'model_dump_m3.txt';

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
const R = load(rtlPath, true), M = load(mdlPath, false);
const g = geom(ROT), k1p = k1p_of(K1Q);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);

const byTile = new Int32Array(8), byU = new Int32Array(TW), byRow = new Int32Array(FH);
const cats = { rcol_lo: 0, rcol_hi: 0, base_out: 0, v2_out: 0, inwin: 0, noRtl: 0 };
let neq = 0;
const ex = [];
for (let v = 0; v < FH; v++) {
  for (let u = 0; u < FW; u++) {
    const i = v * FW + u;
    if (R.img[i] === M.img[i]) continue;
    neq++;
    byTile[Math.floor(u / TW)]++; byU[u % TW]++; byRow[v]++;
    if (!R.pres[i]) { cats.noRtl++; continue; }
    const x0 = Math.floor(u / TW) * TW;
    const ax = g.a00 * u + g.a01 * v + g.a02;
    const ay = g.a10 * u + g.a11 * v + g.a12;
    const sp = mapper.fromNorm(Math.floor(ax / 16), Math.floor(ay / 16));
    const ucn = to_q8(sp[0])[0], vrn = to_q8(sp[1])[0];
    const v1 = Math.min(vrn, FH - 1), v2 = Math.min(v1 + 1, FH - 1);
    const wb1 = lo_of(g, k1p, x0, v1), wb2 = lo_of(g, k1p, x0, v2);
    const base = base_of(g, k1p, v, x0);
    const r1 = ucn - wb1, r2 = ucn - wb2;
    if (r1 < 0) cats.rcol_lo++; else if (r1 > 255) cats.rcol_hi++;
    if (!(v1 >= base && v1 < base + RPB3)) cats.base_out++;
    else if (!(v2 >= base && v2 < base + RPB3)) cats.v2_out++;
    else cats.inwin++;
    if (ex.length < 12) ex.push('(v=' + v + ',u=' + u + ') rtl=' + R.img[i].toString(16).padStart(4, '0') +
      ' mdl=' + M.img[i].toString(16).padStart(4, '0') + ' uc=' + ucn + ' v1=' + v1 + ' wb1=' + wb1 +
      ' rcolE=' + r1 + ' wb2=' + wb2 + ' rcolO=' + r2 + ' base=' + base);
  }
}
console.log('=== rtl vs model !== ===');
console.log('  neq=' + neq + '  MG=' + MG + ' rot=' + ROT);
console.log('  by tile: [' + Array.from(byTile).join(', ') + ']');
const top = Array.from(byU).map(function (c, i) { return [i, c]; }).sort(function (a, b) { return b[1] - a[1]; }).slice(0, 12);
console.log('  top u%160: ' + top.map(function (x) { return x[0] + ':' + x[1]; }).join('  '));
const ru = Array.from(byRow).map(function (c, i) { return [i, c]; }).filter(function (x) { return x[1] > 0; });
console.log('  rows affected: ' + ru.length + '  first=' + (ru[0] ? ru[0][0] : -1) + ' last=' + (ru.length ? ru[ru.length - 1][0] : -1));
console.log('  top rows: ' + ru.sort(function (a, b) { return b[1] - a[1]; }).slice(0, 10).map(function (x) { return x[0] + ':' + x[1]; }).join('  '));
console.log('=== attribution ===');
console.log('  ' + JSON.stringify(cats));
console.log('=== first 12 ===');
for (const e of ex) console.log('  ' + e);
