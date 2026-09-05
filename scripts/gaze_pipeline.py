"""Shared, timestamped eye analysis and rendering for files and the camera worker.

Coordinates in public records are source pixels, origin top left, unmirrored.
Quality scores are engineering heuristics, not calibrated probabilities.
"""
from __future__ import annotations

import hashlib
import json
import math
import time
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks.python import vision

ROOT = Path(__file__).resolve().parent.parent
EYES = {
    'left': {'contour': [33,7,163,144,145,153,154,155,133,173,157,158,159,160,161,246],
             'iris': [468,469,470,471,472], 'anchors': [33,160,158,133,153,144], 'model': 'R'},
    'right': {'contour': [263,249,390,373,374,380,381,382,362,398,384,385,386,387,388,466],
              'iris': [473,474,475,476,477], 'anchors': [263,387,385,362,380,373], 'model': 'L'},
}


def transform(points, matrix):
    return cv2.transform(np.asarray(points, np.float32).reshape(1, -1, 2), matrix)[0]


def linear(rgb):
    x = np.asarray(rgb, np.float32) / 255
    return np.where(x <= .04045, x / 12.92, ((x + .055) / 1.055) ** 2.4)


def encoded(rgb):
    x = np.clip(rgb, 0, 1)
    return np.round(np.where(x <= .0031308, x * 12.92, 1.055 * x ** (1 / 2.4) - .055) * 255).astype(np.uint8)


def percentile(values, q):
    return float(np.percentile(values, q)) if len(values) else 0.0


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.new')
    temp.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    temp.replace(path)


def mask_record(mask):
    """Compact row-major binary ROI mask; runs are [start, length] pairs."""
    flat = (np.asarray(mask) > 0).astype(np.int8).ravel()
    edges = np.diff(np.r_[0, flat, 0])
    starts = np.flatnonzero(edges == 1)
    ends = np.flatnonzero(edges == -1)
    return {'encoding': 'row-major-runs', 'size': [mask.shape[1], mask.shape[0]],
            'runs': np.column_stack([starts, ends-starts]).tolist()}


class Calibration:
    """Only explicit lens fixation supplies a zero-gaze label; no gaze averaging."""
    def __init__(self, path=None):
        self.path = Path(path) if path else None
        self.profile = None
        self.samples = []
        self.collecting = False
        self.status = 'automatic'
        self.started = None
        if self.path and self.path.exists():
            try:
                p = json.loads(self.path.read_text())
                if p.get('version') != 2 or not isinstance(p.get('samples'), list) or not p['samples'] or not isinstance(p.get('signature'),dict):
                    raise ValueError('Unsupported calibration profile')
                for sample in p['samples']:
                    if len(sample['pose']) != 3 or len(sample['shape']) != 2:
                        raise ValueError('Invalid profile geometry')
                    for name in EYES:
                        if len(sample['offsets'][name]) != 2:
                            raise ValueError('Invalid profile offsets')
                    values = sample['pose'] + sample['shape'] + sum([sample['offsets'][name] for name in EYES], [])
                    if not np.isfinite(np.asarray(values, float)).all():
                        raise ValueError('Non-finite profile')
                self.profile = p
                self.status = 'profile loaded'
            except (ValueError, KeyError, TypeError):
                self.status = 'Invalid profile ignored; reset or calibrate again'

    def command(self, command, timestamp):
        if command in ('calibrate', 'calibrate-add'):
            self.samples = list(self.profile['samples']) if command == 'calibrate-add' and self.profile else []
            self.base_count = len(self.samples)
            self.started = timestamp
            self.collecting = True
            self.status = 'Look at the camera lens'
        elif command == 'reset':
            self.profile = None
            self.samples = []
            self.collecting = False
            self.status = 'automatic'
            if self.path and self.path.exists():
                self.path.unlink()

    def observe(self, record, signature):
        if not self.collecting:
            return
        if self.base_count and self.profile and self.profile['signature'] != signature:
            self.collecting = False
            self.status = 'Cannot add this camera geometry; start a new calibration'
            return
        if record['timestamp'] - self.started > 12:
            self.collecting = False
            self.status = 'Insufficient stable open-eye frames; previous profile preserved'
            return
        eyes = record['eyes']
        if len(eyes) != 2 or any(e['quality'] < .62 or e['reason'] != 'ok' for e in eyes.values()):
            self.status = 'Look at lens; waiting for clear open eyes'
            return
        sample = {'pose': record['pose']['angles'], 'offsets': {}, 'shape': []}
        for name,e in eyes.items():
            delta = np.array(e['iris']) - np.array(e['targetUncalibrated'])
            sample['offsets'][name] = (np.array(e['basis']) @ delta / e['width']).tolist()
            sample['shape'].append(e['radius'] / e['width'])
        if any(np.linalg.norm(v) > .28 for v in sample['offsets'].values()):
            self.status = 'Fixation outside calibration range'
            return
        self.samples.append(sample)
        n = len(self.samples) - self.base_count
        self.status = f'Look at lens: {n}/36 clear frames'
        if n >= 36 and record['timestamp'] - self.started >= 2:
            new = self.samples[-36:]
            spread = max(float(np.std([s['offsets'][k] for s in new], axis=0).max()) for k in EYES)
            if spread > .035:
                self.samples = self.samples[:self.base_count]
                self.status = 'Keep looking at lens; gaze was unstable'
                return
            self.profile = {'version': 2, 'signature': signature, 'created': time.time(),
                            'samples': self.samples[-180:], 'source': 'explicit-lens-fixation'}
            if self.path:
                atomic_json(self.path, self.profile)
            self.collecting = False
            self.status = 'calibration saved'

    def offset(self, name, pose, signature, shape):
        if not self.profile:
            return np.zeros(2)
        if self.profile['signature'] != signature:
            self.status = 'profile inactive: camera / geometry / person / glasses setting changed'
            return np.zeros(2)
        samples = self.profile['samples']
        expected = np.median([s['shape'][list(EYES).index(name)] for s in samples])
        if abs(shape - expected) > .065:
            self.status = 'profile inactive: eye geometry changed'
            return np.zeros(2)
        poses = np.array([s['pose'] for s in samples])
        distances = np.linalg.norm(poses - pose, axis=1)
        if distances.min() > 18:
            self.status = 'profile inactive at this head angle'
            return np.zeros(2)
        weights = np.exp(-distances ** 2 / 100)
        offsets = np.array([s['offsets'][name] for s in samples])
        self.status = 'personal calibration'
        return np.sum(offsets * weights[:,None], axis=0) / weights.sum()


