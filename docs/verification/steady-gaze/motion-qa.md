# Animation Video Analysis

- Input: `Assets/examples/video/steady-gaze/gaze-effect-steady-final.mp4`
- Mode/profile: `light` / `generic`
- Overall: **WARN**
- Technical integrity: **PASS**
- Motion presence: **PASS**
- Camera/local separation: **PASS**
- Temporal stability: **WARN**
- Intent conformance: **INCONCLUSIVE**
- Profile coverage: **PASS**
- Full-workflow coverage: **PASS**

## Observed motion

- Motion detected: `True`
- Primary direction: `up`
- Camera/local class: `local-dominant`
- Mean active area: `0.102355`
- Mean flow: `0.153 px/s`
- Unexpected freeze segments: `1`
- Exact repeated-pair ratio: `0.000000`

## Findings

- **WARN freeze_candidate** 5.542-6.333s: Low frame difference and high similarity persist. Confirm against intentional holds or cadence.

## Limitations

- Camera/global transforms are 2D candidates; they do not prove physical 3D camera motion.
- Classical analysis cannot identify semantic actions, identity drift, extra limbs, or object disappearance.
- No Expected Motion Spec or reference was supplied.
