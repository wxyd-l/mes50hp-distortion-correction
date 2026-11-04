
import { FW, FH, TW, Mapper, to_q8 } from './bil_golden_lib.mjs';
import { geom, perspNorm, SW3 } from './m3_model.mjs';
const K1Q=-2248147, MAR=8, CXr=639.5, CYr=359.5, FXr=750, k1r=K1Q/16777216.0;
const mapper=new Mapper(750.0,639.5,359.5,k1r);
const co=(g)=>({A00:g.a00/2**28,A01:g.a01/2**28,A02:g.a02/2**28,A10:g.a10/2**28,A11:g.a11/2**28,A12:g.a12/2**28,W0:g.w0/2**24,H20:g.h20/2**24,H21:g.h21/2**24});
const fwd=(C,u,v)=>{const W=C.W0+C.H20*u+C.H21*v;
  const xn=(C.A00*u+C.A01*v+C.A02)/W, yn=(C.A10*u+C.A11*v+C.A12)/W;
  const s=1+k1r*(xn*xn+yn*yn); return {xn,yn,s,sx:xn*s*FXr+CXr,sy:yn*s*FXr+CYr};};
// 返回 {sx, v} ；v 必须在 [0,FH-1] 才算该点真实存在
const solve=(C,u,r)=>{let yn=(r-CYr)/FXr;
  let v=(yn*C.W0-C.A12-(C.A10-yn*C.H20)*u)/(C.A11-yn*C.H21);
  for(let k=0;k<3;k++){const F=fwd(C,u,v); if(!(F.s>0.2&&F.s<5))break;
    const yt=(r-CYr)/(FXr*F.s); v=(yt*C.W0-C.A12-(C.A10-yt*C.H20)*u)/(C.A11-yt*C.H21);}
  return {sx:fwd(C,u,v).sx, v};};
const loNew=(C,x0,r,NU)=>{
  let best=null;
  for(let i=0;i<NU;i++){
    const u=x0+Math.round(TW*i/(NU-1));
    const q=solve(C,u,r);
    if(!isFinite(q.sx)||q.v<-0.5||q.v>FH-0.5) continue;   // 该点不存在于画面
    const sx=Math.round(q.sx);
    if(best===null||sx<best)best=sx;
  }
  if(best===null) best=Math.round(solve(C,x0,r).sx);
  let lo=best-MAR; if(lo<0)lo=0; lo=Math.floor(lo/16)*16; return lo>1024?1024:lo;
};
for(const [rot,tilt,pitch] of [[0,20,0],[0,20,20],[15,20,0],[15,20,20],[20,30,20]]){
  const g=geom(rot,tilt,0,pitch), C=co(g);
  for(const NU of [2,3,5]){
    let miss=0;
    for(let v=0;v<FH;v++) for(let u=0;u<FW;u++){
      const t=(u/TW)|0, x0=t*TW;
      const sp=mapper.fromNorm(...perspNorm(g,u,v));
      const uc=to_q8(sp[0])[0], vr=Math.min(to_q8(sp[1])[0],FH-1), v2=Math.min(vr+1,FH-1);
      const inW=(lo)=>(uc-lo>=0&&uc-lo<=SW3-1&&uc+1-lo>=0&&uc+1-lo<=SW3-1);
      if(!(inW(loNew(C,x0,vr,NU))&&(v2===vr||inW(loNew(C,x0,v2,NU))))) miss++;
    }
    console.log('rot='+rot+' tilt='+tilt+' pitch='+pitch+'  NU='+NU+'  colMiss='+miss);
  }
}
