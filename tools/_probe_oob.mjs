
process.env.MG='8'; process.env.MAR='8';
const { FW, FH, Mapper, to_q8 } = await import('./bil_golden_lib.mjs');
const { geom, perspNorm } = await import('./m3_model.mjs');
const K1Q = -2248147;
const g = geom(15, 20, 0, 20);
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q/16777216.0);
let oob = 0, total = 0, oobX = 0, oobY = 0;
const rows = new Array(FH).fill(0);
for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++) {
  const [s1x,s1y] = perspNorm(g,u,v);
  const [sx,sy] = mapper.fromNorm(s1x,s1y);
  const [uc] = to_q8(sx), [vr] = to_q8(sy);
  total++;
  if (uc < 0 || uc > FW-1 || vr < 0 || vr > FH-1) { oob++; rows[v]++; if (uc<0||uc>FW-1) oobX++; if (vr<0||vr>FH-1) oobY++; }
}
console.log('越界像素 ' + oob + ' / ' + total + ' = ' + (100*oob/total).toFixed(2) + '%');
console.log('  其中 x 越界 ' + oobX + '，y 越界 ' + oobY);
const nz = rows.map((n,v)=>[v,n]).filter(x=>x[1]>0);
console.log('  涉及行数 ' + nz.length + '，首行 ' + (nz.length?nz[0][0]:'-') + '，末行 ' + (nz.length?nz[nz.length-1][0]:'-'));
// 每行最大越界宽度（左右各多少）
let maxEdge = 0;
for (let v = 0; v < FH; v++) {
  let l = 0, r = 0;
  for (let u = 0; u < FW; u++) { const [s1x,s1y]=perspNorm(g,u,v); const [sx,sy]=mapper.fromNorm(s1x,s1y); const [uc]=to_q8(sx),[vr]=to_q8(sy); if (uc<0||uc>FW-1||vr<0||vr>FH-1) { if (u < FW/2) l++; else r++; } }
  if (l > maxEdge) maxEdge = l;
  if (r > maxEdge) maxEdge = r;
}
console.log('  单边最宽越界带 ' + maxEdge + ' 像素');
