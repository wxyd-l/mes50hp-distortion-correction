"""Compare legacy, centered and fixed-over-poses crops, preserving old outputs."""
import argparse
from dataclasses import asdict
from pathlib import Path
from datetime import datetime,timezone
import hashlib

import numpy as np
from PIL import Image,ImageDraw

from geometry import View,plan_fixed_crop
from pipeline import save_result,write_json,apply_crop_plan,process_video
from rotation_experiment import font,roi_metrics
from undistort import Camera


def make_panel(rows,images,size,path,safety):
    modes=('keep','crop-resize','crop-center','crop-fixed')
    labels=('保留画布','原裁剪策略','保持中心裁剪','视频固定裁剪')
    angles=sorted({row['angle'] for row in rows})
    width=400;height=round(size[1]*width/size[0]);band=88;top=48
    panel=Image.new('RGB',(4*width,top+len(angles)*(height+band)),(245,246,248))
    draw=ImageDraw.Draw(panel)
    draw.text((12,10),f'人工裁剪实验  固定内参  裁剪安全边距 {safety:g} 源像素  不代表实测视场',font=font(22),fill=(25,35,45))
    for row,image in zip(rows,images):
        col=modes.index(row['mode']);x=col*width;y=top+angles.index(row['angle'])*(height+band)
        draw.text((x+10,y+4),f"{row['angle']:g}° {labels[col]}",font=font(20),fill=(25,35,45))
        draw.text((x+10,y+33),f"放大 {row['output_to_roi_zoom_x']:.2f}倍  画布保留 {row['retained_base_canvas_area_fraction']*100:.1f}%",font=font(17),fill=(65,75,85))
        draw.text((x+10,y+58),f"黑边 {row['invalid_pixels']}像素  中心偏移 {row['center_offset_px']:.1f}px",font=font(17),fill=(65,75,85))
        panel.paste(Image.fromarray(image).resize((width,height),Image.Resampling.LANCZOS),(x,y+band))
    panel.save(path)


def run(camera_path,input_path,out,angles=(0,10,20,30),plan_angles=(-30,-20,-10,0,10,20,30),safety=.5):
    if not angles or any(not np.isfinite(v) for v in angles) or len(set(angles))!=len(angles):
        raise ValueError('angles must be nonempty, distinct and finite')
    camera=Camera.load(camera_path)
    with Image.open(input_path) as opened:
        if opened.size!=camera.size:raise ValueError('input size differs from calibration')
        image=np.asarray(opened.convert('RGB'))
    out=Path(out)
    if out.resolve() in (camera_path.parent.resolve(),input_path.parent.resolve()):
        raise ValueError('experiment output must be a separate directory')
    out.mkdir(parents=True,exist_ok=True)
    plan=plan_fixed_crop(camera,[View(angle=a) for a in plan_angles],safety)
    write_json(out/'crop_plan.json',plan)
    fixed_views=apply_crop_plan(camera,[(i,View(angle=a)) for i,a in enumerate(sorted(angles))],plan)
    rows=[];images=[]
    cx,cy=(camera.size[0]-1)/2,(camera.size[1]-1)/2
    for (index,fixed),angle in zip(fixed_views,sorted(angles)):
        views=[View(angle=angle),View(angle=angle,border='crop-resize',crop_safety_px=safety),
               View(angle=angle,border='crop-center',crop_safety_px=safety),fixed]
        for view in views:
            folder=out/f'angle{angle:g}_{view.border.replace("-","_")}'
            result,report=save_result(image,camera,view,folder)
            write_json(folder/'view.json',asdict(view))
            roi=report['mapping']['valid_roi_on_base_canvas']
            center=[roi[0]+(roi[2]-1)/2,roi[1]+(roi[3]-1)/2]
            count=int(round((1-report['valid_fraction'])*result.shape[0]*result.shape[1]))
            if view.border!='keep' and count:raise AssertionError('cropped output must be entirely valid')
            rows.append({'angle':angle,'mode':view.border,'directory':folder.name,
                         'roi':roi,'roi_center':center,'center_offset_px':float(np.hypot(center[0]-cx,center[1]-cy)),
                         'invalid_pixels':count,**roi_metrics(report['mapping'],camera.size),
                         'lut_max_coordinate_error_px':report['lut']['max_coordinate_error_px'],
                         'lut_validity_disagreements':report['lut']['validity_disagreements']})
            images.append(result)
    summary={'created_at_utc':datetime.now(timezone.utc).isoformat(),
             'input_size':list(camera.size),'camera':str(camera_path.resolve()),'input':str(input_path.resolve()),
             'camera_sha256':hashlib.sha256(camera_path.read_bytes()).hexdigest(),
             'input_sha256':hashlib.sha256(input_path.read_bytes()).hexdigest(),
             'angles':sorted(angles),'crop_safety_px':safety,'plan':plan,'cases':rows,
             'scope':'Synthetic default. ROI area is rotated-canvas area, NOT original FOV. Fixed ROI '
                     'removes crop translation/zoom changes, NOT all scene motion or image warping. '
                     'Only listed transforms tested; each new command must be validated.'}
    write_json(out/'summary.json',summary)
    make_panel(rows,images,camera.size,out/'comparison.png',safety)
    commands=[{'frame':i*10,'view':{'angle':angle}} for i,angle in enumerate(sorted(angles))]
    write_json(out/'video_commands.json',commands)
    return summary


