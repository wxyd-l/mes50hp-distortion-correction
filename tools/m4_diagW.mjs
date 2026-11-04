
import { FW, FH, TW, Mapper, to_q8 } from './bil_golden_lib.mjs';
import { geom, perspNorm } from './m3_model.mjs';
const K1Q = -2248147, MAR = 8, XEXT = 24, CXr = 639.5, CYr = 359.5, FXr = 750;
const k1r = K1Q / 16777216.0;
const ROLL = 0;
const mapper = new Mapper(750.0, 639.5, 359.5, k1r);
const co = (g) => ({ A00: g.a00/2**28, A01: g.a01/2**28, A02: g.a02/2**28,
  A10: g.a10/2**28, A11: g.a11/2**28, A12: g.a12/2**28,
  W0: g.w0/2**24, H20: g.h20/2**24, H21: g.h21/2**24 });
const fwd = (C,u,v) => { const W=C.W0+C.H20*u+C.H21*v;
  const xn=(C.A00*u+C.A01*v+C.A02)/W, yn=(C.A10*u+C.A11*v+C.A12)/W;
  const s=1+k1r*(xn*xn+yn*yn); return {xn,yn,s,sx:xn*s*FXr+CXr,sy:yn*s*FXr+CYr}; };
const srcCol=(C,u,r)=>{ let yn=(r-CYr)/FXr;
  let v=(yn*C.W0-C.A12-(C.A10-yn*C.H20)*u)/(C.A11-yn*C.H21);
  for(let k=0;k<3;k++){ const F=fwd(C,u,v); if(!(F.s>0.2&&F.s<5))break;
    const yt=(r-CYr)/(FXr*F.s); v=(yt*C.W0-C.A12-(C.A10-yt*C.H20)*u)/(C.A11-yt*C.H21); }
  return fwd(C,u,v).sx; };
for (const [rot,tilt,pitch] of [[0,20,0],[15,20,20]]) {
  const g = geom(rot,tilt,ROLL,pitch), C = co(g);
  const loOf=(x0,r)=>{ let e=Math.round(srcCol(C,x0,r)); let lo=e-MAR;
    if(lo<0)lo=0; lo=Math.floor(lo/16)*16; return lo>1024?1024:lo; };
  // 逐 (tile, 源行) 求真正需要的 [cmin,cmax]
  const N=8*FH, cmin=new Int32Array(N).fill(1<<30), cmax=new Int32Array(N).fill(-(1<<30));
  const px=[];
  for(let v=0;v<FH;v++) for(let u=0;u<FW;u++){
    const t=(u/TW)|0;
    const sp=mapper.fromNorm(...perspNorm(g,u,v));
    const uc=to_q8(sp[0])[0], vr=Math.min(to_q8(sp[1])[0],FH-1), v2=Math.min(vr+1,FH-1);
    for(const r of (vr===v2?[vr]:[vr,v2])){const k=t*FH+r;
      if(uc<cmin[k])cmin[k]=uc; if(uc>cmax[k])cmax[k]=uc;}
    px.push([t,uc,vr,v2]);
  }
  let dmin=1e9,dmax=-1e9,overSpan=0,worst=[];
  for(let t=0;t<8;t++) for(let r=0;r<FH;r++){const k=t*FH+r;
    if(cmax[k]<cmin[k])continue;
    const d=Math.round(srcCol(C,t*TW,r))-cmin[k];
    if(d<dmin)dmin=d; if(d>dmax)dmax=d;
    const sp=cmax[k]-cmin[k]; if(sp>254)overSpan++;
    if(d>4&&worst.length<5) worst.push([t,r,cmin[k],cmax[k],Math.round(srcCol(C,t*TW,r))]);
  }
  console.log('rot='+rot+' tilt='+tilt+' pitch='+pitch+
    '  估算-cmin: ['+dmin+','+dmax+']   span>254 的(块,行)='+overSpan);
  console.log('  样例[t,r,cmin,cmax,est]: '+worst.map(a=>'['+a.join(',')+']').join(' '));
}
