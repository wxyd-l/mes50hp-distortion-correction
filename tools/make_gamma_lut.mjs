// make_gamma_lut.mjs -- 生成 7 档自适应 Gamma 表（RGB565 三通道分别建表）
// 用法: node tools/make_gamma_lut.mjs [outdir]
import { writeFileSync } from 'node:fs';

const GAMMA = [0.45, 0.60, 0.80, 1.00, 1.25, 1.60, 2.00];
const OUT = process.argv[2] || '.';

function bank(maxv, g) {
  const a = [];
  for (let i = 0; i <= maxv; i++) {
    const v = Math.round(maxv * Math.pow(i / maxv, g));
    a.push(Math.min(maxv, Math.max(0, v)) * (255 / maxv));
  }
  return a.map(v => Math.round(v));
}

const hex = (a) => a.map(v => v.toString(16).padStart(2, '0')).join('\n') + '\n';

const R = [], G = [], B = [];
for (const g of GAMMA) {
  R.push(...bank(31, g));
  G.push(...bank(63, g));
  B.push(...bank(31, g));
}

writeFileSync(OUT + '/gamma_r.hex', hex(R), 'ascii');
writeFileSync(OUT + '/gamma_g.hex', hex(G), 'ascii');
writeFileSync(OUT + '/gamma_b.hex', hex(B), 'ascii');
console.log('gamma_r.hex ' + R.length + ' / gamma_g.hex ' + G.length + ' / gamma_b.hex ' + B.length);
// 恒等校验：bank3(γ=1) 必须逐位回原值
let ok = true;
for (let i = 0; i <= 31; i++) if (Math.round(R[3*32 + i]) !== Math.round(i * (255 / 31))) ok = false;
for (let i = 0; i <= 63; i++) if (Math.round(G[3*64 + i]) !== Math.round(i * (255 / 63))) ok = false;
console.log('bank3 identity: ' + (ok ? 'OK' : 'MISMATCH'));
