import { readFileSync } from 'node:fs';
const FW = 1280, FH = 720;
function load(p, hex) {
  const v = [], u = [], val = [];
  const t = readFileSync(p, 'ascii');
  for (const line of t.split(/\r?\n/)) {
    if (!line) continue;
    const a = line.split(/\s+/);
    if (a.length < 3) continue;
    v.push(+a[0]); u.push(+a[1]);
    val.push(hex ? (/^[0-9a-fA-F]+$/.test(a[2]) ? parseInt(a[2], 16) : 0) : +a[2]);
  }
  return { v: v, u: u, val: val };
}
const rp = process.argv[2] || 'rtl_dump_m3.txt';
const mp = process.argv[3] || 'bisect/model_mg24-r0.txt';
const R = load(rp, true), M = load(mp, false);
console.log('lines rtl=' + R.v.length + ' mdl=' + M.v.length);
const A = new Int32Array(FW * FH), B = new Int32Array(FW * FH);
const cnt = new Int32Array(FW * FH);
for (let i = 0; i < R.v.length; i++) { A[R.v[i] * FW + R.u[i]] = R.val[i]; cnt[R.v[i] * FW + R.u[i]]++; }
for (let i = 0; i < M.v.length; i++) B[M.v[i] * FW + M.u[i]] = M.val[i];
let neq = 0; const byT = new Array(8).fill(0);
for (let i = 0; i < FH * FW; i++) if (A[i] !== B[i]) { neq++; byT[Math.floor((i % FW) / 160)]++; }
let dup = 0; for (let i = 0; i < cnt.length; i++) if (cnt[i] > 1) dup++;
console.log('neq=' + neq + ' byTile=[' + byT.join(',') + '] dupCoords=' + dup);
