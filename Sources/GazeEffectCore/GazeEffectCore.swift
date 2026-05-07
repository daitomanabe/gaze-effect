import CoreGraphics
import Foundation

public struct EyeContactConfiguration: Sendable {
    public var blinkAspectRatioThreshold: CGFloat
    public var maxShiftAsEyeWidth: CGFloat
    public var maxHorizontalShiftAsEyeWidth: CGFloat
    public var maxVerticalShiftAsEyeHeight: CGFloat
    public var targetVerticalBiasAsEyeHeight: CGFloat
    public var smoothingAlpha: CGFloat
    public var pupilSmoothingAlpha: CGFloat
    public var minConfidence: CGFloat

    public init(
        blinkAspectRatioThreshold: CGFloat = 0.12,
        maxShiftAsEyeWidth: CGFloat = 0.28,
        maxHorizontalShiftAsEyeWidth: CGFloat? = nil,
        maxVerticalShiftAsEyeHeight: CGFloat = 0.18,
        targetVerticalBiasAsEyeHeight: CGFloat = 0.03,
        smoothingAlpha: CGFloat = 1.0,
        pupilSmoothingAlpha: CGFloat = 1.0,
        minConfidence: CGFloat = 0.35
    ) {
        self.blinkAspectRatioThreshold = blinkAspectRatioThreshold
        self.maxShiftAsEyeWidth = maxShiftAsEyeWidth
        self.maxHorizontalShiftAsEyeWidth = maxHorizontalShiftAsEyeWidth ?? maxShiftAsEyeWidth
        self.maxVerticalShiftAsEyeHeight = maxVerticalShiftAsEyeHeight
        self.targetVerticalBiasAsEyeHeight = targetVerticalBiasAsEyeHeight
        self.smoothingAlpha = smoothingAlpha
        self.pupilSmoothingAlpha = pupilSmoothingAlpha
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

    private var previousLeftPupil: CGPoint?
    private var previousRightPupil: CGPoint?
    private var previousLeftDelta: CGVector?
    private var previousRightDelta: CGVector?

    public init(configuration: EyeContactConfiguration = EyeContactConfiguration()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        previousLeftPupil = nil
        previousRightPupil = nil
        previousLeftDelta = nil
        previousRightDelta = nil
    }

    public mutating func estimate(from landmarks: FaceLandmarks) -> EyeContactResult {
        guard landmarks.confidence >= configuration.minConfidence else {
            reset()
            return EyeContactResult(left: nil, right: nil)
        }

        let leftResult = correction(
            for: landmarks.leftEye,
            previousPupil: previousLeftPupil,
            previousDelta: previousLeftDelta
        )
        let rightResult = correction(
            for: landmarks.rightEye,
            previousPupil: previousRightPupil,
            previousDelta: previousRightDelta
        )

        let left = leftResult.correction
        let right = rightResult.correction
        previousLeftPupil = leftResult.smoothedPupil
        previousRightPupil = rightResult.smoothedPupil
        previousLeftDelta = left?.delta
        previousRightDelta = right?.delta

        return EyeContactResult(left: left, right: right)
    }

    private func correction(
        for eye: EyeLandmarks,
        previousPupil: CGPoint?,
        previousDelta: CGVector?
    ) -> InternalCorrectionResult {
        guard eye.contour.count >= 4 else {
            return InternalCorrectionResult(correction: nil, smoothedPupil: nil)
        }

        let bounds = eye.contour.boundingRect
        guard bounds.width > 0, bounds.height > 0 else {
            return InternalCorrectionResult(correction: nil, smoothedPupil: nil)
        }

        let aspectRatio = bounds.height / bounds.width
        let isBlinking = aspectRatio < configuration.blinkAspectRatioThreshold
        guard !isBlinking else {
            return InternalCorrectionResult(correction: nil, smoothedPupil: nil)
        }

        let measuredPupil = eye.pupil ?? eye.contour.centroid
        let sourcePupil = smooth(
            current: measuredPupil,
            previous: previousPupil,
            alpha: configuration.pupilSmoothingAlpha
        )
        let rawTarget = cameraFacingTarget(for: eye.contour, bounds: bounds)

        let unclampedDelta = CGVector(dx: rawTarget.x - sourcePupil.x, dy: rawTarget.y - sourcePupil.y)
        let maxDX = max(0, bounds.width * configuration.maxHorizontalShiftAsEyeWidth)
        let maxDY = max(0, bounds.height * configuration.maxVerticalShiftAsEyeHeight)
        let clampedDelta = unclampedDelta.clamped(maxDX: maxDX, maxDY: maxDY)
        let delta = smooth(current: clampedDelta, previous: previousDelta, alpha: configuration.smoothingAlpha)
        let correctedTarget = CGPoint(x: sourcePupil.x + delta.dx, y: sourcePupil.y + delta.dy)
        let confidence = confidenceForCorrection(delta: delta, maxDX: maxDX, maxDY: maxDY, aspectRatio: aspectRatio)

        let correction = EyeCorrection(
            sourcePupil: sourcePupil,
            targetPupil: correctedTarget,
            delta: delta,
            eyeBounds: bounds,
            confidence: confidence,
            isBlinking: false
        )
        return InternalCorrectionResult(correction: correction, smoothedPupil: sourcePupil)
    }

    private func cameraFacingTarget(for contour: [CGPoint], bounds: CGRect) -> CGPoint {
        let sortedByY = contour.sorted { $0.y < $1.y }
        let halfCount = max(1, sortedByY.count / 2)
        let upper = sortedByY.prefix(halfCount)
        let lower = sortedByY.suffix(halfCount)
        let upperY = upper.reduce(CGFloat.zero) { $0 + $1.y } / CGFloat(upper.count)
        let lowerY = lower.reduce(CGFloat.zero) { $0 + $1.y } / CGFloat(lower.count)
        let centerY = (upperY + lowerY) / 2

        return CGPoint(
            x: bounds.midX,
            y: centerY + bounds.height * configuration.targetVerticalBiasAsEyeHeight
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

    private func smooth(current: CGVector, previous: CGVector?, alpha: CGFloat) -> CGVector {
        guard let previous else {
            return current
        }

        let clampedAlpha = min(max(alpha, 0), 1)
        return CGVector(
            dx: previous.dx + (current.dx - previous.dx) * clampedAlpha,
            dy: previous.dy + (current.dy - previous.dy) * clampedAlpha
        )
    }

    private func confidenceForCorrection(delta: CGVector, maxDX: CGFloat, maxDY: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        guard maxDX > 0, maxDY > 0 else {
            return 0
        }

        let normalizedShift = sqrt((delta.dx / maxDX) * (delta.dx / maxDX) + (delta.dy / maxDY) * (delta.dy / maxDY))
        let shiftCost = min(normalizedShift, 1)
        let blinkCost = min(max((0.18 - aspectRatio) / 0.18, 0), 1)
        return min(max(1 - shiftCost * 0.35 - blinkCost * 0.45, 0), 1)
    }
}

private struct InternalCorrectionResult {
    var correction: EyeCorrection?
    var smoothedPupil: CGPoint?
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

    func clamped(maxDX: CGFloat, maxDY: CGFloat) -> CGVector {
        CGVector(
            dx: min(max(dx, -maxDX), maxDX),
            dy: min(max(dy, -maxDY), maxDY)
        )
    }
}
