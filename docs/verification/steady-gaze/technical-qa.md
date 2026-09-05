# Video Render QA

Generated: 2026-09-05T00:19:24.822616+00:00
Summary: 3 PASS / 0 WARN / 0 FAIL / 0 ERROR
Preset: `fast`; budget: 128px / 48 frames

## Assets/examples/video/steady-gaze/gaze-effect-steady-final.mp4

- Status: `PASS`
- Low-level elapsed: 0.500s
- Metadata: 1280x720, 24.000 fps, 15.070s, analyzed 48 frame(s)
- Checks:
  - `PASS` decode: Full stream decoded 361 frame(s); analyzed 48 sampled frame(s).
  - `PASS` motion: Motion detected with sparse flow proxy (mean=0.26px, active=0.17, tracked_pairs=1.00).
  - `PASS` exposure: Exposure is within expected technical range.
  - `PASS` color: Color variation is present.
  - `PASS` complexity: Frames contain sufficient structure.
  - `PASS` lighting: Broad lighting gradients and color separation are detectable.
- Next stage: `stop` — Low-level checks are decisive and no semantic question was supplied.
- Metrics:
  - motion: mean_flow_magnitude_px=0.2584, p90_flow_magnitude_px=0.8619, mean_active_vector_ratio=0.1713, mean_tracked_points=12.9787, flow_evaluated_pair_ratio=1.0000, tracked_pair_ratio=1.0000, mean_frame_delta=1.3581, repeated_pair_ratio=0.0000, frozen_pair_ratio=0.1702
  - exposure: mean_luma=91.8707, mean_luma_p05=6.4831, mean_luma_p95=156.4106, mean_luma_p99=184.9787, mean_luma_p999=193.3968, mean_dark_ratio=0.1373, mean_bright_ratio=0.0000, mean_clip_high_ratio=0.0000, mean_any_channel_clip_ratio=0.0000, mean_red_clip_ratio=0.0000, mean_green_clip_ratio=0.0000, mean_blue_clip_ratio=0.0000, mean_dynamic_range=149.9276
  - color: mean_saturation=0.3445, mean_channel_std=45.1809, mean_color_distance=23.4664
  - complexity: mean_edge_density=0.2527, mean_luma_entropy=4.2814
  - lighting: mean_coarse_dynamic_range=138.4583, mean_coarse_gradient=16.2595, mean_coarse_gradient_coverage=0.8095, mean_coarse_luma_bins=24.0000, mean_quantized_color_bins=167.1250

## Assets/examples/video/steady-gaze/gaze-effect-steady-final-comparison.mp4

- Status: `PASS`
- Low-level elapsed: 0.609s
- Metadata: 1280x720, 24.000 fps, 15.070s, analyzed 48 frame(s)
- Checks:
  - `PASS` decode: Full stream decoded 361 frame(s); analyzed 48 sampled frame(s).
  - `PASS` motion: Motion detected with sparse flow proxy (mean=0.58px, active=0.29, tracked_pairs=1.00).
  - `PASS` exposure: Exposure is within expected technical range.
  - `PASS` color: Color variation is present.
  - `PASS` complexity: Frames contain sufficient structure.
  - `PASS` lighting: Broad lighting gradients and color separation are detectable.
- Next stage: `stop` — Low-level checks are decisive and no semantic question was supplied.
- Metrics:
  - motion: mean_flow_magnitude_px=0.5813, p90_flow_magnitude_px=1.8656, mean_active_vector_ratio=0.2944, mean_tracked_points=27.3191, flow_evaluated_pair_ratio=1.0000, tracked_pair_ratio=1.0000, mean_frame_delta=4.9141, repeated_pair_ratio=0.0000, frozen_pair_ratio=0.0000
  - exposure: mean_luma=97.6741, mean_luma_p05=14.9829, mean_luma_p95=160.9368, mean_luma_p99=180.2346, mean_luma_p999=194.0690, mean_dark_ratio=0.1397, mean_bright_ratio=0.0000, mean_clip_high_ratio=0.0000, mean_any_channel_clip_ratio=0.0000, mean_red_clip_ratio=0.0000, mean_green_clip_ratio=0.0000, mean_blue_clip_ratio=0.0000, mean_dynamic_range=145.9539
  - color: mean_saturation=0.3172, mean_channel_std=47.9854, mean_color_distance=26.7096
  - complexity: mean_edge_density=0.3819, mean_luma_entropy=4.2989
  - lighting: mean_coarse_dynamic_range=135.1719, mean_coarse_gradient=24.6667, mean_coarse_gradient_coverage=0.9486, mean_coarse_luma_bins=22.6042, mean_quantized_color_bins=178.7083

## Assets/examples/video/steady-gaze/gaze-effect-steady-final-debug.mp4

- Status: `PASS`
- Low-level elapsed: 0.423s
- Metadata: 1280x720, 24.000 fps, 15.070s, analyzed 48 frame(s)
- Checks:
  - `PASS` decode: Full stream decoded 361 frame(s); analyzed 48 sampled frame(s).
  - `PASS` motion: Motion detected with sparse flow proxy (mean=0.22px, active=0.15, tracked_pairs=1.00).
  - `PASS` exposure: Exposure is within expected technical range.
  - `PASS` color: Color variation is present.
  - `PASS` complexity: Frames contain sufficient structure.
  - `PASS` lighting: Broad lighting gradients and color separation are detectable.
- Next stage: `stop` — Low-level checks are decisive and no semantic question was supplied.
- Metrics:
  - motion: mean_flow_magnitude_px=0.2236, p90_flow_magnitude_px=0.7671, mean_active_vector_ratio=0.1493, mean_tracked_points=14.9787, flow_evaluated_pair_ratio=1.0000, tracked_pair_ratio=1.0000, mean_frame_delta=1.3912, repeated_pair_ratio=0.0000, frozen_pair_ratio=0.1277
  - exposure: mean_luma=92.2423, mean_luma_p05=6.4832, mean_luma_p95=156.6879, mean_luma_p99=184.9831, mean_luma_p999=193.4491, mean_dark_ratio=0.1374, mean_bright_ratio=0.0000, mean_clip_high_ratio=0.0000, mean_any_channel_clip_ratio=0.0000, mean_red_clip_ratio=0.0000, mean_green_clip_ratio=0.0000, mean_blue_clip_ratio=0.0000, mean_dynamic_range=150.2046
  - color: mean_saturation=0.3433, mean_channel_std=45.3837, mean_color_distance=23.3968
  - complexity: mean_edge_density=0.2738, mean_luma_entropy=4.2880
  - lighting: mean_coarse_dynamic_range=138.4167, mean_coarse_gradient=16.3409, mean_coarse_gradient_coverage=0.8110, mean_coarse_luma_bins=24.0000, mean_quantized_color_bins=167.6458
