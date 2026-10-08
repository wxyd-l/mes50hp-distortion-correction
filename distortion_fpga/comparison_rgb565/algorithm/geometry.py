"""One-pass lens + rotation/affine map and conservative valid-view cropping."""
from dataclasses import asdict, dataclass, replace
import hashlib
import json

import numpy as np

from undistort import checked_size, destination_to_source, valid_coordinates


@dataclass(frozen=True)
class View:
    # R maps source-camera rays to rectified rays: Rz(roll) @ Ry(yaw) @ Rx(pitch).
    roll: float = 0.0
    pitch: float = 0.0
    yaw: float = 0.0
    angle: float = 0.0  # Additional 2-D clockwise image rotation in degrees.
    scale: float = 1.0
    shift_x: float = 0.0
    shift_y: float = 0.0
    border: str = "keep"  # keep / crop / crop-resize / crop-center / crop-fixed
    crop_safety_px: float = 0.0  # Only applies to cropping, in SOURCE pixels.
    fixed_roi: tuple | None = None  # [x,y,width,height] on rotated base canvas.

    def __post_init__(self):
        numbers = [self.roll, self.pitch, self.yaw, self.angle, self.scale, self.shift_x, self.shift_y]
        if not np.isfinite(numbers).all() or self.scale <= 0:
            raise ValueError("view numbers must be finite and scale must be positive")
        if self.border not in ("keep", "crop", "crop-resize", "crop-center", "crop-fixed"):
            raise ValueError("unsupported border policy")
        if not np.isfinite(self.crop_safety_px) or self.crop_safety_px < 0:
            raise ValueError("crop_safety_px must be finite and nonnegative")
        if self.border == "crop-fixed":
            if (not isinstance(self.fixed_roi,(tuple,list,np.ndarray)) or len(self.fixed_roi) != 4
                    or not np.isfinite(self.fixed_roi).all()):
                raise ValueError("crop-fixed requires a finite [x,y,width,height] fixed_roi")
            roi = tuple(float(value) for value in self.fixed_roi)
            if min(roi[:2]) < 0 or min(roi[2:]) < 2:
                raise ValueError("fixed_roi needs nonnegative origin and width/height >= 2")
            object.__setattr__(self, 'fixed_roi', roi)
        elif self.fixed_roi is not None:
            raise ValueError("fixed_roi is only supported with crop-fixed")


