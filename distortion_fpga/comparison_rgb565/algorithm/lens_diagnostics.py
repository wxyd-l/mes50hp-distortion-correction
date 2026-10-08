"""Sampled Brown model diagnostics; never estimates calibration from lens FOV."""
import numpy as np

from undistort import Camera, checked_size


def brown_jacobian(x, y, coeffs):
    """Derivative of forward distorted normalized coordinates w.r.t. ideal rays."""
    d = np.asarray(coeffs, dtype=np.float64)
    if d.shape != (5,) or not np.isfinite(d).all():
        raise ValueError('expected finite Brown [k1,k2,p1,p2,k3]')
    x, y = np.broadcast_arrays(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64))
    if not np.isfinite(x).all() or not np.isfinite(y).all():
        raise ValueError('rays must be finite')
    k1, k2, p1, p2, k3 = d
    r2 = x*x+y*y
    radial = 1+r2*(k1+r2*(k2+r2*k3))
    gradient = k1+2*k2*r2+3*k3*r2*r2
    xx = radial+2*x*x*gradient+2*p1*y+6*p2*x
    xy = 2*x*y*gradient+2*p1*x+2*p2*y
    yy = radial+2*y*y*gradient+6*p1*y+2*p2*x
    return xx, xy, yy


def inspect_brown(camera, samples=(129, 73)):
    """Sample the unrotated ideal output rectangle defined by camera.K.

    Nonpositive eigenvalues flag local nonmonotonicity/compression. Passing a
    finite sample is NOT proof of global invertibility, model fit or suitability
    for the physical lens. Crop/pose validity is checked separately by Mapping.
    """
    nx, ny = checked_size(samples)
    if nx*ny > 4_000_000:
        raise ValueError('diagnostic sampling exceeds limit')
    width, height = camera.size
    u, v = np.meshgrid(np.linspace(0, width-1, nx), np.linspace(0, height-1, ny))
    x = (u-camera.k[0, 2])/camera.k[0, 0]
    y = (v-camera.k[1, 2])/camera.k[1, 1]
    with np.errstate(over='ignore', invalid='ignore'):
        xx, xy, yy = brown_jacobian(x, y, camera.d)
        determinant = xx*yy-xy*xy
        minimum_eigenvalue = (xx+yy-np.hypot(xx-yy, 2*xy))/2
    finite = np.isfinite(determinant) & np.isfinite(minimum_eigenvalue)
    problematic = ~finite | (minimum_eigenvalue <= 1e-6)
    return {
        'sample_shape': [ny, nx], 'sample_count': nx*ny,
        'nonfinite_samples': int(np.count_nonzero(~finite)),
        'nonmonotone_or_nearly_singular_samples': int(np.count_nonzero(problematic)),
        'minimum_jacobian_determinant': float(determinant[finite].min()) if finite.any() else None,
        'minimum_jacobian_eigenvalue': float(minimum_eigenvalue[finite].min()) if finite.any() else None,
        'sampled_local_check_passed': bool(not problematic.any()),
        'scope': 'Sampled unrotated ideal output domain only. Not physical FOV, calibration acceptance, '
                 'global invertibility proof or Brown/fisheye model selection.',
    }


def synthetic_scaled_camera(camera, size):
    """Endpoint-preserving scaling ONLY for artificial stress fixtures.

    This is not the OV5640 sensor crop/binning/readout transform. Actual camera
    modes need their own calibrated intrinsics or a verified mode transform.
    """
    width, height = checked_size(size)
    sx, sy = (width-1)/(camera.size[0]-1), (height-1)/(camera.size[1]-1)
    k = camera.k.copy()
    k[0, :] *= sx
    k[1, :] *= sy
    return Camera((width, height), k, camera.d)


def synthetic_wide_camera(size=(1280, 720), output_hfov=120.):
    """Artificial Brown fixture with assumed IDEAL OUTPUT horizontal FOV.

    Uses centered principal point, fx=fy and pixel-center endpoints. Coefficients
    are arbitrary. This does NOT model the user's lens nor its distorted FOV.
    """
    width, height = checked_size(size)
    if not np.isfinite(output_hfov) or not 0 < output_hfov < 180:
        raise ValueError('ideal horizontal FOV must be finite and in (0,180)')
    f = (width-1)/(2*np.tan(np.deg2rad(output_hfov)/2))
    k = [[f, 0, (width-1)/2], [0, f, (height-1)/2], [0, 0, 1]]
    return Camera((width, height), k, [-.08, .008, .0003, -.0002, 0])
