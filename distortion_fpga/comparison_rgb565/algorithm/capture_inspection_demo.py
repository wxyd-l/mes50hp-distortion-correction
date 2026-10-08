"""Generate ARTIFICIAL chessboard frames solely to exercise capture inspection."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image,ImageDraw

from inspect_calibration import inspect
from pipeline import write_json


def demo(out):
    import cv2
    out=Path(out);frames=out/'synthetic_frames';frames.mkdir(parents=True,exist_ok=True)
    width,height=640,480;cell=32
    tile=np.zeros((7*cell,10*cell),np.uint8)
    for row in range(7):
        for col in range(10):tile[row*cell:(row+1)*cell,col*cell:(col+1)*cell]=20 if (row+col)%2==0 else 245
    for i,(x,y,angle,blur) in enumerate(((30,30,0,0),(260,180,0,0),(150,120,12,0),(130,120,-15,0),
                                       (180,80,5,3),(100,180,0,0),(200,40,0,0),(50,120,0,0))):
        image=np.full((height,width),210,np.uint8)
        image[y:y+tile.shape[0],x:x+tile.shape[1]]=tile
        transform=cv2.getRotationMatrix2D((x+tile.shape[1]/2,y+tile.shape[0]/2),angle,1)
        image=cv2.warpAffine(image,transform,(width,height),borderValue=210)
        if blur:image=cv2.GaussianBlur(image,(0,0),blur)
        image=Image.fromarray(image)
        ImageDraw.Draw(image).text((12,height-20),'SYNTHETIC / NOT CAMERA CAPTURE',fill=0)
        image.save(frames/f'board_{i:02d}.png')
    Image.new('L',(width,height),128).save(frames/'blank.png')
    result=inspect(frames,out/'inspection',board=(9,6))
    write_json(out/'provenance.json',{'synthetic_only':True,
        'purpose':'Check corner detection, coverage and unreadable/blank feedback. Do NOT fit real camera parameters from these frames.',
        'detected_frames':result['detected_frames'],'total_files':result['files']})
    print(f"Artificial frames detected {result['detected_frames']}/{result['files']}; output {out.resolve()}")
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=Path('out/capture_inspection_demo'))
    args=p.parse_args();demo(args.out)
