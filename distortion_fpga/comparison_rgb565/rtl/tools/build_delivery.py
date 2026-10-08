"""Build/verify a scoped source snapshot ZIP, excluding vendor/runtime files.

Archives are created exclusively: never replace an existing user archive.
Verification checks bytes and manifest, NOT execution or board validation.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path,PurePosixPath
import zipfile


def safe_name(name):
    parts=PurePosixPath(name)
    return (bool(name) and not parts.is_absolute() and '..' not in parts.parts
            and str(parts)==name and '\\' not in name and ':' not in name)


def verify(path):
    with zipfile.ZipFile(path) as archive:
        names=archive.namelist()
        if len(names)!=len(set(names)) or any(not safe_name(name) for name in names):
            raise ValueError('duplicate or unsafe archive paths')
        if sum(info.file_size for info in archive.infolist())>256*1024*1024 or any(info.file_size>64*1024*1024 for info in archive.infolist()):
            raise ValueError('archive exceeds scoped verification size limit')
        manifest=json.loads(archive.read('delivery_manifest.json'))
        if manifest.get('schema')!='fpga_algorithm_delivery_v1':raise ValueError('unsupported delivery manifest')
        files=manifest['files']
        if set(names)!=set(files)|{'delivery_manifest.json'}:raise ValueError('archive contents differ from manifest')
        for name,row in files.items():
            data=archive.read(name)
            if len(data)!=row['bytes'] or hashlib.sha256(data).hexdigest()!=row['sha256']:
                raise ValueError(f'archive checksum mismatch: {name}')
    return {'verified':True,'files':len(files),'payload_bytes':sum(row['bytes'] for row in files.values()),
            'scope':'Checks file integrity only, not execution, synthesis or hardware.'}


def build(root,destination,package=None):
    root=Path(root).resolve();destination=Path(destination)
    if destination.suffix.lower()!='.zip':raise ValueError('delivery output must be a ZIP file')
    selected=[root/'README.md',root/'DELIVERY_GUIDE.md',root/'.gitignore']
    folders={'algorithm':('*.py','*.md','*.ps1','requirements.txt'),
             'algorithm/examples':('camera_demo.json','view_rotate.json','view_tilt.json','view_center.json','angle_commands.json'),
             'algorithm/tests':('*.py',),
             'rtl':('*.md','*.ps1'),'rtl/src':('*.v',),'rtl/sim':('*.sv',),
             'rtl/tools':('*.py',),'rtl/tests':('*.py',),'rtl/formula':('*.sv','*.md')}
    for folder,patterns in folders.items():
        for pattern in patterns:selected.extend((root/folder).glob(pattern))
    selected=sorted(set(path for path in selected if path.is_file()))
    if not selected:raise ValueError('no scoped project files')
    payload={}
    for path in selected:
        if path.is_symlink() or not path.resolve().is_relative_to(root):raise ValueError('source symlink/outside root is not packaged')
        if path.resolve()==destination.resolve():raise ValueError('archive must not replace source')
        payload[path.relative_to(root).as_posix()]=path.read_bytes()
    included_reports=[];excluded_reports=[]
    candidates=[root/'rtl/out/regression.json',root/'rtl/out/cache_regression.json',
                *sorted((root/'rtl/out').glob('package-*/result.json')),
                *sorted((root/'rtl/out').glob('formula-*/result.json'))]
    for path in candidates:
        if not path.is_file():continue
        data=path.read_bytes();obj=json.loads(data)
        rows=obj if isinstance(obj,list) else [obj]
        current=bool(rows)
        for row in rows:
            hashes=row.get('source_sha256',{})
            if row.get('passed') is not True or not hashes:current=False;break
            for name,digest in hashes.items():
                normalized=name.replace('\\','/')
                if not safe_name(normalized) or 'rtl/'+normalized not in payload or hashlib.sha256(payload['rtl/'+normalized]).hexdigest()!=digest:
                    current=False;break
            for name,digest in row.get('algorithm_source_sha256',{}).items():
                normalized=name.replace('\\','/')
                if not safe_name(normalized) or 'algorithm/'+normalized not in payload or hashlib.sha256(payload['algorithm/'+normalized]).hexdigest()!=digest:
                    current=False;break
        name=path.relative_to(root).as_posix()
        if current:payload[name]=data;included_reports.append(name)
        else:excluded_reports.append(name)
    if package is not None:
        package=Path(package).resolve();report=json.loads((package/'package.json').read_text(encoding='utf-8'))
        required={'grid.memh','grid.json','source_rgb565.memh','expected_rgb565.memh','expected_valid.memh','rtl_parameters.vh'}
        if report.get('schema')!='rtl_test_package_v1' or set(report['sha256'])!=required:
            raise ValueError('invalid reference package checksum manifest')
        for name,digest in report['sha256'].items():
            data=(package/name).read_bytes()
            if hashlib.sha256(data).hexdigest()!=digest:raise ValueError(f'reference checksum failed: {name}')
            payload['reference_package/'+name]=data
        payload['reference_package/package.json']=(package/'package.json').read_bytes()
    if any(len(data)>64*1024*1024 for data in payload.values()) or sum(map(len,payload.values()))>256*1024*1024:
        raise ValueError('scoped delivery exceeds size limit')
    manifest={'schema':'fpga_algorithm_delivery_v1','created_at_utc':datetime.now(timezone.utc).isoformat(),
        'files':{name:{'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()} for name,data in sorted(payload.items())},
        'included_current_simulation_reports':included_reports,'excluded_stale_reports':excluded_reports,
        'scope':'Local source snapshot and optional reference package. No vendor PDS/IP, original board documents, '
                'Python/OpenCV/ModelSim runtime, user raw captures or camera hardware parameters are included automatically. '
                'Current simulation reports match their hashed source subset; not synthesis/board validation. '
                'Do not deploy artificial reference camera parameters as a real calibration.'}
    destination.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(destination,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for name,data in sorted(payload.items()):archive.writestr(name,data)
        archive.writestr('delivery_manifest.json',json.dumps(manifest,indent=2,allow_nan=False))
    verification=verify(destination)
    return {'archive':str(destination.resolve()),'zip_bytes':destination.stat().st_size,
            'sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),**verification,
            'included_current_simulation_reports':included_reports,'excluded_stale_reports':excluded_reports}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path);p.add_argument('--package',type=Path)
    p.add_argument('--verify',type=Path);args=p.parse_args()
    if args.verify:
        if args.out or args.package:p.error('--verify cannot be combined with build options')
        result=verify(args.verify)
    else:
        if not args.out:p.error('--out is required when building')
        result=build(Path(__file__).resolve().parents[2],args.out,args.package)
    print(json.dumps(result,indent=2))
