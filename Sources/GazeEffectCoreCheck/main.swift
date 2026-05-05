import CoreGraphics
import GazeEffectCore

@main
struct GazeEffectCoreCheck {
    static func main() {
        movesPupilTowardEyeCenter()
        clampsLargeCorrectionsToConfiguredLimit()
        suppressesCorrectionWhenBlinking()
        rejectsLowConfidenceFace()
        print("GazeEffectCoreCheck passed")
    }

    private static func movesPupilTowardEyeCenter() {
        var estimator = EyeContactEstimator()
        let result = estimator.estimate(
            from: FaceLandmarks(
                leftEye: eye(pupil: CGPoint(x: 0.2, y: 0.5)),
                rightEye: eye(pupil: CGPoint(x: 0.8, y: 0.5)),
                faceBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                confidence: 1
            )
        )

        precondition(result.left?.delta.dx ?? 0 > 0, "left pupil should move right")
        precondition(result.right?.delta.dx ?? 0 < 0, "right pupil should move left")
    }

    private static func clampsLargeCorrectionsToConfiguredLimit() {
        var estimator = EyeContactEstimator(
            configuration: EyeContactConfiguration(maxShiftAsEyeWidth: 0.1)
        )

        let result = estimator.estimate(
            from: FaceLandmarks(
                leftEye: eye(pupil: CGPoint(x: 0.0, y: 0.5)),
                rightEye: eye(pupil: CGPoint(x: 1.0, y: 0.5)),
                faceBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                confidence: 1
            )
        )

        precondition(abs(result.left?.delta.dx ?? 0) <= 0.1, "left correction should be clamped")
        precondition(abs(result.right?.delta.dx ?? 0) <= 0.1, "right correction should be clamped")
    }

    private static func suppressesCorrectionWhenBlinking() {
        var estimator = EyeContactEstimator()
        let result = estimator.estimate(
            from: FaceLandmarks(
                leftEye: EyeLandmarks(
                    contour: [
                        CGPoint(x: 0.1, y: 0.5),
                        CGPoint(x: 0.5, y: 0.51),
                        CGPoint(x: 0.9, y: 0.5),
                        CGPoint(x: 0.5, y: 0.49)
                    ],
                    pupil: CGPoint(x: 0.25, y: 0.5)
                ),
                rightEye: eye(pupil: CGPoint(x: 0.75, y: 0.5)),
                faceBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                confidence: 1
            )
        )

        precondition(result.left == nil, "blinking eye should not be corrected")
        precondition(result.right != nil, "stable eye should still be corrected")
    }

    private static func rejectsLowConfidenceFace() {
        var estimator = EyeContactEstimator()
        let result = estimator.estimate(
            from: FaceLandmarks(
                leftEye: eye(pupil: CGPoint(x: 0.2, y: 0.5)),
                rightEye: eye(pupil: CGPoint(x: 0.8, y: 0.5)),
                faceBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                confidence: 0.1
            )
        )

        precondition(!result.shouldRender, "low confidence face should be pass-through")
    }

    private static func eye(pupil: CGPoint) -> EyeLandmarks {
        EyeLandmarks(
            contour: [
                CGPoint(x: 0.1, y: 0.5),
                CGPoint(x: 0.3, y: 0.35),
                CGPoint(x: 0.5, y: 0.32),
                CGPoint(x: 0.7, y: 0.35),
                CGPoint(x: 0.9, y: 0.5),
                CGPoint(x: 0.7, y: 0.65),
                CGPoint(x: 0.5, y: 0.68),
                CGPoint(x: 0.3, y: 0.65)
            ],
            pupil: pupil
        )
    }
}
