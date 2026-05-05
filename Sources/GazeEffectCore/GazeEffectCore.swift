import CoreGraphics
import Foundation

public struct EyeContactConfiguration: Sendable {
    public var blinkAspectRatioThreshold: CGFloat
    public var maxShiftAsEyeWidth: CGFloat
    public var smoothingAlpha: CGFloat
    public var minConfidence: CGFloat

    public init(
        blinkAspectRatioThreshold: CGFloat = 0.12,
        maxShiftAsEyeWidth: CGFloat = 0.16,
        smoothingAlpha: CGFloat = 0.35,
        minConfidence: CGFloat = 0.35
    ) {
        self.blinkAspectRatioThreshold = blinkAspectRatioThreshold
        self.maxShiftAsEyeWidth = maxShiftAsEyeWidth
        self.smoothingAlpha = smoothingAlpha
        self.minConfidence = minConfidence
    }
}

public struct EyeLandmarks: Sendable, Equatable {
    public var contour: [CGPoint]
    public var pupil: CGPoint?

    public init(contour: [CGPoint], pupil: CGPoint?) {
        self.contour = contour
        self.pupil = pupil
    }
}

public struct FaceLandmarks: Sendable, Equatable {
    public var leftEye: EyeLandmarks
    public var rightEye: EyeLandmarks
    public var faceBounds: CGRect
    public var confidence: CGFloat

    public init(leftEye: EyeLandmarks, rightEye: EyeLandmarks, faceBounds: CGRect, confidence: CGFloat) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.faceBounds = faceBounds
        self.confidence = confidence
    }
}

public struct EyeCorrection: Sendable, Equatable {
    public var sourcePupil: CGPoint
    public var targetPupil: CGPoint
    public var delta: CGVector
    public var eyeBounds: CGRect
    public var confidence: CGFloat
    public var isBlinking: Bool

    public init(
        sourcePupil: CGPoint,
        targetPupil: CGPoint,
        delta: CGVector,
        eyeBounds: CGRect,
        confidence: CGFloat,
        isBlinking: Bool
    ) {
        self.sourcePupil = sourcePupil
        self.targetPupil = targetPupil
        self.delta = delta
        self.eyeBounds = eyeBounds
        self.confidence = confidence
        self.isBlinking = isBlinking
    }
}

public struct EyeContactResult: Sendable, Equatable {
    public var left: EyeCorrection?
    public var right: EyeCorrection?
    public var shouldRender: Bool {
        left != nil || right != nil
    }

    public init(left: EyeCorrection?, right: EyeCorrection?) {
        self.left = left
        self.right = right
    }
}

public struct EyeContactEstimator: Sendable {
    public var configuration: EyeContactConfiguration

    private var previousLeftTarget: CGPoint?
    private var previousRightTarget: CGPoint?

    public init(configuration: EyeContactConfiguration = EyeContactConfiguration()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        previousLeftTarget = nil
        previousRightTarget = nil
    }

    public mutating func estimate(from landmarks: FaceLandmarks) -> EyeContactResult {
        guard landmarks.confidence >= configuration.minConfidence else {
            reset()
            return EyeContactResult(left: nil, right: nil)
        }

        let left = correction(
            for: landmarks.leftEye,
            previousTarget: previousLeftTarget
        )
        let right = correction(
            for: landmarks.rightEye,
            previousTarget: previousRightTarget
        )

        previousLeftTarget = left?.targetPupil
        previousRightTarget = right?.targetPupil

        return EyeContactResult(left: left, right: right)
    }

    private func correction(for eye: EyeLandmarks, previousTarget: CGPoint?) -> EyeCorrection? {
        guard eye.contour.count >= 4 else {
            return nil
        }

        let bounds = eye.contour.boundingRect
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let aspectRatio = bounds.height / bounds.width
        let isBlinking = aspectRatio < configuration.blinkAspectRatioThreshold
        guard !isBlinking else {
            return nil
        }

        let sourcePupil = eye.pupil ?? eye.contour.centroid
        let rawTarget = eye.contour.centroid
        let target = smooth(current: rawTarget, previous: previousTarget, alpha: configuration.smoothingAlpha)

        let unclampedDelta = CGVector(dx: target.x - sourcePupil.x, dy: target.y - sourcePupil.y)
        let maxShift = max(0, bounds.width * configuration.maxShiftAsEyeWidth)
        let delta = unclampedDelta.clamped(maxLength: maxShift)
        let correctedTarget = CGPoint(x: sourcePupil.x + delta.dx, y: sourcePupil.y + delta.dy)
        let confidence = confidenceForCorrection(delta: delta, maxShift: maxShift, aspectRatio: aspectRatio)

        return EyeCorrection(
            sourcePupil: sourcePupil,
            targetPupil: correctedTarget,
            delta: delta,
            eyeBounds: bounds,
            confidence: confidence,
            isBlinking: false
        )
    }

    private func smooth(current: CGPoint, previous: CGPoint?, alpha: CGFloat) -> CGPoint {
        guard let previous else {
            return current
        }

        let clampedAlpha = min(max(alpha, 0), 1)
        return CGPoint(
            x: previous.x + (current.x - previous.x) * clampedAlpha,
            y: previous.y + (current.y - previous.y) * clampedAlpha
        )
    }

    private func confidenceForCorrection(delta: CGVector, maxShift: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        guard maxShift > 0 else {
            return 0
        }

        let shiftCost = min(delta.length / maxShift, 1)
        let blinkCost = min(max((0.18 - aspectRatio) / 0.18, 0), 1)
        return min(max(1 - shiftCost * 0.35 - blinkCost * 0.45, 0), 1)
    }
}

private extension Array where Element == CGPoint {
    var boundingRect: CGRect {
        guard let first else {
            return .null
        }

        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y

        for point in dropFirst() {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var centroid: CGPoint {
        guard !isEmpty else {
            return .zero
        }

        let sum = reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }

        let count = CGFloat(self.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }
}

private extension CGVector {
    var length: CGFloat {
        sqrt(dx * dx + dy * dy)
    }

    func clamped(maxLength: CGFloat) -> CGVector {
        guard maxLength > 0 else {
            return .zero
        }

        let currentLength = length
        guard currentLength > maxLength else {
            return self
        }

        let scale = maxLength / currentLength
        return CGVector(dx: dx * scale, dy: dy * scale)
    }
}
