# Third-party models

The application uses MediaPipe Face Landmarker, distributed by Google through the MediaPipe model repository. The Python packages remain external runtime dependencies.

The optional learned eye warp uses Hsu et al., "Look at Me! Correcting Eye Gaze in Live Video Communication" (2019), checkpoint source: https://github.com/chihfanhsu/gaze_correction . The BGR 48×64 model predicts inverse flow and relighting. These are learned warping models; they are not general eye-image generators.

ONNX model assets were converted by the coreml-eye-contact project. Pinned provenance and checksums are in `Assets/models/neural-manifest.json`. Only the model assets are used; that application's engine code is not included. The models are ignored by Git, installed locally by `scripts/setup-models.py`, and included in local developer app bundles.

The pretrained models and source data do not establish accuracy for all populations, lighting, eyewear, or head poses. Local benchmark results are documented separately.

## Original checkpoint license

Copyright 2019 Chih-Fan Hsu

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
