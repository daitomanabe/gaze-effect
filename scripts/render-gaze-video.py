#!/usr/bin/env python3
"""Render every source frame at its original presentation timestamp, with audio."""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import cv2
import numpy as np
from gaze_pipeline import Pipeline, atomic_json


def probe(path):
    return json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)]))


def timestamps(path):
    data=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
        '-show_frames','-show_entries','frame=best_effort_timestamp_time,pkt_duration_time,duration_time','-of','json',str(path)]))
    frames=data['frames']
    pts=[float(f['best_effort_timestamp_time']) for f in frames]
    if any(b<=a for a,b in zip(pts,pts[1:])):
        raise ValueError('Source presentation timestamps are not strictly increasing')
    last=float(frames[-1].get('duration_time',frames[-1].get('pkt_duration_time',pts[-1]-pts[-2] if len(pts)>1 else 1/30)))
    return pts,last


def panel(original,corrected,record):
    h,w=original.shape[:2]
    top=np.hstack([cv2.resize(original,(640,360)),cv2.resize(corrected,(640,360))])
    eyes=record.get('eyes',{})
    if len(eyes)==2:
        pts=np.vstack([e['contour'] for e in eyes.values()])
        center=pts.mean(axis=0)
        width=max(160,float(np.ptp(pts[:,0]))*1.4)
        matrix=np.array([[640/width,0,320-center[0]*640/width],[0,640/width,180-center[1]*640/width]],np.float32)
        bottom=np.hstack([cv2.warpAffine(original,matrix,(640,360),borderMode=cv2.BORDER_REFLECT_101),
                          cv2.warpAffine(corrected,matrix,(640,360),borderMode=cv2.BORDER_REFLECT_101)])
    else:
        bottom=top.copy()
    result=np.vstack([top,bottom])
    for x,y,title in [(0,0,'Original'),(640,0,'Corrected'),(0,360,'Original - eye detail'),(640,360,'Corrected - eye detail')]:
        cv2.rectangle(result,(x,y),(x+640,y+32),(20,20,20),-1)
        cv2.putText(result,title,(x+12,y+23),cv2.FONT_HERSHEY_SIMPLEX,.6,(255,255,255),1,cv2.LINE_AA)
    cv2.putText(result,f"{record['frameID']:04d}  {record['timestamp']:.3f}s",(1050,708),cv2.FONT_HERSHEY_SIMPLEX,.45,(255,255,255),1,cv2.LINE_AA)
    return result


