#!/usr/bin/env python3
"""Create a profile only from explicitly identified lens-fixation intervals."""
import argparse
import cv2
from gaze_pipeline import Pipeline

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('--input',required=True)
ap.add_argument('--profile',required=True)
ap.add_argument('--context',required=True,help='Person / camera / glasses profile key')
ap.add_argument('--lens-range',required=True,action='append',help='start:end seconds when looking at the camera LENS, not the screen')
args=ap.parse_args()
ranges=[tuple(map(float,x.split(':'))) for x in args.lens_range]
if any(b-a<2.1 or a<0 for a,b in ranges):ap.error('Each lens interval must be at least 2.1 seconds')
p=Pipeline(engine='geometry',calibration=args.profile,context=args.context)
cap=cv2.VideoCapture(args.input);fps=cap.get(cv2.CAP_PROP_FPS)
try:
    if not cap.isOpened() or fps<=0:raise ValueError('Cannot open calibration video')
    i=0;active=-1;completed=0
    while True:
        ok,image=cap.read()
        if not ok:break
        t=cap.get(cv2.CAP_PROP_POS_MSEC)/1000
        command=None
        for j,(a,b) in enumerate(ranges):
            if a<=t<=b and j>active:
                if active>=0 and p.calibration.collecting:raise ValueError('Previous lens interval did not yield a valid calibration')
                active=j;command='calibrate' if j==0 else 'calibrate-add'
        _,record=p.process(image,i,t,command=command)
        if active>=0 and t>ranges[active][1] and p.calibration.collecting:
            raise ValueError('Not enough stable lens-fixation samples within the specified interval')
        if record.get('calibration')=='calibration saved':completed=active+1
        i+=1
    if completed!=len(ranges):raise ValueError(f'Only {completed}/{len(ranges)} intervals completed')
    print(f'Saved profile: {args.profile}; {completed} pose samples')
finally:cap.release();p.close()