def rotation_matrix(roll=0, pitch=0, yaw=0):
    if not np.isfinite([roll, pitch, yaw]).all():
        raise ValueError("angles must be finite")
    r, p, y = np.deg2rad([roll, pitch, yaw])
    cr, sr, cp, sp, cy, sy = np.cos(r), np.sin(r), np.cos(p), np.sin(p), np.cos(y), np.sin(y)
    rx = np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rz = np.array([[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    return rz @ ry @ rx


def affine_matrix(size, angle=0, scale=1, shift_x=0, shift_y=0):
    width, height = checked_size(size)
    if not np.isfinite([angle, scale, shift_x, shift_y]).all() or scale <= 0:
        raise ValueError("invalid affine settings")
    a = np.deg2rad(angle)
    linear = scale * np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
    center = np.array([(width - 1) / 2, (height - 1) / 2])
    result = np.eye(3)
    result[:2, :2] = linear
    result[:2, 2] = center - linear @ center + [shift_x, shift_y]
    return result


def largest_valid_rectangle(mask):
    """Largest axis-aligned all-True pixel rectangle, [x,y,width,height]."""
    mask = np.asarray(mask, dtype=bool)
    if mask.ndim != 2 or not mask.size:
        raise ValueError("mask must be a nonempty 2-D array")
    height, width = mask.shape
    if mask.all():
        return (0, 0, width, height)
    histogram = np.zeros(width, dtype=np.int64)
    best, area = None, 0
    for y, row in enumerate(mask):
        histogram = np.where(row, histogram + 1, 0)
        stack = []
        for x, value in enumerate([*histogram.tolist(), 0]):
            start = x
            while stack and stack[-1][1] > value:
                left, h = stack.pop()
                candidate = h * (x - left)
                if candidate > area and h >= 2 and x - left >= 2:
                    best, area = (left, y - h + 1, x - left, h), candidate
                start = left
            if value and (not stack or stack[-1][1] < value):
                stack.append((start, value))
    if best is None or best[2] < 2 or best[3] < 2:
        raise ValueError("no usable valid rectangle; reduce angle or select a different view")
    return best


def aspect_roi(roi, output_size):
    """Inscribed same-aspect continuous ROI using pixel-center extents."""
    x, y, width, height = roi
    ow, oh = checked_size(output_size)
    ratio = (ow - 1) / (oh - 1)
    dx, dy = width - 1., height - 1.
    if dx / dy > ratio:
        new_dx = dy * ratio
        x += (dx - new_dx) / 2
        dx = new_dx
    else:
        new_dy = dx / ratio
        y += (dy - new_dy) / 2
        dy = new_dy
    return (float(x), float(y), float(dx + 1), float(dy + 1))


def crop_valid_coordinates(mx, my, size, margin=0.):
    """Safety inset in source pixels, distinct from the output sampling mask."""
    return (valid_coordinates(mx, my, size) & (mx >= margin) & (my >= margin)
            & (mx <= size[0]-1-margin) & (my <= size[1]-1-margin))


def centered_valid_roi(mask, output_size):
    """Maximal centered homothetic ROI under a conservative discrete-mask test.

    A summed-area table rejects ANY invalid pixel within outward-rounded ROI
    bounds, not merely its corners. Final nonlinear sample coordinates still
    need verification; this is not a global continuous/FOV optimum.
    """
    mask = np.asarray(mask, dtype=bool)
    if mask.ndim != 2 or min(mask.shape) < 2:
        raise ValueError('mask must have at least two rows and columns')
    h, w = mask.shape
    full = aspect_roi((0,0,w,h), output_size)
    cx, cy = (w-1)/2, (h-1)/2
    dx, dy = full[2]-1, full[3]-1
    integral = np.pad(np.cumsum(np.cumsum(~mask, axis=0, dtype=np.int64),axis=1),((1,0),(1,0)))
    def roi(scale):
        return (cx-dx*scale/2, cy-dy*scale/2, dx*scale+1, dy*scale+1)
    def safe(scale):
        x,y,rw,rh = roi(scale)
        x0,y0 = max(0,int(np.floor(x))),max(0,int(np.floor(y)))
        x1,y1 = min(w-1,int(np.ceil(x+rw-1))),min(h-1,int(np.ceil(y+rh-1)))
        return integral[y1+1,x1+1]-integral[y0,x1+1]-integral[y1+1,x0]+integral[y0,x0] == 0
    if safe(1.):
        return roi(1.)
    low, high = max(1/dx,1/dy), 1.
    if low > high or not safe(low):
        raise ValueError('no centered valid crop; reduce angle/shift or allow black borders')
    for _ in range(48):
        middle = (low+high)/2
        if safe(middle): low=middle
        else: high=middle
    return roi(low)


def shrink_centered_roi(roi, canvas_size, pixels=1.):
    cx,cy = (canvas_size[0]-1)/2,(canvas_size[1]-1)/2
    factor = 1-2*pixels/min(roi[2]-1,roi[3]-1)
    if factor <= 0:
        raise ValueError('centered crop became too small')
    dx,dy = (roi[2]-1)*factor,(roi[3]-1)*factor
    if min(dx,dy) < 1:
        raise ValueError('centered crop needs at least two pixel centers per axis')
    return (cx-dx/2,cy-dy/2,dx+1,dy+1)


def camera_fingerprint(camera):
    canonical = {'size':list(camera.size),'k':camera.k.tolist(),'d':camera.d.tolist()}
    return hashlib.sha256(json.dumps(canonical,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()


def plan_fixed_crop(camera, views, safety_px=.5):
    """Intersect masks for listed poses, then validate ONE immutable centered ROI.

    Safety is asserted only for listed transforms, not every angle between them.
    Applying the plan to an unlisted view must still check its dense coordinates.
    """
    if not views or not np.isfinite(safety_px) or safety_px < 0:
        raise ValueError('need nonempty views and a finite nonnegative safety margin')
    bases = [replace(view,border='keep',fixed_roi=None,crop_safety_px=0) for view in views]
    common = np.ones((camera.size[1],camera.size[0]),dtype=bool)
    for view in bases:
        mapping = Mapping(camera,view)
        common &= crop_valid_coordinates(*mapping.dense(),camera.size,safety_px)
    roi = centered_valid_roi(common,camera.size)
    for attempt in range(9):
        safe = True
        for view in bases:
            try:
                Mapping(camera,replace(view,border='crop-fixed',fixed_roi=roi,crop_safety_px=safety_px))
            except ValueError:
                safe = False
                break
        if safe: break
        if attempt==8:raise ValueError('could not validate a common continuous sampling crop')
        roi=shrink_centered_roi(roi,camera.size)
    return {'schema':'centered_fixed_crop_v1','input_size':list(camera.size),
            'camera_fingerprint':camera_fingerprint(camera),'fixed_roi':list(roi),'safety_px':float(safety_px),
            'tested_views':[asdict(view) for view in bases],'common_safe_mask_fraction':float(common.mean()),
            'scope':'Only listed poses were tested. No continuous-angle or outside-range safety guarantee. '
                    'Each applied view is validated again. Inset is in source pixels, not a universal LUT error bound.'}


class Mapping:
    def __init__(self, camera, view=View()):
        self.camera, self.view = camera, view
        r = rotation_matrix(view.roll, view.pitch, view.yaw)
        a = affine_matrix(camera.size, view.angle, view.scale, view.shift_x, view.shift_y)
        self.forward_h = a @ camera.k @ r @ np.linalg.inv(camera.k)
        self.inverse_h = np.linalg.inv(self.forward_h)
        self.size = camera.size
        self.roi = (0., 0., float(camera.size[0]), float(camera.size[1]))
        self.crop_to_canvas = np.eye(3)
        width, height = camera.size
        v, u = np.indices((height, width), dtype=np.float64)
        mx, my = self(u, v)
        base_valid = valid_coordinates(mx, my, camera.size)
        self.base_valid_fraction = float(base_valid.mean())
        if view.border in ('crop-center','crop-fixed'):
            safe_mask=crop_valid_coordinates(mx,my,camera.size,view.crop_safety_px)
            roi=tuple(view.fixed_roi) if view.border=='crop-fixed' else centered_valid_roi(safe_mask,camera.size)
            for attempt in range(9):
                self._set_resized_roi(roi)
                sx,sy=self.dense()
                if crop_valid_coordinates(sx,sy,camera.size,view.crop_safety_px).all():break
                if view.border=='crop-fixed':raise ValueError('fixed_roi is not safe for this view and margin')
                if attempt==8:raise ValueError('could not establish a safe centered crop')
                roi=shrink_centered_roi(roi,camera.size)
        elif view.border != "keep":
            roi = largest_valid_rectangle(crop_valid_coordinates(mx,my,camera.size,view.crop_safety_px))
            # Pixel masks do not guarantee validity between pixel centers for
            # arbitrary nonlinear maps. Validate the final sampling coordinates.
            for margin in range(9):
                x, y, rw, rh = roi
                inner = (x + margin, y + margin, rw - 2 * margin, rh - 2 * margin)
                if min(inner[2:]) < 2:
                    break
                self.roi = aspect_roi(inner, camera.size) if view.border == "crop-resize" else inner
                self.size = camera.size if view.border == "crop-resize" else (inner[2], inner[3])
                rx, ry, rw, rh = self.roi
                ow, oh = self.size
                self.crop_to_canvas = np.array([[(rw - 1) / (ow - 1), 0, rx],
                                               [0, (rh - 1) / (oh - 1), ry], [0, 0, 1.]])
                vv, uu = np.indices((oh, ow), dtype=np.float64)
                sx, sy = self(uu, vv)
                if crop_valid_coordinates(sx, sy, camera.size,view.crop_safety_px).all():
                    break
            else:
                raise ValueError("could not establish an all-valid crop")
            if min(inner[2:]) < 2 or not crop_valid_coordinates(sx, sy, camera.size,view.crop_safety_px).all():
                raise ValueError("no safe crop after view transformation")

    def _set_resized_roi(self,roi):
        x,y,width,height=roi
        cw,ch=self.camera.size
        if (min(width,height)<2 or x<0 or y<0 or x+width-1>cw-1+1e-9 or y+height-1>ch-1+1e-9):
            raise ValueError('crop ROI is outside the base canvas or too small')
        if not np.isclose((width-1)/(height-1),(cw-1)/(ch-1),rtol=1e-10,atol=1e-12):
            raise ValueError('fixed/centered ROI must preserve pixel-center aspect ratio')
        self.roi=tuple(float(v) for v in roi)
        self.size=self.camera.size
        self.crop_to_canvas=np.array([[(width-1)/(cw-1),0,x],[0,(height-1)/(ch-1),y],[0,0,1.]])

    def __call__(self, u, v):
        u, v = np.broadcast_arrays(np.asarray(u, dtype=float), np.asarray(v, dtype=float))
        h = self.inverse_h @ self.crop_to_canvas
        z = h[2, 0] * u + h[2, 1] * v + h[2, 2]
        finite_front = np.isfinite(z) & (z > 1e-10)
        denominator = np.where(finite_front, z, 1.)
        ideal_u = (h[0, 0] * u + h[0, 1] * v + h[0, 2]) / denominator
        ideal_v = (h[1, 0] * u + h[1, 1] * v + h[1, 2]) / denominator
        sx, sy = destination_to_source(self.camera, ideal_u, ideal_v)
        return np.where(finite_front, sx, np.nan), np.where(finite_front, sy, np.nan)

    def dense(self):
        v, u = np.indices((self.size[1], self.size[0]), dtype=np.float64)
        return self(u, v)

    def metadata(self):
        return {"view": asdict(self.view), "output_size": list(self.size),
                "valid_roi_on_base_canvas": list(self.roi),
                "input_camera_ray_to_rectified_ray_rotation": "Rz(roll) @ Ry(yaw) @ Rx(pitch)",
                "axes": "x right, y down, z forward; angles in degrees; positive 2-D angle is clockwise",
                "forward_h_ideal_input_to_base_output": self.forward_h.tolist(),
                "final_output_to_base_canvas": self.crop_to_canvas.tolist(),
                "base_valid_fraction": self.base_valid_fraction,
                "pose_limit": "Pure camera rotation / image affine only; no translation-depth compensation or recovery outside captured FOV."}
