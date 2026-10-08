"""Compare four rotation angles and two border policies on one fixed input.

The default input and calibration are synthetic. Results are CPU algorithm
experiments, not measured camera quality or FPGA speed.
"""
import argparse
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from geometry import View
from pipeline import save_result, write_json
from undistort import Camera


def roi_metrics(metadata, canvas_size):
    _, _, width, height = metadata['valid_roi_on_base_canvas']
    cw, ch = canvas_size
    retained = (width-1)*(height-1)/((cw-1)*(ch-1))
    sx = (cw-1)/(width-1)
    sy = (ch-1)/(height-1)
    return {
        'retained_base_canvas_area_fraction': float(retained),
        'output_to_roi_zoom_x': float(sx), 'output_to_roi_zoom_y': float(sy),
        'roi_area_definition': 'continuous pixel-center area on rotated base canvas; NOT original scene FOV',
    }


def font(size):
    for candidate in ('C:/Windows/Fonts/msyh.ttc','C:/Windows/Fonts/arial.ttf'):
        if Path(candidate).is_file():
            return ImageFont.truetype(candidate,size)
    return ImageFont.load_default(size=size)


def comparison_panel(images, rows, destination, size):
    thumb_w=512;thumb_h=round(size[1]*thumb_w/size[0])
    band=68;top=56;cell_h=thumb_h+band
    angles=sorted({row['angle_degrees'] for row in rows})
    panel=Image.new('RGB',(2*thumb_w,top+len(angles)*cell_h),(245,246,248))
    draw=ImageDraw.Draw(panel)
    draw.text((16,12),'人工旋转实验   同一输入与镜头参数   左保留画布  右裁剪再缩放',font=font(21),fill=(20,30,40))
    for row,array in zip(rows,images):
        column=0 if row['border']=='keep' else 1
        x=column*thumb_w;y=top+angles.index(row['angle_degrees'])*cell_h
        mode='保留画布' if row['border']=='keep' else '裁剪再缩放'
        label=f"{row['angle_degrees']:g}°  {mode}  无效 {100*row['invalid_fraction']:.2f}%"
        draw.text((x+12,y+6),label,font=font(19),fill=(20,30,40))
        label=f"画布保留 {100*row['retained_base_canvas_area_fraction']:.1f}%   放大 {row['output_to_roi_zoom_x']:.2f} 倍"
        draw.text((x+12,y+34),label,font=font(17),fill=(70,80,90))
        thumbnail=Image.fromarray(array).resize((thumb_w,thumb_h),Image.Resampling.LANCZOS)
        panel.paste(thumbnail,(x,y+band))
    panel.save(destination)


def before_after_panel(source, corrected, destination):
    width=640;height=round(source.shape[0]*width/source.shape[1])
    panel=Image.new('RGB',(width*2,height+52),(245,246,248))
    draw=ImageDraw.Draw(panel)
    for i,(array,title) in enumerate(((source,'输入 人工镜头畸变'),(corrected,'输出 去畸变且旋转角度为零'))):
        draw.text((i*width+12,12),title,font=font(22),fill=(20,30,40))
        panel.paste(Image.fromarray(array).resize((width,height),Image.Resampling.LANCZOS),(i*width,52))
    panel.save(destination)


