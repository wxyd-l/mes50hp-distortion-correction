// m4_win2.mjs -- 方案1 的目标值：窗口估计器要做到多准，缺口才能清零
//
// 列窗口 wbase[r] 是按【源行 r】索引的（RTL 里 wbase[rowE]），所以按源行分箱；
// 行窗口 base 是按【输出行】定的，所以按输出行分箱。
// 比较四种 lo(r)：当前 lo_of() / 精确 cmin(r) / 每分块最小二乘直线 / 每分块二次
import { FW, FH, TW, Mapper, to_q8, k1p_of } from './bil_golden_lib.mjs';
import { geom, perspNorm, lo_of, SW3, RPB3 } from './m3_model.mjs';

const K1Q = Number(process.env.K1Q || -2248147);
const MG  = Number(process.env.MG  || 56);
const ROLL= Number(process.env.ROLL|| 0);
const MAR = Number(process.env.MAR || 8);        // 新估计器的 MARGIN 候选
const mapper = new Mapper(750.0, 639.5, 359.5, K1Q / 16777216.0);
const k1p = k1p_of(K1Q);
const CASES = (process.env.CASES || '0/20/0, 0/20/20, 15/20/0, 15/20/20').split(',')
  .map(x => x.trim()).filter(Boolean).map(x => x.split('/').map(Number));
const NT = FW / TW;
const sdiv = (a, b) => Math.floor(a / b);

function base_of(g, row, x0) {   // 复刻 m3_model.base_of
  const vaff = sdiv(g.VX * x0 + g.VX * 80 + g.VV * row + g.V0, 65536);
  const va = vaff < 0 ? 0 : (vaff > FH - 1 ? FH - 1 : vaff);
  const b2 = 2 * va - 719;
  const au2c = 2 * x0 + TW - 1279;
  const a2c = sdiv(au2c * au2c, 4);
  const r2 = a2c + sdiv(b2 * b2, 4);
  const dvc = sdiv(k1p * r2 * b2, 33554432);
  const vcs = sdiv(b2 + 2 * dvc + 719, 2);
  const bsel = vcs - MG - 2;
  if (bsel < 0) return 0;
  if (bsel > FH - RPB3) return FH - RPB3;
  return bsel;
}