class NeuralWarp:
    """Adapter for the Hsu et al. pretrained flow/relighting model (BGR inputs).

    We use the converted ONNX graph as a model asset, not third-party app code.
    Source checkpoint license and conversion provenance are in THIRD_PARTY.md.
    """
    def __init__(self, models, provider='cpu'):
        import onnxruntime as ort
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2
        opts.inter_op_num_threads = 1
        providers = ['CPUExecutionProvider']
        if provider == 'coreml':
            if 'CoreMLExecutionProvider' not in ort.get_available_providers():
                raise RuntimeError('Core ML provider is unavailable')
            providers.insert(0, 'CoreMLExecutionProvider')
        self.sessions = {}
        manifest = json.loads((Path(models) / 'neural-manifest.json').read_text())
        for name in ('L', 'R'):
            filename = f'gaze_{name}.onnx'
            path = Path(models) / filename
            if hashlib.sha256(path.read_bytes()).hexdigest() != manifest['files'][filename]['sha256']:
                raise ValueError(f'Model checksum mismatch: {filename}')
            self.sessions[name] = ort.InferenceSession(str(path), opts, providers=providers)
        self.providers = self.sessions['L'].get_providers()

    def field(self, crop, anchors, name, desired, iris):
        h,w = crop.shape[:2]
        small = cv2.resize(crop, (64,48)).astype(np.float32) / 255
        yy,xx = np.mgrid[:48,:64].astype(np.float32)
        a = np.asarray(anchors) * [64/w,48/h]
        features = np.stack([v for p in a for v in (xx-int(p[0]), yy-int(p[1]))], -1)[None]
        feeds = {'input_img:0':small[None], 'input_fp:0':features.astype(np.float32)}
        session = self.sessions[EYES[name]['model']]
        # Solve this crop's actual response; no assumption about model angle sign.
        def evaluate(angle):
            feeds['input_ang:0'] = np.array([angle],np.float32)
            flow,light = session.run(['flow_raw:0','lcm_map:0'], feeds)
            f = np.tanh(flow[0])
            ix,iy = np.clip(np.array(iris)*[64/w,48/h], [2,2], [61,45]).astype(int)
            disp = -(f[iy-1:iy+2,ix-1:ix+2].mean(axis=(0,1))*[w/2,h/2] + [ix/63*w/64,iy/47*h/48])
            return f,light[0],disp
        base,_,d0 = evaluate([0,0])
        _,_,dv = evaluate([8,0])
        _,_,dh = evaluate([0,8])
        jac = np.column_stack([(dv-d0)/8,(dh-d0)/8])
        if not np.isfinite(jac).all() or np.linalg.cond(jac) > 40:
            return None
        angle = np.clip(np.linalg.lstsq(jac, desired-d0, rcond=None)[0], -25,25)
        field,light,achieved = evaluate(angle)
        f = cv2.resize(field, (w,h))
        yy,xx = np.mgrid[:h,:w].astype(np.float32)
        mx = xx*64/63 + f[:,:,0]*w/2
        my = yy*48/47 + f[:,:,1]*h/2
        return mx.astype(np.float32),my.astype(np.float32),cv2.resize(light,(w,h)), {
            'angles': angle.tolist(), 'estimatedDisplacement': achieved.tolist(),
            'responseErrorPixels':float(np.linalg.norm(achieved-desired))}


