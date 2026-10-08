"""Ten small-frame formula fixtures: pipeline/CE/overflow/border/frame reset."""
import json
from pathlib import Path

from compare_mappers import ROOT,compare,formula_package,synthetic_pattern,rgb_to_565,Camera,Mapping,View
from run_formula_sim import simulate


def main():
    root=ROOT/'rtl/out/formula_regression'
    size=(41,25)
    k=[[32,0,20],[0,32,12],[0,0,1]]
    cases=[('identity',[0,0,0,0,0],View()),
           ('radial1',[-.2,0,0,0,0],View()),('radial2',[0,.04,0,0,0],View()),
           ('tangent1',[0,0,.002,0,0],View()),('tangent2',[0,0,0,-.002,0],View()),
           ('half_border',[0,0,0,0,0],View(shift_x=.5)),
           ('negative30',[-.2,.04,.001,-.001,0],View(angle=-30)),
           ('center45',[-.2,.04,.001,-.001,0],View(angle=45,border='crop-center',crop_safety_px=.5)),
           ('overflow',[0,0,0,0,0],View()),
           ('rotate90',[-.2,.04,.001,-.001,0],View(angle=90))]
    results=[]
    for name,d,view in cases:
        camera=Camera(size,k,d)
        destination=root/name
        if name=='overflow':
            formula_package(Mapping(camera,view),rgb_to_565(synthetic_pattern(size)),destination/'formula',True)
        else:
            compare(camera,view,destination,step=8)
        result=simulate(destination/'formula')
        results.append({'case':name,'report':result})
    (root/'summary.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print(f'Formula fixtures passed: {len(results)}')


if __name__=='__main__':main()