def make_video(camera_path,input_path,out,summary):
    """Offline constant-input replay to isolate changing command/crop effects."""
    import cv2
    camera=Camera.load(camera_path)
    if any(v%2 for v in camera.size):raise ValueError('MJPG demonstration needs even frame dimensions')
    with Image.open(input_path) as opened:
        rgb=np.asarray(opened.convert('RGB'))
    source=out/'input_synthetic.avi'
    writer=cv2.VideoWriter(str(source),cv2.VideoWriter_fourcc(*'MJPG'),30,camera.size)
    if not writer.isOpened():raise ValueError('MJPG encoder unavailable')
    try:
        for _ in range(len(summary['angles'])*10):writer.write(cv2.cvtColor(rgb,cv2.COLOR_RGB2BGR))
    finally:writer.release()
    commands=[(i*10,View(angle=angle)) for i,angle in enumerate(summary['angles'])]
    from dataclasses import replace
    reports={}
    for mode in ('crop-resize','crop-center','crop-fixed'):
        converted=apply_crop_plan(camera,commands,summary['plan']) if mode=='crop-fixed' else [
            (frame,replace(view,border=mode,crop_safety_px=summary['crop_safety_px'])) for frame,view in commands]
        report=process_video(source,camera,converted,out/f'video_{mode.replace("-","_")}')
        if report['frames']!=len(summary['angles'])*10:raise AssertionError('video frame count changed')
        reports[mode]=report
    write_json(out/'video_summary.json',{'modes':reports,
        'scope':'Constant synthetic input, offline replay with lossy MJPG. 30 fps is playback metadata, not processing fps or measured sensor rate.'})


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--camera',type=Path,default=Path('examples/camera_demo.json'))
    parser.add_argument('--input',type=Path,default=Path('out/complete_demo/input_synthetic.png'))
    parser.add_argument('--out',type=Path,default=Path('out/crop_experiment'))
    parser.add_argument('--angles',type=float,nargs='+',default=[0,10,20,30])
    parser.add_argument('--plan-angles',type=float,nargs='+',default=[-30,-20,-10,0,10,20,30])
    parser.add_argument('--safety-px',type=float,default=.5)
    parser.add_argument('--video',action='store_true',help='also render an offline MJPG command replay in three modes')
    args=parser.parse_args()
    summary=run(args.camera,args.input,args.out,args.angles,args.plan_angles,args.safety_px)
    if args.video:make_video(args.camera,args.input,args.out,summary)
    for row in summary['cases']:
        print(f"{row['angle']:5g} {row['mode']:12} invalid={row['invalid_pixels']:7d} "
              f"zoom={row['output_to_roi_zoom_x']:.4f} area={row['retained_base_canvas_area_fraction']:.4f} "
              f"center_offset={row['center_offset_px']:.4f}px")
    print(f"Output: {args.out.resolve()}")
