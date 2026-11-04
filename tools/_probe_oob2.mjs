
process.env.MG='8'; process.env.MAR='8';
const { FW, FH, Mapper, to_q8 } = await import('./bil_golden_lib.mjs');
const { geom, perspNorm } = await import('./m3_model.mjs');
const K1Q = -2248147;
const cases = [['板级配置 0/0/0（只有 k1）', geom(0,0,0,0)], ['15/20/20', geom(15,20,0,20)], ['25/0/0 纯旋转', geom(25,0,0,0)]];
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q/16777216.0);
for (const [name, g] of cases) {
  let oob = 0;
  for (let v = 0; v < FH; v++) for (let u = 0; u < FW; u++) {
    const [s1x,s1y] = perspNorm(g,u,v);
    const [sx,sy] = mapper.fromNorm(s1x,s1y);
    const [uc] = to_q8(sx), [vr] = to_q8(sy);
    if (uc < 0 || uc > FW-1 || vr < 0 || vr > FH-1) oob++;
  }
  console.log(name.padEnd(28) + ' 越界 ' + String(oob).padStart(6) + ' / 921600 = ' + (100*oob/921600).toFixed(2) + '%');
}
