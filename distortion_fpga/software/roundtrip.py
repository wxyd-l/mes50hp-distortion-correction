"""Synthetic ideal -> simulated lens -> fixed correction, never calibration."""
from pathlib import Path
import cv2
import numpy as np
from .reference import bilinear_fixed, fixed_map, synthetic_config


def generate_roundtrip(destination, width=512, height=384):
    if width < 128 or height < 96:
        raise ValueError("roundtrip requires width>=128, height>=96")
    dst = Path(destination)
    dst.mkdir(parents=True,exist_ok=True)
    config = synthetic_config(width,height)
    config["camera_matrix"] = [[width*.65,0,(width-1)/2],[0,width*.65,(height-1)/2],[0,0,1]]
    config["distortion"] = [-.30,.10,.004,-.003]
    ideal = np.full((height,width,3),238,dtype=np.uint8)
    spacing = max(16,width//12)
    for x in range(spacing//2,width,spacing):
        cv2.line(ideal,(x,0),(x,height-1),(40,60,100),2,cv2.LINE_AA)
    for y in range(spacing//2,height,spacing):
        cv2.line(ideal,(0,y),(width-1,y),(40,60,100),2,cv2.LINE_AA)
    for x,y,color in ((width//4,height//4,(220,70,50)),(3*width//4,height//4,(40,150,70)),
                      (width//4,3*height//4,(50,100,230)),(3*width//4,3*height//4,(170,70,180))):
        cv2.circle(ideal,(x,y),max(8,width//35),color,-1,cv2.LINE_AA)
    cv2.rectangle(ideal,(spacing//2,spacing//2),(width-spacing//2,height-spacing//2),(230,120,30),2)
    k = np.asarray(config["camera_matrix"],dtype=np.float64)
    d = np.r_[config["distortion"],0.0]
    u,v = np.meshgrid(np.arange(width,dtype=np.float64),np.arange(height,dtype=np.float64))
    sensor_pixels = np.stack([u,v],axis=-1).reshape(-1,1,2)
    # For each distorted sensor pixel, solve the ideal pixel to sample.
    # This is the inverse of the corrector's ideal-to-sensor mapping.
    normalized = cv2.undistortPointsIter(sensor_pixels,k,d,None,None,
        (cv2.TERM_CRITERIA_COUNT|cv2.TERM_CRITERIA_EPS,80,1e-10)).reshape(-1,2)
    inverse = normalized.reshape(height,width,2)*[k[0,0],k[1,1]]+[k[0,2],k[1,2]]
    distorted = cv2.remap(ideal,inverse[:,:,0].astype(np.float32),inverse[:,:,1].astype(np.float32),
                          cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=(20,20,20))
    qx,qy = fixed_map(config)
    reconstructed = bilinear_fixed(distorted,qx,qy)
    # Independently reproject solver output to check its numerical residual.
    obj = np.column_stack([normalized,np.ones(len(normalized))])
    projected,_ = cv2.projectPoints(obj,np.zeros(3),np.zeros(3),k,d)
    residual = np.abs(projected.reshape(height,width,2)-np.stack([u,v],axis=-1))
    valid = (qx>=65536)&(qy>=65536)&(qx<(width-2)*65536)&(qy<(height-2)*65536)
    error = reconstructed.astype(float)-ideal.astype(float)
    canvas = np.full((height+138,width*3,3),(247,248,250),dtype=np.uint8)
    canvas[86:86+height] = np.concatenate([ideal,distorted,reconstructed],axis=1)
    cv2.putText(canvas,"SYNTHETIC ROUNDTRIP - no real camera / no hardware measurement",(15,29),
                cv2.FONT_HERSHEY_SIMPLEX,.65,(30,40,55),2,cv2.LINE_AA)
    for i,label in enumerate(("1  IDEAL GRID","2  DISTORTED INPUT (inverse solver)","3  FIXED RECONSTRUCTION")):
        cv2.putText(canvas,label,(i*width+15,67),cv2.FONT_HERSHEY_SIMPLEX,.55,(30,40,55),1,cv2.LINE_AA)
    cv2.putText(canvas,"Simulated lens: k1=-0.30, k2=0.10, p1=0.004, p2=-0.003. Two resamplings soften grid edges.",
                (15,height+111),cv2.FONT_HERSHEY_SIMPLEX,.51,(45,55,65),1,cv2.LINE_AA)
    for name,pixels in (("SYNTHETIC_ROUNDTRIP.png",canvas),("synthetic_ideal.png",ideal),
                        ("synthetic_distorted_input.png",distorted),("synthetic_fixed_reconstruction.png",reconstructed)):
        if not cv2.imwrite(str(dst/name),cv2.cvtColor(pixels,cv2.COLOR_RGB2BGR)):
            raise OSError(f"Could not write {dst/name}")
    report = {"provenance":{"kind":"synthetic","warning":"Not real camera calibration or hardware result"},
              "generation":"Each distorted sensor pixel uses OpenCV undistortPointsIter to find its ideal source coordinate before remap.",
              "correction":"Independent fixed coordinate model and 8-bit-fraction bilinear interpolation.",
              "inverse_solver_max_reprojection_residual_pixels":float(residual.max()),
              "reconstruction_valid_fraction":float(valid.mean()),
              "uncorrected_valid_rgb_rmse":float(np.sqrt(np.mean((distorted.astype(float)-ideal.astype(float))[valid]**2))),
              "reconstruction_valid_rgb_rmse":float(np.sqrt(np.mean(error[valid]**2))),
              "reconstruction_note":"Two resamplings soften edges. This demonstrates mapping direction, not real optical MTF or calibration accuracy."}
    return config,report,canvas