class Pipeline:
    def __init__(self, models=None, engine='hybrid', mode='image', calibration=None,
                 strength=1., provider='cpu', intrinsics=None, context='default'):
        self.models = Path(models) if models else ROOT/'Assets/models'
        self.engine = engine
        self.strength = float(np.clip(strength,0,1))
        self.context = context
        self.intrinsics = intrinsics
        self.calibration = Calibration(calibration)
        self.neural = NeuralWarp(self.models,provider) if engine in ('neural','hybrid') else None
        self.mode = mode
        options = vision.FaceLandmarkerOptions(
            base_options=mp.tasks.BaseOptions(model_asset_path=str(self.models/'face_landmarker.task')),
            running_mode=vision.RunningMode.IMAGE if mode == 'image' else vision.RunningMode.VIDEO,
            num_faces=1, output_face_blendshapes=True, output_facial_transformation_matrixes=True)
        self.detector = vision.FaceLandmarker.create_from_options(options)
        self.last_ms = -1
        self.last_record = None
        self.history = {}
        self.slow = {}
        self.targets = {}
        self.rotation = None
        self.last_timestamp = None

    def close(self):
        self.detector.close()

    def reset_history(self):
        self.history.clear()
        self.slow.clear()
        self.targets.clear()
        self.rotation = None

    def pose(self, points, w, h, dt, face_matrix=None):
        k = np.array(self.intrinsics, np.float64).reshape(3,3) if self.intrinsics is not None else np.array([[w*1.15,0,w/2],[0,w*1.15,h/2],[0,0,1]],np.float64)
        model = np.array([[0,0,0],[0,63,12],[-43,-32,26],[43,-32,26],[-28,28,24],[28,28,24]],np.float64)
        image = points[[1,152,33,263,61,291]].astype(np.float64)
        if face_matrix is None:
            return None
        matrix=np.asarray(face_matrix,np.float64)
        if matrix.shape!=(4,4) or not np.isfinite(matrix).all(): return None
        # Face Geometry uses a camera looking down -Z, with Y pointing up.
        # Convert both canonical and camera axes to the CV convention. Unlike
        # the near-planar six-point PnP solution, this rotation uses the full face.
        u,s,vt=np.linalg.svd(matrix[:3,:3])
        if s.min()<.01 or np.linalg.det(u@vt)<0: return None
        axes=np.diag([1.,-1.,-1.])
        rotation=axes@(u@vt)@axes
        if self.rotation is not None:
            alpha = 1-math.exp(-dt/.06)
            u,_,vt = np.linalg.svd(self.rotation*(1-alpha)+rotation*alpha)
            rotation = u@vt
        self.rotation = rotation
        # Fit translation only with this rotation held fixed. The user's camera
        # intrinsics may differ from MediaPipe's virtual camera parameters.
        rays=np.column_stack([image,np.ones(len(image))])@np.linalg.inv(k).T
        rays=rays[:,:2]/rays[:,2:]
        rotated=model@rotation.T
        rows=[];rhs=[]
        for (x,y),(px,py,pz),weight in zip(rays,rotated,[1.,.2,1.,1.,.35,.35]):
            rows.extend([np.array([1,0,-x])*weight,np.array([0,1,-y])*weight])
            rhs.extend([(x*pz-px)*weight,(y*pz-py)*weight])
        t=np.linalg.lstsq(rows,rhs,rcond=None)[0]
        if not np.isfinite(t).all() or t[2]<=0: return None
        projected=(rotated+t)@k.T
        projected=projected[:,:2]/projected[:,2:]
        residual=float(np.linalg.norm(projected-image,axis=1).mean())
        angles = np.array(cv2.RQDecomp3x3(rotation)[0])
        return {'angles':angles.tolist(), 'reprojectionErrorPixels':residual,
                'intrinsics':'provided' if self.intrinsics is not None else 'estimated',
                'source':'full-face-matrix',
                'rotation':rotation.tolist(), 'translation':t.tolist(), 'matrix':k.tolist()}

    def stabilize_target(self, name, target, center, basis, width, dt, valid):
        """Filter the camera-facing goal in eye coordinates, never the observed gaze.

        Reprojection with the current eye frame follows head translation/roll
        immediately. Only small fluctuations of the normalized goal are damped.
        """
        normalized=basis@(target-center)/width
        if not valid:
            self.targets.pop(name,None)
            return target
        previous=self.targets.get(name)
        if previous is not None:
            difference=normalized-previous
            distance=float(np.linalg.norm(difference))
            if distance<.002:
                normalized=previous.copy()
            else:
                tau=.22 if distance<.025 else .06
                normalized=previous+difference*(1-math.exp(-dt/tau))
        self.targets[name]=normalized.copy()
        return center+basis.T@normalized*width

    def eye(self, image, points, name, pose, blend, dt):
        spec = EYES[name]
        contour = points[spec['contour']]
        corners = contour[[0,8]]
        if corners[0,0] > corners[1,0]: corners = corners[::-1]
        width = float(np.linalg.norm(corners[1]-corners[0]))
        if width < 5: return None
        u = (corners[1]-corners[0])/width
        v = np.array([-u[1],u[0]])
        basis = np.stack([u,v])
        center = corners.mean(axis=0)
        cw = max(48,min(256,int(round(width*1.5))))
        ch = int(round(cw*.75))
        scale = cw/(width*1.5)
        matrix = np.column_stack([basis*scale, np.array([cw/2,ch*7/12])-basis@center*scale]).astype(np.float32)
        inv = cv2.invertAffineTransform(matrix)
        crop = cv2.warpAffine(image,matrix,(cw,ch),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_REFLECT_101)
        local_contour = transform(contour,matrix)
        local_iris = transform(points[spec['iris']],matrix)
        source = local_iris[0].copy()
        radius = float(np.median(np.linalg.norm(local_iris[1:]-source,axis=1)))
        mask = np.zeros((ch,cw),np.uint8)
        cv2.fillPoly(mask,[np.round(local_contour).astype(np.int32)],255)
        interior = cv2.erode(mask,np.ones((3,3),np.uint8))
        gray = cv2.cvtColor(crop,cv2.COLOR_BGR2GRAY)
        yy,xx = np.mgrid[:ch,:cw].astype(np.float32)
        radial = np.hypot(xx-source[0],yy-source[1])
        # Boundary refinement uses only the visible aperture near the initial iris.
        gradient = cv2.magnitude(cv2.Sobel(gray,cv2.CV_32F,1,0),cv2.Sobel(gray,cv2.CV_32F,0,1))
        annulus = (radial > radius*.72)&(radial < radius*1.3)&(interior>0)
        edge = annulus & (gradient > percentile(gradient[annulus],65))
        edge_pts = np.column_stack([xx[edge],yy[edge]])
        fit_residual = None
        fit_disagreement = None
        if len(edge_pts) >= 8:
            # Fit a circle with a prior; reject eyelid-driven or implausible solutions.
            aa = np.column_stack([2*edge_pts,np.ones(len(edge_pts))])
            bb = np.sum(edge_pts**2,axis=1)
            fitted = np.linalg.lstsq(aa,bb,rcond=None)[0]
            rfit = math.sqrt(max(0,fitted[2]+np.dot(fitted[:2],fitted[:2])))
            residual = float(np.median(abs(np.linalg.norm(edge_pts-fitted[:2],axis=1)-rfit)))
            fit_residual = residual/scale
            fit_disagreement = float(np.linalg.norm(fitted[:2]-source))/scale
            if np.linalg.norm(fitted[:2]-source)<radius*.18 and .8*radius<rfit<1.2*radius and residual<radius*.16:
                source = (source*.75 + fitted[:2]*.25).astype(np.float32)
                radius = radius*.8+rfit*.2
        iris_region = (np.hypot(xx-source[0],yy-source[1])<radius)&(interior>0)
        pupil_region = iris_region & (np.hypot(xx-source[0],yy-source[1])<radius*.65)
        dark = pupil_region & (gray < percentile(gray[pupil_region],28))
        pupil = None
        pupil_contour = None
        if dark.sum() >= 3:
            num,labels,stats,centroids = cv2.connectedComponentsWithStats(dark.astype(np.uint8))
            if num>1:
                j=1+int(np.argmax(stats[1:,cv2.CC_STAT_AREA]))
                if np.linalg.norm(centroids[j]-source)<radius*.4:
                    pupil=transform([centroids[j]],inv)[0].tolist()
                    pupil_edges,_=cv2.findContours((labels==j).astype(np.uint8),cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
                    if pupil_edges:
                        pupil_contour=transform(max(pupil_edges,key=cv2.contourArea)[:,0],inv).tolist()
        height = float(np.ptp(local_contour[:,1]))/scale
        openness = height/width
        visible = float(iris_region.sum()/max(math.pi*radius*radius,1))
        sharpness = float(cv2.Laplacian(gray,cv2.CV_32F)[interior>0].var()) if interior.any() else 0
        highlight = ((gray>235)&(cv2.cvtColor(crop,cv2.COLOR_BGR2HSV)[:,:,1]<65)&(mask>0)).astype(np.uint8)
        # Dim recordings still contain compact bright glints inside a dark iris.
        bright_detail=gray.astype(np.float32)-cv2.GaussianBlur(gray.astype(np.float32),(0,0),1.2)
        compact=(bright_detail>18)&(gray>percentile(gray[iris_region],50)+35)&iris_region
        count,labels,stats,_=cv2.connectedComponentsWithStats(compact.astype(np.uint8))
        for j in range(1,count):
            if 1<=stats[j,cv2.CC_STAT_AREA]<=max(4,math.pi*radius*radius*.12):
                highlight[labels==j]=1
        highlight = cv2.dilate(highlight,np.ones((2,2),np.uint8))
        reflection = float(highlight.sum()/max(1,(mask>0).sum()))
        # Long dark edges through the aperture can indicate a glasses frame or obstruction.
        edges=cv2.Canny(gray,45,100)&interior
        lines=cv2.HoughLinesP(edges,1,np.pi/180,max(8,int(width*scale*.4)),minLineLength=width*scale*.65,maxLineGap=2)
        line_occlusion=0.
        occlusion_mask=np.zeros_like(mask)
        if lines is not None:
            for line in lines[:,0]:
                a,b=line[:2].astype(float),line[2:].astype(float)
                direction=b-a
                offset=source-a
                d=abs(direction[0]*offset[1]-direction[1]*offset[0])/max(np.linalg.norm(direction),1)
                if d<radius*.45:
                    line_occlusion=max(line_occlusion,min(1,float(np.linalg.norm(direction)/(width*scale))))
                    cv2.line(occlusion_mask,tuple(a.astype(int)),tuple(b.astype(int)),255,2)
        contrast = percentile(gray[interior>0],85)-percentile(gray[interior>0],15)
        q = float(np.clip(min(1,width/28)*min(1,sharpness/70)*min(1,contrast/45)*(1-min(.7,reflection*2)),0,1))
        boundary_quality = .85 if fit_residual is None else 1/(1+(fit_residual/max(radius/scale*.2,.1))**2)
        agreement_quality = .85 if fit_disagreement is None else 1/(1+(fit_disagreement/max(radius/scale*.4,.1))**2)
        q *= (.75+.25*boundary_quality)*(.75+.25*agreement_quality)*min(1,visible/.7)
        blink = blend.get('eyeBlinkRight' if name=='left' else 'eyeBlinkLeft',0)
        reason = 'ok'
        if openness<.105 or blink>.58 or visible<.23: reason='blink'
        elif width<18: reason='eye-too-small'
        elif q<.32: reason='uncertain-eye'
        elif line_occlusion>.7: reason='suspected-occlusion'
        elif np.any(contour<0) or np.any(contour[:,0]>=image.shape[1]) or np.any(contour[:,1]>=image.shape[0]): reason='eye-outside-frame'
        elif pose is None or max(abs(pose['angles'][0]),abs(pose['angles'][1]))>42: reason='head-angle'
        # Camera-directed rotation relative to the head-forward iris position.
        target = np.array([center[0],center[1]],np.float32)
        target += v*(float(np.mean(local_contour[:,1]))-ch*7/12)/scale
        if pose is not None:
            rot=np.array(pose['rotation']); t=np.array(pose['translation']); k=np.array(pose['matrix'])
            ocular=np.array([-29 if name=='left' else 29,-32,29.])
            e=rot@ocular+t
            facing=e-12*e/np.linalg.norm(e)
            neutral=e+rot@np.array([0.,0.,-12.])
            def project(p):
                z=k@p
                return z[:2]/z[2]
            delta=project(facing)-project(neutral)
            target += np.clip(delta,-width*.16,width*.16)
        geometric_target=target.copy()
        target=self.stabilize_target(name,target,center,basis,width,dt,reason=='ok')
        raw_target=target.copy()
        signature=self.signature
        calibrated=self.calibration.offset(name,pose['angles'] if pose else [0,0,0],signature,radius/(scale*width))
        target += basis.T@calibrated*width
        iris_pixel=transform([source],inv)[0]
        local_target=transform([target],matrix)[0]
        # Conservative shift, especially vertically; strength changes geometry, not opacity.
        shift=local_target-source
        shift[0]=np.clip(shift[0],-width*scale*.42,width*scale*.42)
        shift[1]=np.clip(shift[1],-height*scale*.55,height*scale*.55)
        desired_strength=self.strength*min(1,q/.55)
        previous=self.slow.get(name,{}).get('strength',desired_strength)
        amount=previous+(desired_strength-previous)*(1-math.exp(-dt/.1))
        if reason!='ok': amount=0
        previous_radius=self.slow.get(name,{}).get('radiusRatio',radius/(scale*width))
        ratio=radius/(scale*width)
        if reason=='ok' and abs(ratio-previous_radius)<.035:
            ratio=previous_radius+(ratio-previous_radius)*(1-math.exp(-dt/.15))
            radius=ratio*scale*width
        self.slow[name]={'strength':amount,'radiusRatio':ratio}
        target=transform([source+shift*amount],inv)[0]
        return {'contour':contour.tolist(),'iris':iris_pixel.tolist(),'irisContour':points[spec['iris'][1:]].tolist(),
                'pupil':pupil,'pupilContour':pupil_contour,'radius':radius/scale,'width':width,'openness':openness,'blinkScore':float(blink),
                'visibleIrisFraction':visible,'quality':q,'qualityType':'heuristic', 'reason':reason,
                'sharpness':sharpness,'reflectionFraction':reflection,'lineOcclusionScore':line_occlusion,'fitResidualPixels':fit_residual,
                'boundaryDisagreementPixels':fit_disagreement,
                'masks':{'space':'normalized-eye-roi','type':'geometric-and-photometric-estimates',
                         'aperture':mask_record(mask),'visibleIris':mask_record(iris_region),
                         'sclera':mask_record((interior>0)&~iris_region),
                         'reflections':mask_record(highlight),'suspectedOcclusion':mask_record(occlusion_mask&mask)},
                'targetGeometric':geometric_target.tolist(),
                'targetUncalibrated':raw_target.tolist(),'target':target.tolist(),'basis':basis.tolist(),
                'roiTransform':matrix.tolist(),'roiSize':[cw,ch],'strength':amount,
                '_crop':crop,'_mask':mask,'_highlight':highlight,'_source':source,
                '_target':transform([target],matrix)[0],'_radius':radius,
                '_anchors':transform(points[spec['anchors']],matrix)}

    def analyze(self,image,frame_id,timestamp,command=None):
        h,w=image.shape[:2]
        if not math.isfinite(timestamp) or timestamp<0: raise ValueError('Invalid timestamp')
        if self.last_timestamp is not None and timestamp<=self.last_timestamp:
            raise ValueError('Frames must have strictly increasing capture timestamps')
        dt=timestamp-self.last_timestamp if self.last_timestamp is not None else 1/30
        if dt>.25: self.reset_history()
        self.last_timestamp=timestamp
        self.signature={'context':self.context,'width':w,'height':h,'orientation':'top-left-unmirrored',
                        'intrinsics':self.intrinsics,'targetModel':'full-face-camera-v3','detector':self.mode}
        if command: self.calibration.command(command,timestamp)
        mp_image=mp.Image(image_format=mp.ImageFormat.SRGB,data=cv2.cvtColor(image,cv2.COLOR_BGR2RGB))
        ms=max(self.last_ms+1,int(round(timestamp*1000)))
        self.last_ms=ms
        result=self.detector.detect(mp_image) if self.mode=='image' else self.detector.detect_for_video(mp_image,ms)
        record={'schemaVersion':2,'frameID':frame_id,'timestamp':timestamp,'width':w,'height':h,'dt':dt,
                'coordinates':'source-pixels-top-left-unmirrored','eyes':{},'pose':None,'status':'no-face'}
        if not result.face_landmarks:
            self.reset_history()
            self.calibration.observe(record,self.signature)
            record['calibration']=self.calibration.status
            self.last_record=record
            return record
        points=np.array([[p.x*w,p.y*h] for p in result.face_landmarks[0]],np.float32)
        bounds=[*points.min(axis=0),*np.ptp(points,axis=0)]
        if self.last_record and 'faceBounds' in self.last_record:
            old=np.array(self.last_record['faceBounds'])
            if np.linalg.norm(np.array(bounds[:2])-old[:2])>max(bounds[2:])*.45:
                self.reset_history()
        face_matrix=np.asarray(result.facial_transformation_matrixes[0]).tolist() if result.facial_transformation_matrixes else None
        pose=self.pose(points,w,h,dt,face_matrix)
        record.update(faceBounds=[float(x) for x in bounds],pose=pose,status='tracked',
                      faceMatrix=face_matrix)
        blend={b.category_name:b.score for b in result.face_blendshapes[0]} if result.face_blendshapes else {}
        for name in EYES:
            eye=self.eye(image,points,name,pose,blend,dt)
            if eye: record['eyes'][name]=eye
        # Binocular safety: avoid an asymmetric artificial gaze when one eye is uncertain.
        if len(record['eyes'])<2 or any(e['reason']!='ok' for e in record['eyes'].values()):
            for e in record['eyes'].values():
                if e['reason']=='ok': e['reason']='paired-eye-uncertain'
            self.targets.clear()
        public=self.public(record)
        if pose: self.calibration.observe(public,self.signature)
        record['calibration']=self.calibration.status
        self.last_record=public
        return record

    @staticmethod
    def public(record):
        return {k:({n:{a:b for a,b in e.items() if not a.startswith('_')} for n,e in v.items()} if k=='eyes' else v)
                for k,v in record.items()}

    def render_eye(self,image,out,e,name,dt):
        if e['reason']!='ok' or e['strength']<=0:
            self.history.pop(name,None)
            e['rendered']=False
            return
        crop=e['_crop']; mask=e['_mask']; source=e['_source']; target=e['_target']
        h,w=crop.shape[:2]
        yy,xx=np.mgrid[:h,:w].astype(np.float32)
        distance=cv2.distanceTransform(mask,cv2.DIST_L2,3)
        alpha=np.clip((distance-.4)/max(1.2,e['_radius']*.25),0,1)
        desired=target-source
        if np.linalg.norm(desired)<.2:
            self.history.pop(name,None)
            e['rendered']=False; e['renderReason']='already-on-target'; return
        # Inverse local warp; eye corners stay fixed and the iris interior stays rigid.
        rad=e['_radius']
        left=np.full(h,source[0]-e['width']*.5*(w/(e['width']*1.5)),np.float32)
        right=np.full(h,source[0]+e['width']*.5*(w/(e['width']*1.5)),np.float32)
        for row in range(h):
            xs=np.flatnonzero(mask[row])
            if len(xs): left[row]=xs[0];right[row]=xs[-1]
        mx=xx.copy();my=yy.copy()
        for row in range(h):
            lo,hi=left[row],right[row]
            a=float(np.clip(target[0]-rad,lo+.5,hi-1)); b=float(np.clip(target[0]+rad,a+.25,hi-.25))
            sa=float(np.clip(source[0]-rad,lo,hi)); sb=float(np.clip(source[0]+rad,sa,hi))
            if hi-lo>2: mx[row]=np.interp(xx[row],[lo,a,b,hi],[lo,sa,sb,hi])
        support=np.clip(distance/max(rad*.45,1),0,1)
        my=yy-desired[1]*support
        engine='geometry'
        light=None
        if self.neural is not None and (self.engine=='neural' or rad*.12<np.linalg.norm(desired)<rad*.65):
            response=self.neural.field(crop,e['_anchors'],name,desired,source)
            if response:
                nx,ny,light,meta=response
                e['neural']=meta
                if meta['responseErrorPixels']<max(rad*.12,.6):
                    mx,my=nx,ny; engine='neural'
        # Remove tiny specular points before warping; put their original lighting back.
        highlights=e['_highlight']
        clean=cv2.inpaint(crop,highlights,2,cv2.INPAINT_TELEA) if highlights.any() else crop
        warped=cv2.remap(clean,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REFLECT_101)
        sampled_mask=cv2.remap(mask,mx,my,cv2.INTER_NEAREST,borderMode=cv2.BORDER_CONSTANT)
        holes=((sampled_mask==0)&(alpha>.1)).astype(np.uint8)*255
        if holes.any():
            warped=cv2.inpaint(warped,holes,max(2,rad*.3),cv2.INPAINT_TELEA)
        generated=linear(warped)
        original=linear(crop)
        reconstructed=self.synthesize_eye(clean,mask,source,target,rad)
        if engine=='neural':
            # A displacement match alone cannot detect misshapen or duplicated irises.
            target_distance=np.hypot(xx-target[0],yy-target[1])
            source_distance=np.hypot(xx-source[0],yy-source[1])
            src_gray=cv2.cvtColor(crop,cv2.COLOR_BGR2GRAY)
            gen_gray=cv2.cvtColor(warped,cv2.COLOR_BGR2GRAY)
            iris_samples=src_gray[(source_distance<rad*.65)&(mask>0)]
            sclera_samples=src_gray[(source_distance>rad*1.2)&(alpha>.6)]
            threshold=(percentile(iris_samples,65)+percentile(sclera_samples,65))*.5
            dark=(gen_gray<threshold)&(alpha>.65)
            area=int(dark.sum())
            inside=dark&(target_distance<rad*1.2)
            centroid=np.array([xx[inside].mean(),yy[inside].mean()]) if inside.any() else np.array([-999.,-999.])
            spill=float((dark&(target_distance>rad*1.3)).sum()/max(1,area))
            error=float(np.linalg.norm(centroid-target))
            valid=spill<.08 and error<max(.5,rad*.075) and inside.sum()>math.pi*rad*rad*.38
            e['neural'].update(photometricAccepted=bool(valid),darkSpillFraction=spill,centerErrorPixels=error)
            if valid:
                # Keep the reconstructed sclera and boundary lighting; use the model only inside the iris.
                neural_mask=np.clip((rad-target_distance)/max(.8,rad*.15),0,1)[:,:,None]
                generated=reconstructed*(1-neural_mask)+generated*neural_mask
            else:
                engine='geometry'
                generated=reconstructed
        else:
            generated=reconstructed
        if light is not None and engine=='neural':
            # Learned relighting is bounded; retain native texture and local contrast.
            lift=np.clip(light[:,:,1:2],0,.06)
            generated=np.clip(generated+lift*(1-generated)*.35,0,1)
        # Only reuse aligned low-frequency sclera residuals; never old iris imagery.
        iris_destination=np.hypot(xx-target[0],yy-target[1])<rad*1.4
        sclera=(alpha>.7)&~iris_destination&(highlights==0)
        temporal_pixels=0
        if name in self.history:
            prev=self.history[name]
            if prev['crop'].shape==crop.shape and np.linalg.norm(prev['target']-target)<rad*.6 and dt<.15:
                gray=cv2.cvtColor(crop,cv2.COLOR_BGR2GRAY)
                oldgray=cv2.cvtColor(prev['crop'],cv2.COLOR_BGR2GRAY)
                back=cv2.calcOpticalFlowFarneback(gray,oldgray,None,.5,2,9,2,5,1.1,0)
                forward=cv2.calcOpticalFlowFarneback(oldgray,gray,None,.5,2,9,2,5,1.1,0)
                bx=xx+back[:,:,0];by=yy+back[:,:,1]
                f=cv2.remap(forward,bx,by,cv2.INTER_LINEAR)
                good=(np.linalg.norm(back+f,axis=2)<.8)&sclera
                oldimage=cv2.remap(prev['crop'],bx,by,cv2.INTER_LINEAR)
                good &= np.mean(abs(oldimage.astype(float)-crop),axis=2)<12
                oldres=cv2.remap(prev['residual'],bx,by,cv2.INTER_LINEAR)
                residual=generated-original
                low=cv2.GaussianBlur(residual,(0,0),1)
                generated += (oldres-low)*good[:,:,None]*.2
                temporal_pixels=int(good.sum())
        self.history[name]={'crop':crop.copy(),'target':target.copy(),
                            'residual':cv2.GaussianBlur(generated-original,(0,0),1)}
        # Restore the positive specular layer at its observed position. Copying
        # whole highlighted source pixels would also retain the old dark iris
        # around a glint, leaving dark holes in newly exposed sclera.
        specular=np.maximum(original-linear(clean),0)*np.clip(highlights[:,:,None],0,1)
        generated+=specular
        generated=np.clip(generated,0,1)
        matrix=np.array(e['roiTransform'],np.float32)
        inv=cv2.invertAffineTransform(matrix)
        points=transform([[0,0],[w,0],[w,h],[0,h]],inv)
        ih,iw=image.shape[:2]
        x0,y0=np.maximum(np.floor(points.min(axis=0)).astype(int),0)
        x1,y1=np.minimum(np.ceil(points.max(axis=0)).astype(int),[iw,ih])
        if x1<=x0 or y1<=y0: return
        inv[:,2]-=[x0,y0]
        a=cv2.warpAffine(alpha,inv,(x1-x0,y1-y0),flags=cv2.INTER_LINEAR)
        # Premultiply before resampling so alpha edges cannot darken.
        premult=cv2.warpAffine(generated*alpha[:,:,None],inv,(x1-x0,y1-y0),flags=cv2.INTER_LINEAR)
        # Hard aperture clipping after reprojection keeps surrounding skin unchanged.
        aperture=np.zeros((y1-y0,x1-x0),np.uint8)
        cv2.fillPoly(aperture,[np.round(np.array(e['contour'])-[x0,y0]).astype(np.int32)],1)
        a*=aperture
        premult*=aperture[:,:,None]
        out[y0:y1,x0:x1]=encoded(linear(out[y0:y1,x0:x1])*(1-a[:,:,None])+premult)
        e.update(rendered=True,renderEngine=engine,changedPixels=int((a>.05).sum()),
                 disocclusionPixels=int((holes>0).sum()),temporalPixels=temporal_pixels)

    @staticmethod
    def synthesize_eye(crop,mask,source,target,radius):
        """Rotate/reproject the visible iris texture; fill only newly exposed sclera.

        The sclera surface is fitted from this frame's visible sclera in linear
        light. Missing iris samples use the opposite visible part of the same
        iris, never skin beyond the eyelid. This is source-based reconstruction,
        not a claim of recovering unobserved anatomical detail.
        """
        h,w=crop.shape[:2]
        yy,xx=np.mgrid[:h,:w].astype(np.float32)
        src_dist=np.hypot(xx-source[0],yy-source[1])
        dst_dist=np.hypot(xx-target[0],yy-target[1])
        src=linear(crop)
        gray=cv2.cvtColor(crop,cv2.COLOR_BGR2GRAY)
        inside=cv2.erode(mask,np.ones((3,3),np.uint8))>0
        visible_sclera=inside&(src_dist>radius*1.15)
        if visible_sclera.sum()<8: return src
        visible_sclera &= gray>percentile(gray[visible_sclera],35)
        # Low-order illumination field, with regularization to prevent extrapolation ringing.
        x=(xx-source[0])/w; y=(yy-source[1])/h
        features=np.stack([np.ones_like(x),x,y,x*x,x*y,y*y],-1)
        a=features[visible_sclera]; values=src[visible_sclera]
        regularizer=np.diag([.001,.05,.05,.2,.2,.2])
        coeff=np.linalg.solve(a.T@a+regularizer,a.T@values)
        surface=features@coeff
        surface=np.clip(surface,np.percentile(values,10,axis=0)*.88,np.percentile(values,90,axis=0)*1.04)
        # Preserve measured texture residuals using the nearest observed sclera sample.
        _,labels=cv2.distanceTransformWithLabels((~visible_sclera).astype(np.uint8),cv2.DIST_L2,5,labelType=cv2.DIST_LABEL_PIXEL)
        residual=values-(features[visible_sclera]@coeff)
        texture=residual[np.clip(labels-1,0,len(residual)-1)]
        surface=np.clip(surface+cv2.GaussianBlur(texture,(0,0),.6)*.35,0,1)
        aperture_distance=cv2.distanceTransform(mask,cv2.DIST_L2,3)
        shade=.58+.42*np.clip(aperture_distance/max(radius*.8,1),0,1)**.6
        reference_shade=float(np.median(shade[visible_sclera]))
        surface*=np.clip(shade/max(reference_shade,.5),.6,1.05)[:,:,None]
        erase=np.clip((radius*1.18-src_dist)/max(.8,radius*.16),0,1)*(mask>0)
        base=src*(1-erase[:,:,None])+surface*erase[:,:,None]
        mx=(xx-target[0]+source[0]).astype(np.float32)
        my=(yy-target[1]+source[1]).astype(np.float32)
        iris=cv2.remap(src,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REFLECT_101)
        valid=cv2.remap(inside.astype(np.uint8),mx,my,cv2.INTER_NEAREST)>0
        opposite_x=2*source[0]-mx; opposite_y=2*source[1]-my
        opposite=cv2.remap(src,opposite_x,opposite_y,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REFLECT_101)
        opposite_valid=cv2.remap(inside.astype(np.uint8),opposite_x,opposite_y,cv2.INTER_NEAREST)>0
        iris=np.where((~valid&opposite_valid)[:,:,None],opposite,iris)
        visible_iris=inside&(src_dist<radius*.85)
        if visible_iris.any():
            iris=np.where((~valid&~opposite_valid)[:,:,None],np.median(src[visible_iris],axis=0),iris)
        iris_alpha=np.clip((radius*1.04-dst_dist)/max(.65,radius*.12),0,1)
        return base*(1-iris_alpha[:,:,None])+iris*iris_alpha[:,:,None]

    def process(self,image,frame_id,timestamp,command=None,render_mode='effect'):
        start=time.perf_counter()
        record=self.analyze(image,frame_id,timestamp,command)
        analyzed=time.perf_counter()
        out=image.copy()
        dt=1/30 if frame_id==0 else record.get('dt',1/30)
        for name,e in record['eyes'].items(): self.render_eye(image,out,e,name,dt)
        record['processingMS']=(time.perf_counter()-start)*1000
        record['analysisMS']=(analyzed-start)*1000
        record['providers']=self.neural.providers if self.neural else []
        public=self.public(record)
        if render_mode!='effect': out=self.debug(image,public,render_mode)
        return out,public

    @staticmethod
    def debug(image,record,mode='debug'):
        out=image.copy()
        for name,e in record['eyes'].items():
            contour=np.round(e['contour']).astype(np.int32)
            if mode.startswith('white-eyes'):
                cv2.fillPoly(out,[contour],(255,255,255))
            else:
                cv2.polylines(out,[contour],True,(30,220,70) if e['reason']=='ok' else (0,160,255),1,cv2.LINE_AA)
                cv2.circle(out,tuple(np.round(e['iris']).astype(int)),max(1,int(e['radius'])),(0,200,255),1,cv2.LINE_AA)
            if mode!='white-eyes':
                p=tuple(np.round(e['target']).astype(int))
                cv2.circle(out,p,2,(0,0,255),-1,cv2.LINE_AA)
        if mode=='debug':
            lines=[f"Frame {record['frameID']} / {record['timestamp']:.3f}s | {record['status']}",record.get('calibration','automatic')]
            lines += [f"{n}: {e['reason']} q={e['quality']:.2f} {e.get('renderEngine','pass')}" for n,e in record['eyes'].items()]
            for i,s in enumerate(lines):
                cv2.putText(out,s,(16,28+i*24),cv2.FONT_HERSHEY_SIMPLEX,.55,(255,255,255),1,cv2.LINE_AA)
        return out
