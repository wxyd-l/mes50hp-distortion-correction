"""Run with python -m software.cli from the project root."""
from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path

import cv2
import numpy as np

from .calibrate import calibrate_images
from .reference import (bilinear_fixed, compare, fixed_map, fixed_parameters,
                        load_config, synthetic_config, synthetic_image)


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data,indent=2,ensure_ascii=False,allow_nan=False)+"\n",encoding="utf-8")


def export(config, destination, image=None):
    """Validate the entire frame before exporting any coefficients or vectors."""
    qx,qy = fixed_map(config)
    params = fixed_parameters(config)
    dst = Path(destination)
    dst.mkdir(parents=True,exist_ok=True)
    names = list(params)
    manifest = {"provenance":config.get("provenance",{"kind":"unspecified"}),
                "image_size":config["image_size"],"arithmetic":"signed32; overflow rejected; signed64 multiply; arithmetic right shift",
                "formats":{"a":"Q4.28","k1_k2_p1_p2":"Q8.24","fx_fy_cx_cy":"Q16.16","source":"Q16.16"},
                "parameter_order":names,"parameters":params,"validated_pixels":int(qx.size),
                "border":"each out-of-range neighbor is zero", "bilinear":"high 8 fractional bits; sum of four weighted RGB888 taps; (sum+32768)>>16"}
    if len(params) == 17:
        manifest["formats"]["a"] = "Q4.28 3x3 homogeneous matrix; first six entries then a20,a21,a22 after intrinsics"
        manifest["homogeneous_division"] = "Q8.24 numerator/denominator; signed quotient truncates toward zero"
        manifest["positive_depth"] = bool(config.get("projective_positive_depth", False))
    write_json(dst/"fixed_parameters.json",manifest)
    (dst/"parameters.mem").write_text("".join(f"{params[n]&0xffffffff:08x}\n" for n in names),encoding="ascii")
    (dst/"parameters.vh").write_text("// Generated coefficients. See fixed_parameters.json for provenance.\n"+
        "".join(f"localparam signed [31:0] CFG_{n.upper()} = 32'sh{params[n]&0xffffffff:08x};\n" for n in names),encoding="ascii")
    np.savez_compressed(dst/"coordinate_golden.npz",source_x_q16=qx,source_y_q16=qy)
    (dst/"coordinates.mem").write_text("".join(f"{int(x)&0xffffffff:08x}{int(y)&0xffffffff:08x}\n" for x,y in zip(qx.ravel(),qy.ravel())),encoding="ascii")
    if image is not None:
        out = bilinear_fixed(image,qx,qy)
        for name,pixels in (("input_rgb.mem",image),("expected_rgb.mem",out)):
            (dst/name).write_text("".join(f"{int(r):02x}{int(g):02x}{int(b):02x}\n" for r,g,b in pixels.reshape(-1,3)),encoding="ascii")
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command",required=True)
    p = sub.add_parser("calibrate",help="calibrate user-supplied chessboard photographs; no synthetic fallback")
    p.add_argument("--images",required=True,help="quoted glob, e.g. captures/*.png")
    p.add_argument("--columns",type=int,required=True,help="inner corners, not squares")
    p.add_argument("--rows",type=int,required=True)
    p.add_argument("--square-size",type=float,required=True)
    p.add_argument("--holdout-every",type=int,default=5)
    p.add_argument("--output",required=True)
    p = sub.add_parser("export",help="full-frame numeric validation, coefficient and coordinate vectors")
    p.add_argument("--config",required=True)
    p.add_argument("--output",required=True)
    p = sub.add_parser("compare",help="compare floating, OpenCV and fixed reference on a supplied image")
    p.add_argument("--config",required=True)
    p.add_argument("--image",required=True)
    p.add_argument("--output",required=True)
    p = sub.add_parser("demo",help="generate explicitly SYNTHETIC test fixtures, never a calibration result")
    p.add_argument("--output",default="build/synthetic_demo")
    p.add_argument("--width",type=int,default=64)
    p.add_argument("--height",type=int,default=48)
    p = sub.add_parser("roundtrip",help="independently synthesize a distorted grid then reconstruct it with the fixed model")
    p.add_argument("--output",default="build/synthetic_roundtrip")
    p.add_argument("--width",type=int,default=512)
    p.add_argument("--height",type=int,default=384)
    from .pipeline import add_arguments
    p = sub.add_parser("process", help="process an image sequence: raw-frame Gamma, then geometry and bilinear")
    add_arguments(p)
    p = sub.add_parser("algorithm-demo", help="synthetic dark/bright sequence through Gamma and lens/pose correction")
    p.add_argument("--output", default="build/algorithm_demo")
    p.add_argument("--width", type=int, default=384)
    p.add_argument("--height", type=int, default=288)
    p = sub.add_parser("pose", help="build an output-to-source camera rotation and validate its fixed-point map")
    p.add_argument("--config", required=True)
    p.add_argument("--yaw", type=float, default=0.0)
    p.add_argument("--pitch", type=float, default=0.0)
    p.add_argument("--roll", type=float, default=0.0)
    p.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    if args.command == "process":
        from .pipeline import run
        report = run(args)
        print(json.dumps({"frames":len(report["frames"]),"output":args.output},indent=2))
    elif args.command == "algorithm-demo":
        from .pipeline import demo
        report = demo(args.output, args.width, args.height)
        print(json.dumps({"provenance":report["provenance"],"frames":report["frames"]},indent=2))
    elif args.command == "pose":
        from .geometry import pose_config
        config = pose_config(load_config(args.config),yaw_degrees=args.yaw,
                             pitch_degrees=args.pitch,roll_degrees=args.roll)
        qx,qy = fixed_map(config)
        write_json(args.output,config)
        print(json.dumps({"validated_pixels":int(qx.size),"output":args.output}))
    elif args.command == "roundtrip":
        from .roundtrip import generate_roundtrip
        config,report,_ = generate_roundtrip(args.output,args.width,args.height)
        write_json(Path(args.output)/"SYNTHETIC_TEST_ONLY.json",config)
        write_json(Path(args.output)/"roundtrip_report.json",report)
        print(json.dumps(report,indent=2,ensure_ascii=False))
    elif args.command == "calibrate":
        data = calibrate_images(glob.glob(args.images,recursive=True),args.columns,args.rows,args.square_size,args.holdout_every)
        write_json(args.output,data)
        print(f"Saved camera-image calibration: {args.output}")
    elif args.command == "export":
        manifest = export(load_config(args.config),args.output)
        print(json.dumps({"validated_pixels":manifest["validated_pixels"],"output":args.output}))
    else:
        dst = Path(args.output)
        dst.mkdir(parents=True,exist_ok=True)
        if args.command == "demo":
            config = synthetic_config(args.width,args.height)
            image = synthetic_image(args.width,args.height)
            write_json(dst/"SYNTHETIC_TEST_ONLY.json",config)
            export(config,dst/"vectors",image)
            cv2.imwrite(str(dst/"synthetic_input.png"),cv2.cvtColor(image,cv2.COLOR_RGB2BGR))
        else:
            config = load_config(args.config)
            image = cv2.imread(args.image)
            if image is None:
                raise ValueError("could not read image")
            image = cv2.cvtColor(image,cv2.COLOR_BGR2RGB)
        report,out = compare(config,image)
        write_json(dst/"comparison.json",report)
        cv2.imwrite(str(dst/"corrected_fixed.png"),cv2.cvtColor(out,cv2.COLOR_RGB2BGR))
        print(json.dumps(report,indent=2,ensure_ascii=False))


if __name__ == "__main__":
    main()
