#!/usr/bin/env python3
"""Still images / timestamped image sequences using the same camera pipeline."""
import argparse
import json
from pathlib import Path
import cv2
from gaze_pipeline import Pipeline,atomic_json

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--input',type=Path);ap.add_argument('--output',type=Path)
ap.add_argument('--input-dir',type=Path);ap.add_argument('--output-dir',type=Path)
ap.add_argument('--timestamps',type=Path,help='JSON array of presentation times in seconds')
ap.add_argument('--fps',type=float,help='Explicit timing for a constant-rate image sequence')
ap.add_argument('--models',type=Path);ap.add_argument('--engine',default='hybrid',choices=['geometry','neural','hybrid'])
ap.add_argument('--detector',choices=['image','video'],default='image')
ap.add_argument('--metadata',type=Path);ap.add_argument('--metadata-dir',type=Path)
ap.add_argument('--before',type=Path);ap.add_argument('--max-width',type=int,default=0)
ap.add_argument('--strength',type=float,default=1);ap.add_argument('--calibration',type=Path)
ap.add_argument('--context',default='default');ap.add_argument('--render-mode',default='effect',choices=['effect','debug','white-eyes','white-eyes-red-pupils'])
args=ap.parse_args()
if not 0<=args.strength<=1:ap.error('Strength must be in [0,1]')
if args.input_dir:
    if not args.output_dir:ap.error('--output-dir is required')
    if not args.timestamps and not args.fps:ap.error('Sequences require --timestamps or --fps')
    if args.fps is not None and args.fps<=0:ap.error('--fps must be positive')
    files=sorted(p for p in args.input_dir.iterdir() if p.suffix.lower() in ('.jpg','.jpeg','.png'))
    times=json.loads(args.timestamps.read_text()) if args.timestamps else [i/args.fps for i in range(len(files))]
    if len(times)!=len(files):ap.error('Timestamp count does not match image count')
else:
    if not args.input or not args.output:ap.error('--input and --output are required')
    files=[args.input];times=[0]
p=Pipeline(models=args.models,engine=args.engine,mode=args.detector,calibration=args.calibration,strength=args.strength,context=args.context)
try:
    for i,(path,t) in enumerate(zip(files,times)):
        image=cv2.imread(str(path))
        if image is None:raise ValueError(f'Cannot decode {path}')
        if args.max_width and image.shape[1]>args.max_width:
            image=cv2.resize(image,(args.max_width,round(image.shape[0]*args.max_width/image.shape[1])))
        out,record=p.process(image,i,float(t),render_mode=args.render_mode)
        target=args.output_dir/path.name if args.input_dir else args.output
        if target.resolve()==path.resolve():raise ValueError('Input and output must differ')
        target.parent.mkdir(parents=True,exist_ok=True)
        if not cv2.imwrite(str(target),out):raise IOError(f'Cannot write {target}')
        metadata=args.metadata_dir/(path.stem+'.json') if args.metadata_dir else args.metadata
        if metadata:atomic_json(metadata,record)
        if args.before and not args.input_dir:cv2.imwrite(str(args.before),image)
        print(f'{i}: {record["status"]} -> {target}',flush=True)
finally:p.close()