def encode(folder,pts,last,source,destination,audio=True):
    durations=np.diff(pts).tolist()+[last]
    source_info=probe(source)
    video_stream=next(s for s in source_info['streams'] if s['codec_type']=='video')
    is_cfr=len(pts)<3 or np.max(abs(np.diff(pts)-np.median(np.diff(pts))))<.000003
    video_only=folder/'encoded-video.mp4'
    cmd=['ffmpeg','-v','error','-nostdin','-y']
    if is_cfr:
        rate=video_stream['r_frame_rate']
        cmd+=['-framerate',rate,'-i',str(folder/'%06d.png')]
    else:
        manifest=folder/'frames.ffconcat'
        lines=['ffconcat version 1.0']
        for i,d in enumerate(durations):
            lines += [f"file '{i:06d}.png'",'option framerate 1000000',f'duration {d:.9f}']
        manifest.write_text('\n'.join(lines)+'\n')
        cmd+=['-safe','0','-f','concat','-i',str(manifest),'-fps_mode','passthrough',
              '-enc_time_base','1:1000000','-bf','0',
              '-bsf:v',f'setts=duration=if(eq(N\\,{len(pts)-1})\\,{last}/TB\\,DURATION)']
    cmd+=['-an','-c:v','libx264','-crf','16','-preset','fast','-pix_fmt','yuv420p',
          '-frames:v',str(len(pts)),'-video_track_timescale','1000000',str(video_only)]
    subprocess.run(cmd,check=True)
    # Mux in a second pass: -frames:v on a joint encode can stop audio early.
    mux=['ffmpeg','-v','error','-nostdin','-y','-i',str(video_only)]
    if audio: mux+=['-ss',str(pts[0]),'-i',str(source)]
    mux+=['-map','0:v:0']
    if audio: mux+=['-map','1:a?']
    full_count=int(video_stream.get('nb_frames',0))
    duration=pts[-1]-pts[0]+last
    if full_count==len(pts): duration=max(duration,float(source_info['format']['duration'])-pts[0])
    mux+=['-c','copy','-t',str(duration),'-movflags','+faststart',str(destination)]
    subprocess.run(mux,check=True)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--input',required=True,type=Path)
    ap.add_argument('--output',required=True,type=Path)
    ap.add_argument('--engine',choices=['geometry','neural','hybrid'],default='hybrid')
    ap.add_argument('--detector',choices=['video','image'],default='image')
    ap.add_argument('--models',type=Path)
    ap.add_argument('--provider',choices=['cpu','coreml'],default='cpu')
    ap.add_argument('--strength',type=float,default=1)
    ap.add_argument('--max-width',type=int,default=0,help='0 preserves source resolution')
    ap.add_argument('--render-mode',default='effect',choices=['effect','debug','white-eyes','white-eyes-red-pupils'])
    ap.add_argument('--calibration',type=Path)
    ap.add_argument('--context',default='default',help='Person/camera/glasses profile key')
    ap.add_argument('--intrinsics',type=Path,help='JSON 3x3 camera matrix in source pixels')
    ap.add_argument('--comparison',action='store_true')
    ap.add_argument('--debug-video',action='store_true')
    ap.add_argument('--keep-frames',action='store_true')
    ap.add_argument('--limit',type=int)
    args=ap.parse_args()
    if args.input.resolve()==args.output.resolve(): ap.error('Input and output must differ')
    if not 0<=args.strength<=1: ap.error('Strength must be in [0,1]')
    if args.limit is not None and args.limit<1: ap.error('--limit must be positive')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    pts,last=timestamps(args.input)
    if args.limit and args.limit<len(pts):
        last=pts[args.limit]-pts[args.limit-1]
        pts=pts[:args.limit]
    metadata=probe(args.input)
    p=Pipeline(models=args.models,engine=args.engine,mode=args.detector,calibration=args.calibration,
               strength=args.strength,provider=args.provider,context=args.context,
               intrinsics=json.loads(args.intrinsics.read_text()) if args.intrinsics else None)
    work=Path(tempfile.mkdtemp(prefix=args.output.stem+'-frames-',dir=args.output.parent))
    variants={'effect':args.output}
    if args.comparison: variants['comparison']=args.output.with_name(args.output.stem+'-comparison.mp4')
    if args.debug_video: variants['debug']=args.output.with_name(args.output.stem+'-debug.mp4')
    for name in variants: (work/name).mkdir()
    cap=cv2.VideoCapture(str(args.input))
    records=[]; start=time.perf_counter(); outside_changes=0; total_changed=0
    records_path=args.output.with_suffix('.frames.jsonl')
    try:
        with records_path.open('w') as sidecar:
            for i,t in enumerate(pts):
                ok,frame=cap.read()
                if not ok: raise RuntimeError(f'Decode ended before expected frame {i}/{len(pts)}')
                if args.max_width and frame.shape[1]>args.max_width:
                    if args.intrinsics: raise ValueError('Use native resolution with supplied intrinsics')
                    nh=round(frame.shape[0]*args.max_width/frame.shape[1]/2)*2
                    frame=cv2.resize(frame,(args.max_width,nh),interpolation=cv2.INTER_AREA)
                corrected,record=p.process(frame,i,t-pts[0],render_mode=args.render_mode)
                aperture=np.zeros(frame.shape[:2],np.uint8)
                for e in record['eyes'].values(): cv2.fillPoly(aperture,[np.round(e['contour']).astype(np.int32)],1)
                changed=np.any(frame!=corrected,axis=2)
                record['changedOutsideAperture']=int((changed&(aperture==0)).sum()) if args.render_mode=='effect' else None
                record['changedPixels']=int(changed.sum())
                outside_changes+=record['changedOutsideAperture'] or 0
                total_changed+=record['changedPixels']
                sidecar.write(json.dumps(record,allow_nan=False)+'\n')
                records.append(record)
                cv2.imwrite(str(work/'effect'/f'{i:06d}.png'),corrected,[cv2.IMWRITE_PNG_COMPRESSION,1])
                if 'comparison' in variants: cv2.imwrite(str(work/'comparison'/f'{i:06d}.png'),panel(frame,corrected,record),[cv2.IMWRITE_PNG_COMPRESSION,1])
                if 'debug' in variants: cv2.imwrite(str(work/'debug'/f'{i:06d}.png'),p.debug(frame,record),[cv2.IMWRITE_PNG_COMPRESSION,1])
                if i%24==0: print(f'frame={i}/{len(pts)} time={t-pts[0]:.2f}s processing={record["processingMS"]:.1f}ms',flush=True)
        if not args.limit and cap.read()[0]: raise RuntimeError('Decoded more frames than timestamp manifest')
    finally:
        cap.release(); p.close()
    for name,dest in variants.items():
        encode(work/name,pts,last,args.input,dest)
        output_pts,_=timestamps(dest)
        if len(output_pts)!=len(pts): raise RuntimeError(f'Output frame count mismatch: {dest}')
        deviation=max(abs(a-(b-pts[0])) for a,b in zip(output_pts,pts))
        if deviation>.002: raise RuntimeError(f'Timestamp drift {deviation}s: {dest}')
        subprocess.run(['ffmpeg','-v','error','-i',str(dest),'-f','null','-'],check=True)
    reasons=Counter(e['reason'] for r in records for e in r['eyes'].values())
    engines=Counter(e.get('renderEngine','pass') for r in records for e in r['eyes'].values())
    timing=[r['processingMS'] for r in records]
    summary={'source':str(args.input.resolve()),'sourceSHA256':hashlib.sha256(args.input.read_bytes()).hexdigest(),
             'outputs':{k:str(v.resolve()) for k,v in variants.items()},'frames':len(records),
             'duration':pts[-1]-pts[0]+last,'sourceMetadata':metadata,'engine':args.engine,'detector':args.detector,
             'calibration':str(args.calibration) if args.calibration else None,
             'renderedFrames':sum(any(e.get('rendered') for e in r['eyes'].values()) for r in records),
             'reasons':dict(reasons),'engines':dict(engines),'changedOutsideAperture':outside_changes,
             'changedPixels':total_changed,'processingMedianMS':float(np.median(timing)),
             'processingP95MS':float(np.percentile(timing,95)),'elapsedSeconds':time.perf_counter()-start,
             'frameCountAndTimestampsVerified':True,'fullDecodeVerified':True,
             'pipelineSHA256':hashlib.sha256((Path(__file__).parent/'gaze_pipeline.py').read_bytes()).hexdigest(),
             'modelManifest':json.loads((p.models/'neural-manifest.json').read_text()),
             'frameDirectory':str(work.resolve()) if args.keep_frames else None,
             'limitations':['No ground-truth gaze angles in source clip','Quality scores are not probabilities',
                            'Head/eye geometry uses an approximate anatomical model',
                            'This clip does not validate all identities or eyewear'],
             'records':str(records_path.resolve())}
    atomic_json(args.output.with_suffix('.report.json'),summary)
    if not args.keep_frames: shutil.rmtree(work)
    print(f"Completed: {len(records)} frames at original timestamps",flush=True)
    print(f"Output: {args.output.resolve()}",flush=True)
    print(f"Report: {args.output.with_suffix('.report.json').resolve()}",flush=True)


if __name__=='__main__': main()