console.log('rot tilt pitch |  span  | 当前lo  精确lo  直线lo  二次lo  |  当前base  精确base');
for (const [rot, tilt, pitch] of CASES) {
  const g = geom(rot, tilt, ROLL, pitch);
  const N = NT * FH;
  const cmin = new Int32Array(N).fill(1 << 30), cmax = new Int32Array(N).fill(-(1 << 30)); // 源行
  const rmin = new Int32Array(N).fill(1 << 30), rmax = new Int32Array(N).fill(-(1 << 30)); // 输出行
  const px = [];
  for (let v = 0; v < FH; v++) {
    for (let u = 0; u < FW; u++) {
      const t = (u / TW) | 0;
      const [s1x, s1y] = perspNorm(g, u, v);
      const sp = mapper.fromNorm(s1x, s1y);
      const uc = to_q8(sp[0])[0];
      const vr = Math.min(to_q8(sp[1])[0], FH - 1);
      const v2 = Math.min(vr + 1, FH - 1);
      for (const r of (vr === v2 ? [vr] : [vr, v2])) {           // 两个采样行各自入箱
        const kr = t * FH + r;
        if (uc < cmin[kr]) cmin[kr] = uc;
        if (uc > cmax[kr]) cmax[kr] = uc;
      }
      const kv = t * FH + v;
      if (vr < rmin[kv]) rmin[kv] = vr;
      if (vr > rmax[kv]) rmax[kv] = vr;
      px.push([t, v, uc, vr, v2]);
    }
  }
  let spanMax = 0;
  for (let i = 0; i < N; i++) if (cmax[i] >= cmin[i]) spanMax = Math.max(spanMax, cmax[i] - cmin[i]);
  // 每分块：对 (r -> cmin(r)) 做一次直线 / 二次最小二乘
  const LA = new Float64Array(NT), LB = new Float64Array(NT);
  const QA = new Float64Array(NT), QB = new Float64Array(NT), QC = new Float64Array(NT);
  for (let t = 0; t < NT; t++) {
    const R = [], C = [];
    for (let r = 0; r < FH; r++) { const k = t * FH + r; if (cmax[k] >= cmin[k]) { R.push(r); C.push(cmin[k]); } }
    const n = R.length;
    // 直线
    let sx=0, sy=0, sxx=0, sxy=0;
    for (let i=0;i<n;i++){ sx+=R[i]; sy+=C[i]; sxx+=R[i]*R[i]; sxy+=R[i]*C[i]; }
    const den = n*sxx - sx*sx;
    LB[t] = den ? (n*sxy - sx*sy)/den : 0; LA[t] = (sy - LB[t]*sx)/n;
    // 二次：正规方程 3x3（用 r/719 归一化避免病态）
    let m0=n,m1=0,m2=0,m3=0,m4=0,y0=0,y1=0,y2=0;
    for (let i=0;i<n;i++){ const x=R[i]/719, y=C[i]; m1+=x; m2+=x*x; m3+=x*x*x; m4+=x*x*x*x; y0+=y; y1+=y*x; y2+=y*x*x; }
    // 解 [m0 m1 m2; m1 m2 m3; m2 m3 m4] * [a b c] = [y0 y1 y2]
    const M=[[m0,m1,m2],[m1,m2,m3],[m2,m3,m4]], V=[y0,y1,y2];
    for (let i=0;i<3;i++){ let p=i; for(let j=i+1;j<3;j++) if(Math.abs(M[j][i])>Math.abs(M[p][i])) p=j;
      [M[i],M[p]]=[M[p],M[i]]; [V[i],V[p]]=[V[p],V[i]];
      for(let j=i+1;j<3;j++){ const f=M[j][i]/M[i][i]; for(let k2=i;k2<3;k2++) M[j][k2]-=f*M[i][k2]; V[j]-=f*V[i]; } }
    const sol=[0,0,0]; for(let i=2;i>=0;i--){ let s=V[i]; for(let j=i+1;j<3;j++) s-=M[i][j]*sol[j]; sol[i]=s/M[i][i]; }
    QA[t]=sol[0]; QB[t]=sol[1]; QC[t]=sol[2];
  }
  let colCur=0, colExa=0, colLin=0, colQad=0, rowCur=0, rowExa=0;
  for (const [t, v, uc, vr, v2] of px) {
    const lo_cur1 = lo_of(g, k1p, t*TW, vr), lo_cur2 = lo_of(g, k1p, t*TW, v2);
    const kr1 = t*FH+vr, kr2 = t*FH+v2;
    const lo_ex1 = cmin[kr1], lo_ex2 = cmin[kr2];
    const lo_ln1 = Math.max(0, Math.round(LA[t]+LB[t]*vr)), lo_ln2 = Math.max(0, Math.round(LA[t]+LB[t]*v2));
    const lo_qd1 = Math.max(0, Math.round(QA[t]+QB[t]*(vr/719)+QC[t]*(vr/719)*(vr/719)));
    const lo_qd2 = Math.max(0, Math.round(QA[t]+QB[t]*(v2/719)+QC[t]*(v2/719)*(v2/719)));
    const inWin = (lo, r) => (uc-lo>=0 && uc-lo<=SW3-1 && uc+1-lo>=0 && uc+1-lo<=SW3-1);
    if (!(inWin(lo_cur1, vr) && inWin(lo_cur2, v2))) colCur++;
    if (!(inWin(lo_ex1-MAR, vr) && inWin(lo_ex2-MAR, v2))) colExa++;
    if (!(inWin(lo_ln1-MAR, vr) && inWin(lo_ln2-MAR, v2))) colLin++;
    if (!(inWin(lo_qd1-MAR, vr) && (v2===vr || inWin(lo_qd2-MAR, v2)))) colQad++;
    const kv = t*FH+v;
    const bCur = base_of(g, v, t*TW);
    const bExa = Math.max(0, Math.min(rmin[kv]-2, FH-RPB3));
    if (!(vr>=bCur && vr<bCur+RPB3 && v2>=bCur && v2<bCur+RPB3)) rowCur++;
    if (!(vr>=bExa && vr<bExa+RPB3 && v2>=bExa && v2<bExa+RPB3)) rowExa++;
  }
  console.log(String(rot).padStart(3)+String(tilt).padStart(5)+String(pitch).padStart(6)+' |'+
    String(spanMax).padStart(6)+'  |'+String(colCur).padStart(8)+String(colExa).padStart(8)+
    String(colLin).padStart(8)+String(colQad).padStart(8)+'  |'+
    String(rowCur).padStart(10)+String(rowExa).padStart(10));
}
