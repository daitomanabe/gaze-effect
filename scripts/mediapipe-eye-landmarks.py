#!/usr/bin/env python3
"""Generate eye landmark sidecars for GazeEffectImageTool.

The realtime mode uses MediaPipe Face Landmarker iris points directly. The
offline mode keeps the same MediaPipe eye contour, then refines pupil centers
inside each eye ROI with a darker connected-component search.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.request
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks.python import vision


MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_landmarker/"
    "face_landmarker/float16/latest/face_landmarker.task"
)

# Screen-left and screen-right naming matches the Swift tool's current
# left/right convention after Vision's top-left coordinate conversion.
SCREEN_LEFT_EYE = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
SCREEN_RIGHT_EYE = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
SCREEN_LEFT_IRIS = [468, 469, 470, 471, 472]
SCREEN_RIGHT_IRIS = [473, 474, 475, 476, 477]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", help="Single input image")
    parser.add_argument("--output", help="Single output JSON")
    parser.add_argument("--input-dir", help="Directory of input frames")
    parser.add_argument("--output-dir", help="Directory for output JSON files")
    parser.add_argument("--mode", choices=["realtime", "offline"], default="realtime")
    parser.add_argument(
        "--model",
        default="Assets/models/face_landmarker.task",
        help="MediaPipe .task model path. Downloaded automatically when missing.",
    )
    parser.add_argument("--no-download", action="store_true", help="Do not download the MediaPipe model")
    args = parser.parse_args()

    if args.input_dir:
        if not args.output_dir:
            parser.error("--output-dir is required with --input-dir")
    else:
        if not args.input or not args.output:
            parser.error("--input and --output are required")
    return args


def ensure_model(path: Path, no_download: bool) -> None:
    if path.exists():
        return
    if no_download:
        raise FileNotFoundError(f"MediaPipe model not found: {path}")

    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading MediaPipe face landmarker model to {path}", file=sys.stderr)
    with urllib.request.urlopen(MODEL_URL) as response, path.open("wb") as handle:
        handle.write(response.read())


def point(landmarks, index: int) -> tuple[float, float]:
    lm = landmarks[index]
    return float(lm.x), float(lm.y)


def points(landmarks, indices: list[int]) -> list[list[float]]:
    return [[*point(landmarks, index)] for index in indices]


def center(landmarks, indices: list[int]) -> list[float]:
    raw = np.array([point(landmarks, index) for index in indices], dtype=np.float32)
    return [float(raw[:, 0].mean()), float(raw[:, 1].mean())]


def bounds_from_points(points_: list[list[float]]) -> list[float]:
    raw = np.array(points_, dtype=np.float32)
    min_xy = raw.min(axis=0)
    max_xy = raw.max(axis=0)
    return [
        float(min_xy[0]),
        float(min_xy[1]),
        float(max_xy[0] - min_xy[0]),
        float(max_xy[1] - min_xy[1]),
    ]


def expanded_roi(contour: list[list[float]], width: int, height: int, pad_x: float = 0.65, pad_y: float = 1.10):
    x, y, w, h = bounds_from_points(contour)
    px = max(3, int(w * width * pad_x))
    py = max(3, int(h * height * pad_y))
    x0 = max(0, int(math.floor(x * width)) - px)
    y0 = max(0, int(math.floor(y * height)) - py)
    x1 = min(width - 1, int(math.ceil((x + w) * width)) + px)
    y1 = min(height - 1, int(math.ceil((y + h) * height)) + py)
    return x0, y0, x1, y1


def refine_pupil_dark_blob(
    image_bgr: np.ndarray,
    contour: list[list[float]],
    initial: list[float],
) -> list[float]:
    height, width = image_bgr.shape[:2]
    x0, y0, x1, y1 = expanded_roi(contour, width, height)
    if x1 <= x0 or y1 <= y0:
        return initial

    roi = image_bgr[y0 : y1 + 1, x0 : x1 + 1]
    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    threshold = np.percentile(gray, 24)
    dark = (gray <= threshold).astype(np.uint8)

    # Keep candidates close to the MediaPipe iris estimate. This preserves fast
    # eye motion without temporal interpolation.
    cx = initial[0] * width - x0
    cy = initial[1] * height - y0
    yy, xx = np.mgrid[0 : dark.shape[0], 0 : dark.shape[1]]
    rx = max((x1 - x0 + 1) * 0.22, 1)
    ry = max((y1 - y0 + 1) * 0.30, 1)
    prior = (((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2) <= 1.0
    dark = (dark & prior.astype(np.uint8)).astype(np.uint8)

    count, labels, stats, centroids = cv2.connectedComponentsWithStats(dark, connectivity=8)
    if count <= 1:
        return initial

    best_score = -1.0
    best_center = None
    roi_area = max(1, dark.shape[0] * dark.shape[1])
    for label in range(1, count):
        area = int(stats[label, cv2.CC_STAT_AREA])
        if area < max(2, roi_area * 0.002) or area > roi_area * 0.18:
            continue
        center_x, center_y = centroids[label]
        dist = math.hypot(center_x - cx, center_y - cy)
        distance_score = 1.0 - min(dist / max(rx * 0.85, 1), 1.0)
        darkness = 1.0 - float(gray[labels == label].mean()) / 255.0
        area_score = 1.0 - min(abs(area - roi_area * 0.025) / max(roi_area * 0.025, 1), 1.0)
        score = darkness * 0.30 + distance_score * 0.55 + area_score * 0.15
        if score > best_score:
            best_score = score
            best_center = center_x, center_y

    if best_center is None or best_score < 0.48:
        return initial

    return [
        float((x0 + best_center[0]) / width),
        float((y0 + best_center[1]) / height),
    ]


def result_for_image(landmarker, image_path: Path, mode: str) -> dict:
    mp_image = mp.Image.create_from_file(str(image_path))
    result = landmarker.detect(mp_image)
    if not result.face_landmarks:
        raise RuntimeError(f"No face detected: {image_path}")

    landmarks = result.face_landmarks[0]
    left_contour = points(landmarks, SCREEN_LEFT_EYE)
    right_contour = points(landmarks, SCREEN_RIGHT_EYE)
    left_pupil = center(landmarks, SCREEN_LEFT_IRIS)
    right_pupil = center(landmarks, SCREEN_RIGHT_IRIS)

    if mode == "offline":
        image_bgr = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        if image_bgr is not None:
            left_pupil = refine_pupil_dark_blob(image_bgr, left_contour, left_pupil)
            right_pupil = refine_pupil_dark_blob(image_bgr, right_contour, right_pupil)

    all_points = left_contour + right_contour
    return {
        "source": "mediapipe-face-landmarker",
        "mode": mode,
        "confidence": 0.95,
        "faceBounds": bounds_from_points(all_points),
        "leftContour": left_contour,
        "leftPupil": left_pupil,
        "rightContour": right_contour,
        "rightPupil": right_pupil,
    }


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def image_files(path: Path) -> list[Path]:
    allowed = {".jpg", ".jpeg", ".png"}
    return sorted(item for item in path.iterdir() if item.suffix.lower() in allowed and not item.name.startswith("."))


def main() -> int:
    args = parse_args()
    model_path = Path(args.model)
    ensure_model(model_path, args.no_download)

    options = vision.FaceLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(model_path)),
        num_faces=1,
        output_face_blendshapes=False,
        output_facial_transformation_matrixes=False,
    )

    with vision.FaceLandmarker.create_from_options(options) as landmarker:
        if args.input_dir:
            input_dir = Path(args.input_dir)
            output_dir = Path(args.output_dir)
            processed = 0
            fallback = 0
            for image_path in image_files(input_dir):
                output_path = output_dir / f"{image_path.stem}.json"
                try:
                    write_json(output_path, result_for_image(landmarker, image_path, args.mode))
                    processed += 1
                except Exception as exc:  # noqa: BLE001 - CLI should report and continue.
                    print(f"fallback {image_path.name}: {exc}", file=sys.stderr)
                    fallback += 1
            print(f"processed={processed} fallback={fallback}")
        else:
            write_json(Path(args.output), result_for_image(landmarker, Path(args.input), args.mode))
            print(args.output)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
