#!/bin/sh
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m venv "${ROOT_DIR}/.venv"
"${ROOT_DIR}/.venv/bin/python3" -m pip install -r "${ROOT_DIR}/requirements-lock.txt"
"${ROOT_DIR}/.venv/bin/python3" "${ROOT_DIR}/scripts/setup-models.py"
"${ROOT_DIR}/.venv/bin/python3" -c 'import cv2,mediapipe,numpy,onnxruntime; print("Gaze Effect runtime imports passed")'
