#!/usr/bin/env python3
"""Persistent local pipe worker. uint32-LE JSON length, JSON, then packed BGR.

One request yields one result with identical frameID/timestamp. stdout is binary
only; errors terminate the worker, so the host must fall back to the source.
"""
import argparse
import json
import struct
import sys
import numpy as np
from gaze_pipeline import Pipeline


def read_exact(stream,n):
    data=bytearray()
    while len(data)<n:
        block=stream.read(n-len(data))
        if not block: raise EOFError('Truncated worker request')
        data.extend(block)
    return bytes(data)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--models')
    ap.add_argument('--calibration')
    ap.add_argument('--engine',default='hybrid',choices=['geometry','neural','hybrid'])
    ap.add_argument('--context',default='default')
    ap.add_argument('--provider',default='cpu',choices=['cpu','coreml'])
    args=ap.parse_args()
    pipeline=Pipeline(models=args.models,engine=args.engine,calibration=args.calibration,context=args.context,provider=args.provider)
    try:
        while True:
            prefix=sys.stdin.buffer.read(4)
            if not prefix: break
            if len(prefix)!=4: raise EOFError('Truncated request header')
            size=struct.unpack('<I',prefix)[0]
            if size>65536: raise ValueError('Oversized request header')
            header=json.loads(read_exact(sys.stdin.buffer,size))
            w,h=int(header['width']),int(header['height'])
            if not 1<=w<=7680 or not 1<=h<=4320: raise ValueError('Invalid frame dimensions')
            image=np.frombuffer(read_exact(sys.stdin.buffer,w*h*3),np.uint8).reshape(h,w,3)
            output,record=pipeline.process(image,int(header['frameID']),float(header['timestamp']),
                                           command=header.get('command'),render_mode=header.get('renderMode','effect'))
            payload=json.dumps(record,allow_nan=False).encode()
            sys.stdout.buffer.write(struct.pack('<I',len(payload)))
            sys.stdout.buffer.write(payload)
            sys.stdout.buffer.write(output.tobytes())
            sys.stdout.buffer.flush()
    finally:
        pipeline.close()


if __name__=='__main__': main()
