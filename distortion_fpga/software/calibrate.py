"""Real-image chessboard calibration with k3 fixed to zero and held-out views."""
from __future__ import annotations

import hashlib
from pathlib import Path

import cv2
import numpy as np


def calibrate_images(paths, columns, rows, square_size, holdout_every=5):
    if columns < 2 or rows < 2 or square_size <= 0:
        raise ValueError("use inner-corner columns/rows >= 2 and positive square size")
    if holdout_every < 2:
        raise ValueError("holdout_every must be at least 2")
    paths = sorted(set(Path(p).resolve() for p in paths))
    obj = np.zeros((columns*rows,3),np.float32)
    obj[:,:2] = np.mgrid[0:columns,0:rows].T.reshape(-1,2)*square_size
    accepted,rejected,size = [],[],None
    for path in paths:
        gray = cv2.imread(str(path),cv2.IMREAD_GRAYSCALE)
        if gray is None:
            rejected.append({"path":str(path),"reason":"unreadable image"})
            continue
        current = gray.shape[1::-1]
        if size is not None and current != size:
            raise ValueError("mixed image resolutions; calibrate each sensor mode separately")
        found,corners = cv2.findChessboardCornersSB(gray,(columns,rows),flags=cv2.CALIB_CB_NORMALIZE_IMAGE)
        if not found:
            rejected.append({"path":str(path),"reason":"chessboard not detected"})
            continue
        size = current
        accepted.append((path,corners.astype(np.float32)))
    train = [v for i,v in enumerate(accepted) if i % holdout_every != 0]
    held = [v for i,v in enumerate(accepted) if i % holdout_every == 0]
    if len(train) < 8 or len(held) < 2:
        raise ValueError(f"need >=8 training and >=2 held-out detections; got {len(train)}/{len(held)}")
    rms,k,d,rv,tv = cv2.calibrateCamera([obj]*len(train),[c for _,c in train],size,None,
                                      np.zeros((5,1)),flags=cv2.CALIB_FIX_K3)
    if abs(d.ravel()[4]) > 1e-12:
        raise RuntimeError("unexpected nonzero k3")
    def record(path,corners,rvec,tvec,split):
        reproj,_ = cv2.projectPoints(obj,rvec,tvec,k,d)
        error = float(np.sqrt(np.mean(np.sum((reproj-corners)**2,axis=2))))
        return {"path":str(path),"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),
                "split":split,"reprojection_rms_pixels":error}
    records = [record(path,corners,r,t,"train") for (path,corners),r,t in zip(train,rv,tv)]
    for path,corners in held:
        ok,r,t = cv2.solvePnP(obj,corners,k,d)
        if not ok:
            raise ValueError(f"held-out pose estimation failed: {path}")
        records.append(record(path,corners,r,t,"held_out_intrinsics"))
    points = np.concatenate([c.reshape(-1,2) for _,c in accepted])
    bins = np.histogram2d(points[:,0],points[:,1],bins=(8,6),range=((0,size[0]),(0,size[1])))[0]
    return {"schema_version":1,"image_size":list(size),"camera_matrix":k.tolist(),
            "distortion":d.ravel()[:4].tolist(),
            "provenance":{"kind":"camera_images","method":"OpenCV calibrateCamera, CALIB_FIX_K3", "opencv_version":cv2.__version__,
                "board_inner_corners":[columns,rows],"square_size":square_size,"square_size_unit":"user supplied",
                "note":"Input photographs are user supplied; capture authenticity has not been independently verified."},
            "validation":{"training_rms_pixels":float(rms),"training_views":len(train),"held_out_views":len(held),
                "held_out_note":"Intrinsics are held fixed; each held-out board pose is estimated from its detected corners.",
                "corner_coverage_8x6_fraction":float(np.count_nonzero(bins)/bins.size),
                "views":records,"rejected":rejected,
                "warning":"Low reprojection error alone does not establish accuracy; inspect edge coverage and separate straight-line test images."}}
