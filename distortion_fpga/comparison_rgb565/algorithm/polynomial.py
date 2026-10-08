"""Brown-four formula branch with the teammate's published integer contract.

Independent local oracle/adaptation; no dependency on the teammate checkout.
Q4.28 inverse affine, Q8.24 intermediates, Q16.16 source coordinates.
Coefficient export rounds ties-even; runtime multiply shifts truncate downward.
"""
import numpy as np

PARAMETER_NAMES = ('a00','a01','a02','a10','a11','a12','k1','k2','p1','p2','fx','fy','cx','cy')


def signed32(value, stage):
    value = np.asarray(value, dtype=np.int64)
    if np.any(value < -(1 << 31)) or np.any(value > (1 << 31)-1):
        raise ValueError(f'signed32 overflow at {stage}')
    return value


def quantize_parameter(value, fraction, stage):
    value = np.asarray(value, dtype=np.float64)
    rounded = np.rint(value*(1 << fraction))
    if not np.isfinite(rounded).all() or np.any(rounded < -(1 << 31)) or np.any(rounded > (1 << 31)-1):
        raise ValueError(f'parameter overflow at {stage}')
    return rounded.astype(np.int64)


def export_parameters(mapping):
    camera = mapping.camera
    if camera.d[4] != 0:
        raise ValueError('formula branch supports Brown four only; nonzero k3 is not silently discarded')
    if mapping.view.pitch != 0 or mapping.view.yaw != 0:
        raise ValueError('formula branch supports planar affine only; pitch/yaw needs homogeneous division')
    h = mapping.inverse_h @ mapping.crop_to_canvas
    if not np.allclose(h[2], [0, 0, 1], rtol=0, atol=1e-12):
        raise ValueError('formula branch requires affine output-to-ideal coordinates')
    a = quantize_parameter((np.linalg.inv(camera.k) @ h)[:2], 28, 'affine Q4.28')
    d = quantize_parameter(camera.d[:4], 24, 'Brown Q8.24')
    intrinsics = quantize_parameter([camera.k[0,0],camera.k[1,1],camera.k[0,2],camera.k[1,2]],16,'K Q16.16')
    values = [*a.flat, *d, *intrinsics]
    return dict(zip(PARAMETER_NAMES, map(int, values)))


def validate_parameters(parameters):
    if set(parameters) != set(PARAMETER_NAMES) or any(type(v) is not int or not -(1<<31) <= v < (1<<31) for v in parameters.values()):
        raise ValueError('expected exactly fourteen signed32 integer parameters')
    return parameters


def packed_parameters(parameters):
    validate_parameters(parameters)
    return sum((parameters[name] & 0xffffffff) << (32*i) for i,name in enumerate(PARAMETER_NAMES))


def fixed_points(parameters, u, v):
    """Independent integer expression evaluation; rejects any stage overflow.

    Hardware instead retires each overflowed token as black and counts it.
    Golden package export rejects a configuration if any sampled token overflows.
    """
    p = validate_parameters(parameters)
    u, v = np.broadcast_arrays(np.asarray(u), np.asarray(v))
    if (not np.isfinite(u).all() or not np.isfinite(v).all() or
            np.any(u != np.floor(u)) or np.any(v != np.floor(v)) or
            np.any(u < 0) or np.any(v < 0) or np.any(u > 65535) or np.any(v > 65535)):
        raise ValueError('output indices must be uint16 integers')
    u, v = u.astype(np.int64), v.astype(np.int64)
    def check(value, label): return signed32(value, label)
    def mul(a, b, label): return check((a*b) >> 24, label)
    x,y = [check((p[f'a{i}0']*u+p[f'a{i}1']*v+p[f'a{i}2']) >> 4, f'normalized{i}') for i in range(2)]
    x2,y2,xy = mul(x,x,'x2'),mul(y,y,'y2'),mul(x,y,'xy')
    r2 = check(x2+y2,'r2')
    r4 = mul(r2,r2,'r4')
    scale = check(check((1<<24)+mul(p['k1'],r2,'k1r2'),'scale_partial')+mul(p['k2'],r4,'k2r4'),'scale')
    tx = check(r2+check(2*x2,'twice_x2'),'tx_extent')
    ty = check(r2+check(2*y2,'twice_y2'),'ty_extent')
    tanx = check(check(2*mul(p['p1'],xy,'p1xy'),'twice_p1xy')+mul(p['p2'],tx,'p2tx'),'tanx')
    tany = check(mul(p['p1'],ty,'p1ty')+check(2*mul(p['p2'],xy,'p2xy'),'twice_p2xy'),'tany')
    xd,yd = check(mul(x,scale,'radial_x')+tanx,'xd'),check(mul(y,scale,'radial_y')+tany,'yd')
    return (check(check((xd*p['fx']) >> 24,'project_x')+p['cx'],'source_x'),
            check(check((yd*p['fy']) >> 24,'project_y')+p['cy'],'source_y'))


def fixed_map(mapping):
    v,u = np.indices((mapping.size[1],mapping.size[0]),dtype=np.int64)
    return fixed_points(export_parameters(mapping),u,v)
