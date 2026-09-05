#!/usr/bin/env python3
"""Gaze-specific, reference-aware diagnostics; proxy measurements are not gaze truth."""
import argparse
import json
from pathlib import Path
import cv2
import numpy as np
from gaze_pipeline import atomic_json

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--source-frames',required=True,type=Path)
ap.add_argument('--candidate-frames',required=True,type=Path)
ap.add_argument('--records',required=True,type=Path)
ap.add_argument('--output',required=True,type=Path)
ap.add_argument('--annotations',type=Path,help='JSON list: frameID, eye, iris=[x,y]; human source-image annotation')
args=ap.parse_args()
source=sorted(args.source_frames.glob('*.png'));candidate=sorted(args.candidate_frames.glob('*.png'))
records=[json.loads(x) for x in args.records.read_text().splitlines()]
if len(source)!=len(candidate) or len(source)!=len(records):raise ValueError('Frame/record count mismatch')
outside=0;inside=0;allchanges=0;iris_errors=[];temporal=[];stable_temporal=[];previous={};double_candidates=[]
for i,(a,b,r) in enumerate(zip(source,candidate,records)):
    original=cv2.imread(str(a));modified=cv2.imread(str(b))
    if original.shape!=modified.shape:raise ValueError(f'Frame size mismatch at {i}')
    fullmask=np.zeros(original.shape[:2],np.uint8)
    for name,e in r['eyes'].items():
        contour=np.round(e['contour']).astype(np.int32);cv2.fillPoly(fullmask,[contour],1)
        matrix=np.array(e['roiTransform'],np.float32);w,h=e['roiSize']
        old=cv2.warpAffine(original,matrix,(w,h));new=cv2.warpAffine(modified,matrix,(w,h))
        aperture=np.zeros((h,w),np.uint8)
        local=cv2.transform(contour.astype(np.float32)[None],matrix)[0]
        cv2.fillPoly(aperture,[np.round(local).astype(np.int32)],1)
        gray=cv2.cvtColor(new,cv2.COLOR_BGR2GRAY)
        eroded=cv2.erode(aperture,np.ones((3,3),np.uint8))
        values=gray[eroded>0]
        if len(values)>8:
            binary=((gray<np.percentile(values,35))&(eroded>0)).astype(np.uint8)
            count,labels,stats,centers=cv2.connectedComponentsWithStats(binary)
            significant=[j for j in range(1,count) if stats[j,cv2.CC_STAT_AREA]>max(4,len(values)*.08)]
            if len(significant)>1:double_candidates.append({'frameID':i,'eye':name,'components':len(significant)})
        residual=new.astype(np.float32)-old.astype(np.float32)
        iris_local=cv2.transform(np.array([[e['iris']]],np.float32),matrix)[0,0]/[w,h]
        if name in previous and previous[name]['old'].shape==old.shape:
            p=previous[name];g=cv2.cvtColor(old,cv2.COLOR_BGR2GRAY);pg=cv2.cvtColor(p['old'],cv2.COLOR_BGR2GRAY)
            flow=cv2.calcOpticalFlowFarneback(g,pg,None,.5,2,9,2,5,1.1,0)
            yy,xx=np.mgrid[:h,:w].astype(np.float32)
            aligned=cv2.remap(p['residual'],xx+flow[:,:,0],yy+flow[:,:,1],cv2.INTER_LINEAR)
            error=float(np.mean(abs(residual-aligned)[eroded>0]))
            temporal.append(error)
            if np.linalg.norm(iris_local-p['iris'])<.012 and e['reason']=='ok':stable_temporal.append(error)
        previous[name]={'old':old,'residual':residual,'iris':iris_local}
    changed=np.any(original!=modified,axis=2)
    outside+=int((changed&(fullmask==0)).sum());inside+=int((changed&(fullmask>0)).sum());allchanges+=int(changed.sum())
if args.annotations:
    for a in json.loads(args.annotations.read_text()):
        e=records[a['frameID']]['eyes'][a['eye']]
        px=float(np.linalg.norm(np.array(e['iris'])-a['iris']))
        iris_errors.append({'frameID':a['frameID'],'eye':a['eye'],'pixels':px,'fractionEyeWidth':px/e['width']})
report={'frames':len(records),'changedOutsideCandidateAperture':outside,'changedInsideCandidateAperture':inside,
        'changedPixels':allchanges,'meanAlignedResidualChange':float(np.mean(temporal)) if temporal else None,
        'p95AlignedResidualChange':float(np.percentile(temporal,95)) if temporal else None,
        'stablePairCount':len(stable_temporal),
        'stableMeanResidualChange':float(np.mean(stable_temporal)) if stable_temporal else None,
        'stableP95ResidualChange':float(np.percentile(stable_temporal,95)) if stable_temporal else None,
        'multipleDarkComponentCandidates':double_candidates,'manualIrisErrors':iris_errors,
        'groundTruthGazeAccuracy':'not measured: no labeled gaze direction in supplied footage',
        'limits':['Dark components can be lashes or reflections, not necessarily duplicate pupils',
                  'Temporal residual change includes intended eye movements; it is not a flicker verdict',
                  'Candidate aperture is a predicted mask, not human ground truth']}
atomic_json(args.output,report)
print(json.dumps({k:v for k,v in report.items() if k not in ('multipleDarkComponentCandidates','manualIrisErrors','limits')},indent=2))
