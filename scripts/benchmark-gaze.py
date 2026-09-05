#!/usr/bin/env python3
"""Compare supported processing paths on identical decoded source frames.

This measures runtime and treatment of frames, not ground-truth gaze accuracy.
Each path starts with fresh tracking state and receives every source timestamp.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import cv2
import numpy as np
from gaze_pipeline import Pipeline, atomic_json

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--input',required=True,type=Path)
ap.add_argument('--output',required=True,type=Path)
args=ap.parse_args()
spec=importlib.util.spec_from_file_location('video_renderer',Path(__file__).with_name('render-gaze-video.py'))
renderer=importlib.util.module_from_spec(spec);spec.loader.exec_module(renderer)
times,_=renderer.timestamps(args.input)
sample_ids=sorted(set(np.linspace(0,len(times)-1,min(5,len(times))).astype(int)))
samples={};results=[]
for engine,detector in [('geometry','video'),('hybrid','video'),('neural','video'),('hybrid','image')]:
    name=f'{engine}-{detector}'
    pipeline=Pipeline(engine=engine,mode=detector)
    capture=cv2.VideoCapture(str(args.input))
    records=[]
    try:
        for i,timestamp in enumerate(times):
            ok,frame=capture.read()
            if not ok:raise ValueError(f'Source decode ended at {i}')
            out,record=pipeline.process(frame,i,timestamp-times[0])
            records.append(record)
            if i in sample_ids:
                points=np.vstack([e['contour'] for e in record['eyes'].values()]) if record['eyes'] else np.array([[0,0],[frame.shape[1],frame.shape[0]]])
                center=points.mean(axis=0);width=max(100,np.ptp(points[:,0])*1.4)
                matrix=np.array([[480/width,0,240-center[0]*480/width],[0,480/width,80-center[1]*480/width]],np.float32)
                crop=cv2.warpAffine(out,matrix,(480,160))
                cv2.rectangle(crop,(0,0),(480,24),(20,20,20),-1)
                cv2.putText(crop,f'{name} {timestamp:.3f}s',(8,17),cv2.FONT_HERSHEY_SIMPLEX,.45,(255,255,255),1,cv2.LINE_AA)
                samples.setdefault(i,[]).append(crop)
    finally:
        capture.release();pipeline.close()
    timing=[r['processingMS'] for r in records]
    reasons=Counter(e['reason'] for r in records for e in r['eyes'].values())
    engines=Counter(e.get('renderEngine','pass') for r in records for e in r['eyes'].values())
    active=[any(e.get('rendered') for e in r['eyes'].values()) for r in records]
    results.append({'case':name,'frames':len(records),'renderedFrames':sum(active),
                    'renderSwitches':sum(a!=b for a,b in zip(active,active[1:])),
                    'reasons':dict(reasons),'actualEngines':dict(engines),
                    'processingMedianMS':float(np.median(timing)),'processingP95MS':float(np.percentile(timing,95))})
    print(name,'completed',flush=True)
args.output.parent.mkdir(parents=True,exist_ok=True)
sheet=args.output.with_suffix('.jpg')
cv2.imwrite(str(sheet),np.vstack([np.hstack(samples[i]) for i in sample_ids]))
atomic_json(args.output,{'source':str(args.input.resolve()),'sourceSHA256':hashlib.sha256(args.input.read_bytes()).hexdigest(),
                         'pipelineSHA256':hashlib.sha256(Path(__file__).with_name('gaze_pipeline.py').read_bytes()).hexdigest(),
                         'cases':results,'sampleSheet':str(sheet.resolve()),
                         'limits':['No gaze-angle or eyelid ground truth; these results do not rank gaze accuracy',
                                   'Neural path keeps acceptance gates and may fall back to geometry',
                                   'Processing time excludes video decode, native bridge, display and camera capture']})
