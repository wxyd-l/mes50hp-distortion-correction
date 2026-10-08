"""Compare an explicitly formatted captured frame against a checksummed package.

Diagnostic transformations are suggestions only: NEVER silently repair a dump.
An exact match checks this frame, not camera calibration or real-time throughput.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from prepare_package import read_grid,rgb_to_565,rgb_from_565


def read_memh(path,count,digits=4):
    lines=Path(path).read_text(encoding='ascii').splitlines()
    if len(lines)!=count or any(len(line)!=digits or any(c not in '0123456789abcdefABCDEF' for c in line) for line in lines):
        raise ValueError(f'expected exactly {count} lines of {digits} hexadecimal digits')
    return np.array([int(line,16) for line in lines],np.uint16)


def swap_red_blue(pixels):
    return ((pixels & np.uint16(0x07e0)) | ((pixels & 31)<<11) | ((pixels>>11)&31)).astype(np.uint16)


def load_actual(path,size,format,pixel_order=None,byte_order=None,stride_bytes=None):
    path=Path(path);width,height=size
    if format not in ('memh','raw565','png'):raise ValueError('format must be memh, raw565 or png')
    if format=='png':
        if pixel_order is not None or byte_order is not None or stride_bytes is not None:
            raise ValueError('PNG is decoded RGB8; packed-pixel options do not apply')
        with Image.open(path) as image:
            if image.size!=tuple(size):raise ValueError('actual image dimensions differ from expected output')
            if image.format!='PNG':raise ValueError('PNG mode requires a lossless PNG file')
            if image.mode not in ('RGB','RGBA'):
                raise ValueError('PNG must be RGB/RGBA, not palette/grayscale conversion')
            if image.mode=='RGBA' and np.any(np.asarray(image)[...,3]!=255):
                raise ValueError('transparent PNG cannot represent captured pixels unambiguously')
            return rgb_to_565(np.asarray(image.convert('RGB')))
    if pixel_order not in ('rgb565','bgr565'):raise ValueError('explicit pixel_order rgb565/bgr565 is required')
    if format=='memh':
        if byte_order is not None or stride_bytes is not None:raise ValueError('memh has packed words, not raw byte stride')
        pixels=read_memh(path,width*height).reshape(height,width)
    else:
        if byte_order not in ('little','big'):raise ValueError('raw565 requires explicit little/big byte_order')
        stride=width*2 if stride_bytes is None else stride_bytes
        if type(stride) is not int or stride<width*2 or stride%2:
            raise ValueError('stride_bytes must be even and >= width*2')
        raw=path.read_bytes()
        if len(raw) not in ((height-1)*stride+width*2,height*stride):
            raise ValueError('raw frame length differs from declared resolution/stride; extra frames are not ignored')
        dtype=np.dtype('<u2' if byte_order=='little' else '>u2')
        pixels=np.stack([np.frombuffer(raw,dtype=dtype,count=width,offset=y*stride) for y in range(height)]).astype(np.uint16)
    return swap_red_blue(pixels) if pixel_order=='bgr565' else pixels


def compare_pixels(expected,actual,valid):
    expected,actual,valid=np.asarray(expected),np.asarray(actual),np.asarray(valid)
    if expected.dtype!=np.uint16 or actual.dtype!=np.uint16 or expected.shape!=actual.shape or expected.ndim!=2 or valid.shape!=expected.shape:
        raise ValueError('need matching 2-D uint16 frames and a valid mask')
    valid=valid.astype(bool);mismatch=actual!=expected;height,width=expected.shape
    count=int(mismatch.sum());yy,xx=np.where(mismatch)
    channels={}
    for name,shift,mask in (('R5',11,31),('G6',5,63),('B5',0,31)):
        delta=((actual>>shift)&mask).astype(np.int16)-((expected>>shift)&mask).astype(np.int16)
        channels[name]={'mean_absolute_error_codes':float(np.abs(delta).mean()),
                        'max_absolute_error_codes':int(np.abs(delta).max()),
                        'mismatched_pixels':int(np.count_nonzero(delta))}
    variants={'swap_red_blue':swap_red_blue(actual),
              'swap_word_bytes':((actual>>8)|((actual&255)<<8)).astype(np.uint16),
              'horizontal_flip':actual[:,::-1],'vertical_flip':actual[::-1,:],'rotate_180':actual[::-1,::-1]}
    diagnostic=[]
    for name,candidate in variants.items():
        differences=int(np.count_nonzero(candidate!=expected))
        if differences<count:
            diagnostic.append({'hypothesis':name,'mismatched_pixels_if_applied':differences,
                               'exact_match_if_applied':differences==0})
    diagnostic.sort(key=lambda row:row['mismatched_pixels_if_applied'])
    first=[{'address':int(y*width+x),'x':int(x),'y':int(y),
            'expected':f'{int(expected[y,x]):04x}','actual':f'{int(actual[y,x]):04x}',
            'expected_sample_valid':bool(valid[y,x])} for y,x in zip(yy[:20],xx[:20])]
    return {'exact_match':count==0,'total_pixels':int(expected.size),'mismatched_pixels':count,
            'mismatch_fraction':count/int(expected.size),
            'valid_region_mismatched_pixels':int(np.count_nonzero(mismatch & valid)),
            'invalid_region_nonblack_pixels':int(np.count_nonzero((actual!=0)&~valid)),
            'mismatch_bounding_box_xywh':[int(xx.min()),int(yy.min()),int(xx.max()-xx.min()+1),int(yy.max()-yy.min()+1)] if count else None,
            'channels':channels,'first_mismatches':first,'diagnostic_hypotheses':diagnostic,
            'diagnostic_warning':'Hypotheses are alternatives, not automatic corrections or confirmed causes.'}


def compare_package(package,actual_path,out,format,pixel_order=None,byte_order=None,stride_bytes=None):
    package,actual_path,out=Path(package),Path(actual_path),Path(out)
    report=json.loads((package/'package.json').read_text(encoding='utf-8'))
    if report.get('schema')!='rtl_test_package_v1':raise ValueError('unsupported test package')
    required={'grid.memh','grid.json','source_rgb565.memh','expected_rgb565.memh','expected_valid.memh','rtl_parameters.vh'}
    if set(report['sha256'])!=required:raise ValueError('incomplete package checksum manifest')
    for name,digest in report['sha256'].items():
        if hashlib.sha256((package/name).read_bytes()).hexdigest()!=digest:raise ValueError(f'package checksum failed for {name}')
    metadata,_=read_grid(package);size=metadata['output_size'];width,height=size
    if report['parameters'].get('OUT_WIDTH')!=width or report['parameters'].get('OUT_HEIGHT')!=height:
        raise ValueError('package output parameters differ from grid')
    outputs=('actual_rgb565.png','expected_rgb565.png','difference_x8.png','mismatch_mask.png','comparison.json')
    if out.resolve()==package.resolve() or package.resolve() in out.resolve().parents:
        raise ValueError('diagnostic output must not modify the reference package')
    if actual_path.resolve() in {(out/name).resolve() for name in outputs}:
        raise ValueError('diagnostic output would overwrite the captured input')
    expected=read_memh(package/'expected_rgb565.memh',width*height).reshape(height,width)
    valid=read_memh(package/'expected_valid.memh',width*height,1).reshape(height,width)
    if not np.isin(valid,[0,1]).all():raise ValueError('valid mask contains non-binary values')
    actual=load_actual(actual_path,size,format,pixel_order,byte_order,stride_bytes)
    result=compare_pixels(expected,actual,valid)
    result.update(schema='captured_frame_comparison_v1',created_at_utc=datetime.now(timezone.utc).isoformat(),
        package=str(package.resolve()),actual_file=str(actual_path.resolve()),actual_sha256=hashlib.sha256(actual_path.read_bytes()).hexdigest(),
        expected_sha256=report['sha256']['expected_rgb565.memh'],
        decoding={'format':format,'pixel_order':pixel_order,'byte_order':byte_order,'stride_bytes':stride_bytes},
        scope='Checks the captured OUTPUT frame against this exact LUT/source/rounding configuration. '
              'PNG is high-bit re-quantized, not a physical bus capture. Provenance is unverified; '
              'matching one frame does not validate lens quality, camera FPS, DDR timing or all frames.')
    out.mkdir(parents=True,exist_ok=True)
    actual_rgb,expected_rgb=rgb_from_565(actual),rgb_from_565(expected)
    Image.fromarray(actual_rgb).save(out/'actual_rgb565.png')
    Image.fromarray(expected_rgb).save(out/'expected_rgb565.png')
    delta=np.abs(actual_rgb.astype(np.int16)-expected_rgb.astype(np.int16))
    Image.fromarray(np.clip(delta*8,0,255).astype(np.uint8)).save(out/'difference_x8.png')
    Image.fromarray((actual!=expected).astype(np.uint8)*255).save(out/'mismatch_mask.png')
    (out/'comparison.json').write_text(json.dumps(result,indent=2,allow_nan=False),encoding='utf-8')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package',type=Path,required=True);p.add_argument('--actual',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--format',choices=('memh','raw565','png'),required=True)
    p.add_argument('--pixel-order',choices=('rgb565','bgr565'));p.add_argument('--byte-order',choices=('little','big'))
    p.add_argument('--stride-bytes',type=int);p.add_argument('--allow-mismatch',action='store_true')
    args=p.parse_args()
    result=compare_package(args.package,args.actual,args.out,args.format,args.pixel_order,args.byte_order,args.stride_bytes)
    print(f"Exact match: {result['exact_match']}; mismatched pixels: {result['mismatched_pixels']}/{result['total_pixels']}")
    print(f"Report: {args.out.resolve()/'comparison.json'}")
    raise SystemExit(0 if result['exact_match'] or args.allow_mismatch else 2)
