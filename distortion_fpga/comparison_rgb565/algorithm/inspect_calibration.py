"""Read-only chessboard capture audit; NO camera parameters are fitted here.

Counts, coverage and blur indicators support acquisition feedback, not formal
calibration acceptance, SFR measurement or automatic rejection of real frames.
"""
import argparse
from datetime import datetime,timezone
import hashlib
from pathlib import Path

import numpy as np

from calibrate import parse_board
from pipeline import write_json


def inspect(images,out,board=(9,6),pattern='*.png',min_laplacian_variance=None):
    import cv2
    images,out=Path(images),Path(out)
    if len(board)!=2 or any(type(v) is not int or v<2 for v in board):raise ValueError('board specifies INNER corner counts >=2')
    if min_laplacian_variance is not None and (not np.isfinite(min_laplacian_variance) or min_laplacian_variance<0):
        raise ValueError('blur warning threshold must be finite and nonnegative')
    if out.resolve()==images.resolve() or images.resolve() in out.resolve().parents:
        raise ValueError('inspection output must be outside the original image directory')
    files=sorted(images.glob(pattern))
    if not files:raise ValueError('no matching image files')
    rows=[];all_points=[];overlays=[];size=None
    occupancy=np.zeros((4,4),int)
    for index,path in enumerate(files):
        if not path.is_file():continue
        gray=cv2.imdecode(np.fromfile(path,dtype=np.uint8),cv2.IMREAD_GRAYSCALE)
        row={'file':str(path.resolve()),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'readable':gray is not None}
        if gray is None:
            row.update(detected=False,warnings=['unreadable_image']);rows.append(row);continue
        current=(gray.shape[1],gray.shape[0])
        if size is None:size=current
        if current!=size:raise ValueError('mixed image sizes; use ONE camera mode per inspection/calibration')
        found,corners=cv2.findChessboardCornersSB(gray,board)
        variance=float(cv2.Laplacian(gray,cv2.CV_64F).var())
        row.update(image_size=list(current),detected=bool(found),laplacian_variance=variance,
                   mean_gray_code=float(gray.mean()),warnings=[])
        if min_laplacian_variance is not None and variance<min_laplacian_variance:
            row['warnings'].append('below_user_blur_indicator_threshold')
        overlay=cv2.cvtColor(gray,cv2.COLOR_GRAY2BGR)
        if found:
            points=corners.reshape(-1,2).astype(float)
            normalized=points/np.array([current[0]-1,current[1]-1])
            bins=np.clip((normalized*4).astype(int),0,3)
            for bx,by in set(map(tuple,bins)):occupancy[by,bx]+=1
            hull=cv2.convexHull(points.astype(np.float32))
            first_row_delta=points[board[0]-1]-points[0]
            row.update(inner_corner_count=len(points),centroid_normalized=normalized.mean(axis=0).tolist(),
                corner_bounds_normalized=[*normalized.min(axis=0).tolist(),*normalized.max(axis=0).tolist()],
                corner_hull_image_area_fraction=float(cv2.contourArea(hull)/(current[0]*current[1])),
                first_row_angle_deg=float(np.rad2deg(np.arctan2(first_row_delta[1],first_row_delta[0]))),
                corners_xy=points.tolist())
            cv2.drawChessboardCorners(overlay,board,corners.astype(np.float32).reshape(-1,1,2),True)
            all_points.append(normalized)
        else:row['warnings'].append('inner_corners_not_detected')
        label=f'{index}: corners={int(found)}  LapVar={variance:.1f}'
        cv2.putText(overlay,label,(12,24),cv2.FONT_HERSHEY_SIMPLEX,.55,(0,0,255),1,cv2.LINE_AA)
        filename=f'{index:03d}_{path.stem}_corners.png';row['overlay']=filename
        overlays.append((filename,overlay));rows.append(row)
    detected=[row for row in rows if row['detected']]
    warnings=[]
    if len(detected)<8:warnings.append('current_calibration_tool_requires_at_least_8_detected_frames')
    if len(detected)<15:warnings.append('fewer_than_15_detected_frames_for_varied_capture_review')
    if len(detected)!=len(rows):warnings.append('some_frames_unreadable_or_without_detected_corners')
    points=np.concatenate(all_points) if all_points else np.empty((0,2))
    bounds=[*points.min(axis=0).tolist(),*points.max(axis=0).tolist()] if points.size else None
    if bounds and (bounds[0]>.2 or bounds[1]>.2 or bounds[2]<.8 or bounds[3]<.8):
        warnings.append('observed_corners_do_not_reach_outer_20_percent_on_at_least_one_side')
    centroids=np.array([row['centroid_normalized'] for row in detected])
    result={'schema':'chessboard_capture_inspection_v1','created_at_utc':datetime.now(timezone.utc).isoformat(),
        'images':str(images.resolve()),'pattern':pattern,'board_inner_corners':list(board),
        'image_size':list(size) if size else None,'files':len(rows),'detected_frames':len(detected),
        'corner_bounds_normalized':bounds,'centroid_spread_normalized':np.ptp(centroids,axis=0).tolist() if len(centroids) else None,
        'grid_4x4_frames_with_corners':occupancy.tolist(),'warnings':warnings,
        'user_min_laplacian_variance':min_laplacian_variance,'frames':rows,
        'scope':'Detection audit ONLY, not calibrated K/distortion, physical pose diversity, lens quality or formal acceptance. '
                '4x4 cells count distinct frames containing detected corners, not counts of corners. '
                'Laplacian variance depends on resolution, exposure, noise and target scale; no default blur rejection. '
                '15 views and outer-20-percent coverage are acquisition review hints, not competition thresholds. '
                'Do not silently discard frames based on this report; review overlays and camera mode.'}
    out.mkdir(parents=True,exist_ok=True)
    for filename,overlay in overlays:
        ok,encoded=cv2.imencode('.png',overlay)
        if not ok:raise ValueError('overlay encoding failed')
        encoded.tofile(out/filename)
    write_json(out/'inspection.json',result)
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--images',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--board',type=parse_board,default=(9,6));p.add_argument('--pattern',default='*.png')
    p.add_argument('--min-laplacian-variance',type=float)
    args=p.parse_args();result=inspect(args.images,args.out,args.board,args.pattern,args.min_laplacian_variance)
    print(f"Detected {result['detected_frames']}/{result['files']} frames; this is NOT camera calibration.")
    print(f"Report: {args.out.resolve()/'inspection.json'}")
