// tile_bil_model.mjs -- Node 版逐位黄金模型（等价移植自 tools/tile_bil_model.py）
// 用法: node tools/tile_bil_model.mjs [--k1q N] [--out model_dump.txt]
import { writeFileSync } from 'node:fs';
import {
  FW, FH, TW, SW, RPB, LATCG, NT, SWM8, VWD, RLEN,
  Mapper, to_q8, mixc, k1p_of, base_t_of, xs_of, src_px,
} from './bil_golden_lib.mjs';

export function runModel(k1q, nt, tileXs) {
  const k1r = k1q / 16777216.0;
  const k1p = k1p_of(k1q);
  const mapper = new Mapper(750.0, 639.5, 359.5, k1r);

  const out = new Int32Array(FH * FW);
  const ntok = TW + 24;                 // TW + XEXT

  // RTL 从不清零 vmem/amem, 跨条保持 -> 必须跨条保留才能逐位一致
  const vmem = new Int32Array(SW);
  const amem = new Int32Array(VWD);

  const uc = new Int32Array(ntok), wxA = new Int32Array(ntok);
  const wyA = new Int32Array(ntok);
  const rval = new Uint8Array(ntok), vval = new Int32Array(ntok), rcol = new Int32Array(ntok);

  for (let row = 0; row < FH; row++) {
    for (let ti = 0; ti < nt; ti++) {
      const x0 = ti * TW;
      const base = base_t_of(row, x0, k1p);
      const win_x = tileXs[ti];

      for (let n = 0; n < ntok; n++) {
        const [sx, sy] = mapper.src(x0 + n, row);
        const [ucn, wxn] = to_q8(sx);
        const [vrn, wyn] = to_q8(sy);
        const v1 = Math.min(vrn, FH - 1);
        const v2 = Math.min(v1 + 1, FH - 1);
        let rc = ucn - win_x;
        if (rc < 0) rc = 0; else if (rc > SWM8) rc = SWM8;
        const ok = (v1 >= base) && (v1 < base + RPB);
        const rb_ok = (v2 >= base) && (v2 < base + RPB);
        const colAbs = win_x + rc;
        const ra = src_px(v1, colAbs);
        const rb = src_px(v2, colAbs);
        const rbE = rb_ok ? rb : ra;
        const rR = mixc((ra >> 11) & 31, (rbE >> 11) & 31, wyn) & 0x1F;
        const rG = mixc((ra >> 5) & 63, (rbE >> 5) & 63, wyn);
        const rB = mixc(ra & 31, rbE & 31, wyn) & 0x1F;
        vval[n] = ((rR << 11) | (rG << 5) | rB) & 0xFFFF;
        rcol[n] = rc; uc[n] = ucn; wxA[n] = wxn;
        rval[n] = ok ? 1 : 0;
      }

      // ---- 逐拍事件模拟 (只做存储簿记) ----
      let hA_has = false, hA_u2 = 0, hA_uc = 0, hA_wx = 0;
      const lim = RLEN + 20 + 8;        // RLEN + LAG + 8
      for (let c = 0; c < lim; c++) {
        const m = c - 14;               // token m 的写, 在 cycle m+14 对读可见
        if (m >= 0 && m < ntok && rval[m]) {
          vmem[rcol[m]] = vval[m];
          amem[m] = (rcol[m] << 8) | wxA[m];
        }
        if (hA_has) {
          const v0 = vmem[hA_uc];
          const v1v = vmem[hA_uc >= SWM8 ? SWM8 : hA_uc + 1];
          const pr = mixc((v0 >> 11) & 31, (v1v >> 11) & 31, hA_wx) & 0x1F;
          const pg = mixc((v0 >> 5) & 63, (v1v >> 5) & 63, hA_wx) & 0x3F;
          const pb = mixc(v0 & 31, v1v & 31, hA_wx) & 0x1F;
          out[row * FW + x0 + hA_u2] = ((pr << 11) | (pg << 5) | pb) & 0xFFFF;
        }
        const u1 = c - 20;              // LAG
        if (u1 >= 0 && u1 < TW) {
          const a = amem[u1];
          hA_has = true; hA_u2 = u1; hA_uc = a >> 8; hA_wx = a & 0xFF;
        } else { hA_has = false; }
      }
    }
    if (row % 120 === 0) console.log('  row ' + row + '/' + FH);
  }
  return out;
}

export function tilesXs(k1q) {
  const k1p = k1p_of(k1q);
  const xs = [];
  for (let t = 0; t < NT; t++) xs.push(xs_of(t * TW, k1p));
  return xs;
}

const isMain = process.argv[1] && process.argv[1].replace(/\\/g, '/').endsWith('tile_bil_model.mjs');
if (isMain) {
  const argv = process.argv.slice(2);
  const argOf = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
  const k1q = Number(argOf('--k1q', -2248147));
  const outPath = argOf('--out', 'model_dump.txt');
  const k1p = k1p_of(k1q);
  const xs = tilesXs(k1q);
  console.log('K1Q=' + k1q + ' K1P=' + k1p + ' xs=[' + xs.join(', ') + ']');
  const t0 = Date.now();
  const out = runModel(k1q, NT, xs);
  const buf = [];
  for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++) buf.push(v + ' ' + u + ' ' + out[v * FW + u]);
  writeFileSync(outPath, buf.join('\n') + '\n', 'ascii');
  console.log('wrote ' + outPath + ' (' + buf.length + ' pixels, ' + ((Date.now() - t0) / 1000).toFixed(1) + ' s)');
}
