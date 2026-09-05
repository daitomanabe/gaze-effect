#!/usr/bin/env python3
"""Measure eye-relative motion in two rendered videos at matching timestamps.

Output image measurements use dark connected regions inside the observed eyelid
mask, without consulting the commanded target. These are image-motion proxies,
not calibrated gaze directions or a photorealism score.
"""
import argparse
import hashlib
import json
from pathlib import Path
import cv2
import numpy as np
from gaze_pipeline import atomic_json, transform


def summarize(values):
    a=np.asarray(values,float)
    if not len(a):return {'count':0}
    steps=[np.linalg.norm(b[1:]-a[1:]) for a,b in zip(a,a[1:]) if b[0]-a[0]==1]
    return {'count':len(a),'stdEyeWidths':np.std(a[:,1:],axis=0).tolist(),
            'rangeEyeWidths':np.ptp(a[:,1:],axis=0).tolist(),
            'stepP95EyeWidths':float(np.percentile(steps,95)) if steps else None}


def measure(video, records_path):
    records=[json.loads(s) for s in records_path.read_text().splitlines()]
    cap=cv2.VideoCapture(str(video))
    pixels={};targets={};coverage={};measurements=[]
    try:
        for r in records:
            ok,image=cap.read()
            if not ok:raise ValueError('Video ended before its records')
            for name,e in r['eyes'].items():
                basis=np.array(e['basis']);width=e['width']
                corners=np.array(e['contour'])[[0,8]].mean(axis=0)
                goal=basis@(np.array(e['target'])-corners)/width
                targets.setdefault(name,[]).append([r['frameID'],*goal])
                if not e.get('rendered'):continue
                matrix=np.array(e['roiTransform'],np.float32);w,h=e['roiSize']
                crop=cv2.warpAffine(image,matrix,(w,h))
                mask=np.zeros((h,w),np.uint8)
                cv2.fillPoly(mask,[np.round(transform(e['contour'],matrix)).astype(np.int32)],1)
                mask=cv2.erode(mask,np.ones((3,3),np.uint8))
                gray=cv2.cvtColor(crop,cv2.COLOR_BGR2GRAY)
                values=gray[mask>0]
                coverage[name]=coverage.get(name,0)+1
                if len(values)<20:continue
                threshold,_=cv2.threshold(values.reshape(-1,1),0,255,cv2.THRESH_BINARY+cv2.THRESH_OTSU)
                dark=((gray<=threshold)&(mask>0)).astype(np.uint8)
                count,labels,stats,centers=cv2.connectedComponentsWithStats(dark)
                if count<2:continue
                index=1+int(np.argmax(stats[1:,cv2.CC_STAT_AREA]))
                area=int(stats[index,cv2.CC_STAT_AREA])
                if not 8<=area<=len(values)*.85:continue
                center=transform([centers[index]],cv2.invertAffineTransform(matrix))[0]
                normalized=basis@(center-corners)/width
                pixels.setdefault(name,[]).append([r['frameID'],*normalized])
                measurements.append({'frameID':r['frameID'],'eye':name,'centroid':center.tolist(),
                                     'eyeRelative':normalized.tolist(),'componentPixels':area})
        if cap.read()[0]:raise ValueError('Video has more frames than its records')
    finally:cap.release()
    return {'video':str(video.resolve()),'sha256':hashlib.sha256(video.read_bytes()).hexdigest(),
            'recordSHA256':hashlib.sha256(records_path.read_bytes()).hexdigest(),
            'frames':len(records),'renderedEyeFrames':coverage,
            'targetMotion':{k:summarize(v) for k,v in targets.items()},
            'imageIrisMotion':{k:summarize(v) for k,v in pixels.items()},
            'measurements':measurements,
            'estimatedYawRangeDegrees':float(np.ptp([r['pose']['angles'][1] for r in records if r['pose']]))}


ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--before',required=True,type=Path)
ap.add_argument('--before-records',required=True,type=Path)
ap.add_argument('--after',required=True,type=Path)
ap.add_argument('--after-records',required=True,type=Path)
ap.add_argument('--output',required=True,type=Path)
args=ap.parse_args()
before_times=[(r['frameID'],r['timestamp']) for r in map(json.loads,args.before_records.read_text().splitlines())]
after_times=[(r['frameID'],r['timestamp']) for r in map(json.loads,args.after_records.read_text().splitlines())]
if before_times!=after_times:raise ValueError('Comparison records must have identical frame IDs and timestamps')
before=measure(args.before,args.before_records);after=measure(args.after,args.after_records)
result={'before':before,'after':after,
        'limits':['Eye-relative dark-region motion is not ground-truth gaze angle',
                  'Eyelid clipping, lashes, reflections and texture can shift the measured centroid',
                  'Input/output masks come from source landmarks; output targets are not used to locate the iris']}
atomic_json(args.output,result)
print(json.dumps({label:{k:v for k,v in item.items() if k not in ('measurements','recordSHA256','sha256')}
                  for label,item in [('before',before),('after',after)]},indent=2))