def run(camera_path, input_path, output_dir, angles=(0,10,20,30), step=32, frac_bits=8):
    if not angles or any(not np.isfinite(angle) for angle in angles) or len(set(angles))!=len(angles):
        raise ValueError('angles must be nonempty, distinct and finite')
    camera=Camera.load(camera_path)
    with Image.open(input_path) as image:
        if image.size!=camera.size:
            raise ValueError('input size must match calibration; no implicit resizing')
        source=np.asarray(image.convert('RGB'))
    output_dir=Path(output_dir)
    if output_dir.resolve() in (input_path.parent.resolve(),camera_path.parent.resolve()):
        raise ValueError('experiment output must have its own directory')
    output_dir.mkdir(parents=True,exist_ok=True)
    rows=[];images=[]
    for angle in sorted(angles):
        for border in ('keep','crop-resize'):
            view=View(angle=angle,border=border)
            name=f'angle{angle:g}_{border.replace("-","_")}'
            corrected,report=save_result(source,camera,view,output_dir/name,step=step,frac_bits=frac_bits)
            write_json(output_dir/name/'view.json',asdict(view))
            row={
                'angle_degrees':angle,'border':border,'directory':name,
                'output_size':report['mapping']['output_size'],
                'valid_fraction':report['valid_fraction'],'invalid_fraction':1-report['valid_fraction'],
                'invalid_pixels':int(round((1-report['valid_fraction'])*corrected.shape[0]*corrected.shape[1])),
                'base_valid_fraction':report['mapping']['base_valid_fraction'],
                'roi_on_rotated_base_canvas':report['mapping']['valid_roi_on_base_canvas'],
                **roi_metrics(report['mapping'],camera.size),
                'lut_bytes_per_bank':report['lut']['memory_bytes'],
                'float_grid_vs_exact_mapping_max_coordinate_error_px':report['lut']['max_coordinate_error_px'],
                'float_grid_vs_exact_mapping_p99_coordinate_error_px':report['lut']['p99_coordinate_error_px'],
                'float_grid_validity_disagreements':report['lut']['validity_disagreements'],
            }
            # Validate the exact mapping separately from LUT approximation.
            if tuple(row['output_size'])!=camera.size:
                raise AssertionError('keep/crop-resize must preserve the output dimensions')
            if border=='crop-resize' and row['invalid_pixels']!=0:
                raise AssertionError('exact crop-resize mapping is not all valid')
            rows.append(row);images.append(corrected)
    summary={
        'created_at_utc':datetime.now(timezone.utc).isoformat(),
        'camera':str(camera_path.resolve()),'input':str(input_path.resolve()),
        'source_sha256':hashlib.sha256(input_path.read_bytes()).hexdigest(),
        'camera_sha256':hashlib.sha256(camera_path.read_bytes()).hexdigest(),
        'input_size':list(camera.size),'angles_degrees':sorted(angles),
        'fixed_settings':{'roll':0,'pitch':0,'yaw':0,'scale':1,'shift_x':0,'shift_y':0,
                          'enhancement':'none','grid_step':step,'coordinate_fraction_bits':frac_bits},
        'cases':rows,
        'scope':'Default data is synthetic. Mask measures coordinate validity, not image black-color count. '
                'ROI area is rotated-canvas area, not recovered scene FOV. LUT error is a coordinate metric, '
                'not measured image quality. CPU runtime and LUT bytes do not establish FPGA fps or BRAM usage.',
    }
    write_json(output_dir/'summary.json',summary)
    comparison_panel(images,rows,output_dir/'comparison.png',camera.size)
    if 0 in angles:
        baseline=next(i for i,row in enumerate(rows) if row['angle_degrees']==0 and row['border']=='keep')
        before_after_panel(source,images[baseline],output_dir/'input_vs_corrected.png')
    return summary


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--camera',type=Path,default=Path('examples/camera_demo.json'))
    parser.add_argument('--input',type=Path,default=Path('out/complete_demo/input_synthetic.png'))
    parser.add_argument('--out',type=Path,default=Path('out/rotation_experiment'))
    parser.add_argument('--angles',type=float,nargs='+',default=[0,10,20,30])
    parser.add_argument('--step',type=int,default=32)
    parser.add_argument('--frac-bits',type=int,default=8)
    args=parser.parse_args()
    summary=run(args.camera,args.input,args.out,args.angles,args.step,args.frac_bits)
    print(json.dumps({'out':str(args.out.resolve()),'cases':summary['cases']},ensure_ascii=False,indent=2))
