import AppKit
import CoreGraphics
import Foundation
import GazeEffectCore
import ImageIO
import UniformTypeIdentifiers
import Vision

private struct Options {
    var input: String?
    var output: String?
    var before: String?
    var metadata: String?
    var maxWidth: Int = 1000
    var strength: CGFloat = 2.0
    var verbose = false
}

private struct RGBAImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

private struct EyeRenderData {
    var contour: [CGPoint]
    var sourcePupil: CGPoint
    var targetPupil: CGPoint
}

private enum ToolError: LocalizedError {
    case missingArgument(String)
    case cannotLoadImage(String)
    case cannotCreateImage
    case noFace
    case noLandmarks
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let arg):
            return "Missing required argument: \(arg)"
        case .cannotLoadImage(let path):
            return "Could not load image: \(path)"
        case .cannotCreateImage:
            return "Could not create image buffer"
        case .noFace:
            return "No face detected"
        case .noLandmarks:
            return "No usable eye landmarks detected"
        case .cannotWrite(let path):
            return "Could not write image: \(path)"
        }
    }
}

private func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--input":
            options.input = args.removeFirst()
        case "--output":
            options.output = args.removeFirst()
        case "--before":
            options.before = args.removeFirst()
        case "--metadata":
            options.metadata = args.removeFirst()
        case "--max-width":
            options.maxWidth = Int(args.removeFirst()) ?? options.maxWidth
        case "--strength":
            options.strength = CGFloat(Double(args.removeFirst()) ?? Double(options.strength))
        case "--verbose":
            options.verbose = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw ToolError.missingArgument("unknown option \(arg)")
        }
    }

    guard options.input != nil else {
        throw ToolError.missingArgument("--input")
    }
    guard options.output != nil else {
        throw ToolError.missingArgument("--output")
    }

    return options
}

private func printUsage() {
    print("""
    Usage:
      GazeEffectImageTool --input source.jpg --output after.jpg [--before before.jpg] [--metadata data.json] [--max-width 1000] [--strength 2.0] [--verbose]
    """)
}

private func loadCGImage(path: String) throws -> CGImage {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw ToolError.cannotLoadImage(path)
    }
    return cgImage
}

private func resizeIfNeeded(_ image: CGImage, maxWidth: Int) throws -> CGImage {
    guard maxWidth > 0, image.width > maxWidth else {
        return image
    }

    let scale = CGFloat(maxWidth) / CGFloat(image.width)
    let width = maxWidth
    let height = max(1, Int(CGFloat(image.height) * scale))
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ToolError.cannotCreateImage
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let resized = context.makeImage() else {
        throw ToolError.cannotCreateImage
    }
    return resized
}

private func rgbaImage(from image: CGImage) throws -> RGBAImage {
    let width = image.width
    let height = image.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ToolError.cannotCreateImage
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RGBAImage(width: width, height: height, pixels: pixels)
}

private func makeCGImage(from image: RGBAImage) throws -> CGImage {
    let data = Data(image.pixels)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let provider = CGDataProvider(data: data as CFData),
          let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
          ) else {
        throw ToolError.cannotCreateImage
    }

    return cgImage
}

private func writeJPEG(_ image: CGImage, to path: String, quality: CGFloat = 0.92) throws {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ToolError.cannotWrite(path)
    }

    let options: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: quality
    ]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
        throw ToolError.cannotWrite(path)
    }
}

private func analyze(image: CGImage, rgba: RGBAImage, verbose: Bool) throws -> (EyeRenderData, EyeRenderData, CGRect) {
    var requestError: Error?
    var observations: [VNFaceObservation] = []

    let request = VNDetectFaceLandmarksRequest { request, error in
        requestError = error
        observations = request.results as? [VNFaceObservation] ?? []
    }

    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])

    if let requestError {
        throw requestError
    }

    guard let face = observations.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
        throw ToolError.noFace
    }
    guard let landmarks = face.landmarks,
          let leftEye = landmarks.leftEye,
          let rightEye = landmarks.rightEye else {
        throw ToolError.noLandmarks
    }

    let leftContour = normalizedPoints(leftEye, in: face)
    let rightContour = normalizedPoints(rightEye, in: face)
    let leftPupil = detectDarkPupil(contour: leftContour, in: rgba)
        ?? normalizedPupil(landmarks.leftPupil, in: face)
        ?? centroid(leftContour)
    let rightPupil = detectDarkPupil(contour: rightContour, in: rgba)
        ?? normalizedPupil(landmarks.rightPupil, in: face)
        ?? centroid(rightContour)

    var estimator = EyeContactEstimator(
        configuration: EyeContactConfiguration(
            blinkAspectRatioThreshold: 0.04,
            maxShiftAsEyeWidth: 0.24,
            smoothingAlpha: 1.0,
            minConfidence: 0.05
        )
    )

    let result = estimator.estimate(
        from: FaceLandmarks(
            leftEye: EyeLandmarks(contour: leftContour, pupil: leftPupil),
            rightEye: EyeLandmarks(contour: rightContour, pupil: rightPupil),
            faceBounds: topLeftRect(face.boundingBox),
            confidence: CGFloat(face.confidence)
        )
    )

    guard let leftCorrection = result.left, let rightCorrection = result.right else {
        throw ToolError.noLandmarks
    }

    if verbose {
        print("face confidence: \(face.confidence)")
        print("left delta: \(leftCorrection.delta.dx), \(leftCorrection.delta.dy)")
        print("right delta: \(rightCorrection.delta.dx), \(rightCorrection.delta.dy)")
    }

    return (
        EyeRenderData(contour: leftContour, sourcePupil: leftPupil, targetPupil: leftCorrection.targetPupil),
        EyeRenderData(contour: rightContour, sourcePupil: rightPupil, targetPupil: rightCorrection.targetPupil),
        topLeftRect(face.boundingBox)
    )
}

private func renderEffect(source: RGBAImage, left: EyeRenderData, right: EyeRenderData, strength: CGFloat) -> RGBAImage {
    var output = source
    applyEyeShift(eye: left, source: source, output: &output, strength: strength)
    applyEyeShift(eye: right, source: source, output: &output, strength: strength)
    reinforcePupil(eye: left, source: source, output: &output, strength: strength)
    reinforcePupil(eye: right, source: source, output: &output, strength: strength)
    return output
}

private func applyEyeShift(eye: EyeRenderData, source: RGBAImage, output: inout RGBAImage, strength: CGFloat) {
    let width = source.width
    let height = source.height

    let sourcePoint = pixelPoint(eye.sourcePupil, width: width, height: height)
    let targetPoint = pixelPoint(eye.targetPupil, width: width, height: height)
    let shiftX = (targetPoint.x - sourcePoint.x) * strength
    let shiftY = (targetPoint.y - sourcePoint.y) * strength

    guard hypot(shiftX, shiftY) >= 0.5 else {
        return
    }

    let eyeBounds = normalizedBounds(eye.contour)
    let centerX = (eyeBounds.midX * CGFloat(width))
    let centerY = (eyeBounds.midY * CGFloat(height))
    let radiusX = max(18, eyeBounds.width * CGFloat(width) * 0.74)
    let radiusY = max(10, eyeBounds.height * CGFloat(height) * 0.92)

    let minX = max(0, Int(floor(centerX - radiusX)))
    let maxX = min(width - 1, Int(ceil(centerX + radiusX)))
    let minY = max(0, Int(floor(centerY - radiusY)))
    let maxY = min(height - 1, Int(ceil(centerY + radiusY)))

    for y in minY...maxY {
        for x in minX...maxX {
            let nx = (CGFloat(x) - centerX) / radiusX
            let ny = (CGFloat(y) - centerY) / radiusY
            let distance = sqrt(nx * nx + ny * ny)

            guard distance < 1 else {
                continue
            }

            let alpha = smoothstep(edge0: 1.0, edge1: 0.56, x: distance) * 0.96
            guard alpha > 0 else {
                continue
            }

            let sampleX = CGFloat(x) - shiftX
            let sampleY = CGFloat(y) - shiftY
            let sample = bilinearSample(source, x: sampleX, y: sampleY)
            let index = (y * width + x) * 4

            for c in 0..<3 {
                let original = CGFloat(source.pixels[index + c])
                let corrected = CGFloat(sample[c])
                output.pixels[index + c] = UInt8(clamping: Int(original * (1 - alpha) + corrected * alpha))
            }
            output.pixels[index + 3] = 255
        }
    }
}

private func reinforcePupil(eye: EyeRenderData, source: RGBAImage, output: inout RGBAImage, strength: CGFloat) {
    let width = source.width
    let height = source.height
    let sourcePoint = pixelPoint(eye.sourcePupil, width: width, height: height)
    let targetPoint = pixelPoint(eye.targetPupil, width: width, height: height)
    let emphasizedTarget = CGPoint(
        x: sourcePoint.x + (targetPoint.x - sourcePoint.x) * strength,
        y: sourcePoint.y + (targetPoint.y - sourcePoint.y) * strength
    )
    let eyeBounds = normalizedBounds(eye.contour)
    let radiusX = max(2.0, eyeBounds.width * CGFloat(width) * 0.075)
    let radiusY = max(1.6, eyeBounds.height * CGFloat(height) * 0.16)

    let minX = max(0, Int(floor(emphasizedTarget.x - radiusX)))
    let maxX = min(width - 1, Int(ceil(emphasizedTarget.x + radiusX)))
    let minY = max(0, Int(floor(emphasizedTarget.y - radiusY)))
    let maxY = min(height - 1, Int(ceil(emphasizedTarget.y + radiusY)))
    let dark = darkestSample(around: sourcePoint, radiusX: radiusX, radiusY: radiusY, in: source)

    guard minX <= maxX, minY <= maxY else {
        return
    }

    for y in minY...maxY {
        for x in minX...maxX {
            let nx = (CGFloat(x) - emphasizedTarget.x) / radiusX
            let ny = (CGFloat(y) - emphasizedTarget.y) / radiusY
            let distance = sqrt(nx * nx + ny * ny)

            guard distance < 1 else {
                continue
            }

            let alpha = smoothstep(edge0: 1.0, edge1: 0.35, x: distance) * 0.30
            let index = (y * width + x) * 4

            for c in 0..<3 {
                let original = CGFloat(output.pixels[index + c])
                let corrected = CGFloat(dark[c])
                output.pixels[index + c] = UInt8(clamping: Int(original * (1 - alpha) + corrected * alpha))
            }
            output.pixels[index + 3] = 255
        }
    }
}

private func darkestSample(around point: CGPoint, radiusX: CGFloat, radiusY: CGFloat, in image: RGBAImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    let minX = max(0, Int(floor(point.x - radiusX)))
    let maxX = min(width - 1, Int(ceil(point.x + radiusX)))
    let minY = max(0, Int(floor(point.y - radiusY)))
    let maxY = min(height - 1, Int(ceil(point.y + radiusY)))
    var darkestIndex = (Int(point.y) * width + Int(point.x)) * 4
    var darkestLuma = CGFloat.greatestFiniteMagnitude

    guard minX <= maxX, minY <= maxY else {
        return [35, 35, 35, 255]
    }

    for y in minY...maxY {
        for x in minX...maxX {
            let luma = luminance(image, x: x, y: y)
            if luma < darkestLuma {
                darkestLuma = luma
                darkestIndex = (y * width + x) * 4
            }
        }
    }

    return [
        image.pixels[darkestIndex],
        image.pixels[darkestIndex + 1],
        image.pixels[darkestIndex + 2],
        255
    ]
}

private func bilinearSample(_ image: RGBAImage, x: CGFloat, y: CGFloat) -> [UInt8] {
    let clampedX = min(max(x, 0), CGFloat(image.width - 1))
    let clampedY = min(max(y, 0), CGFloat(image.height - 1))
    let x0 = Int(floor(clampedX))
    let y0 = Int(floor(clampedY))
    let x1 = min(x0 + 1, image.width - 1)
    let y1 = min(y0 + 1, image.height - 1)
    let tx = clampedX - CGFloat(x0)
    let ty = clampedY - CGFloat(y0)

    func value(_ px: Int, _ py: Int, _ channel: Int) -> CGFloat {
        CGFloat(image.pixels[(py * image.width + px) * 4 + channel])
    }

    var result = [UInt8](repeating: 255, count: 4)
    for c in 0..<3 {
        let a = value(x0, y0, c) * (1 - tx) + value(x1, y0, c) * tx
        let b = value(x0, y1, c) * (1 - tx) + value(x1, y1, c) * tx
        result[c] = UInt8(clamping: Int(a * (1 - ty) + b * ty))
    }
    return result
}

private func detectDarkPupil(contour: [CGPoint], in image: RGBAImage) -> CGPoint? {
    let bounds = normalizedBounds(contour)
    let width = image.width
    let height = image.height
    let centerX = bounds.midX * CGFloat(width)
    let centerY = bounds.midY * CGFloat(height)
    let radiusX = max(6, bounds.width * CGFloat(width) * 0.52)
    let radiusY = max(4, bounds.height * CGFloat(height) * 0.48)

    let minX = max(0, Int(floor(centerX - radiusX)))
    let maxX = min(width - 1, Int(ceil(centerX + radiusX)))
    let minY = max(0, Int(floor(centerY - radiusY)))
    let maxY = min(height - 1, Int(ceil(centerY + radiusY)))

    var minLuma = CGFloat.greatestFiniteMagnitude
    var totalLuma: CGFloat = 0
    var count: CGFloat = 0

    for y in minY...maxY {
        for x in minX...maxX {
            let nx = (CGFloat(x) - centerX) / radiusX
            let ny = (CGFloat(y) - centerY) / radiusY
            guard nx * nx + ny * ny <= 1 else {
                continue
            }

            let luma = luminance(image, x: x, y: y)
            minLuma = min(minLuma, luma)
            totalLuma += luma
            count += 1
        }
    }

    guard count > 0, minLuma.isFinite else {
        return nil
    }

    let meanLuma = totalLuma / count
    let threshold = minLuma + (meanLuma - minLuma) * 0.70
    var weightedX: CGFloat = 0
    var weightedY: CGFloat = 0
    var totalWeight: CGFloat = 0

    for y in minY...maxY {
        for x in minX...maxX {
            let nx = (CGFloat(x) - centerX) / radiusX
            let ny = (CGFloat(y) - centerY) / radiusY
            guard nx * nx + ny * ny <= 1 else {
                continue
            }

            let luma = luminance(image, x: x, y: y)
            let weight = max(0, threshold - luma)
            weightedX += CGFloat(x) * weight
            weightedY += CGFloat(y) * weight
            totalWeight += weight
        }
    }

    guard totalWeight > 0 else {
        return nil
    }

    return CGPoint(x: (weightedX / totalWeight) / CGFloat(width), y: (weightedY / totalWeight) / CGFloat(height))
}

private func luminance(_ image: RGBAImage, x: Int, y: Int) -> CGFloat {
    let index = (y * image.width + x) * 4
    let r = CGFloat(image.pixels[index])
    let g = CGFloat(image.pixels[index + 1])
    let b = CGFloat(image.pixels[index + 2])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

private func normalizedPoints(_ region: VNFaceLandmarkRegion2D, in face: VNFaceObservation) -> [CGPoint] {
    region.normalizedPoints.map { point in
        normalizedPoint(point, in: face)
    }
}

private func normalizedPupil(_ region: VNFaceLandmarkRegion2D?, in face: VNFaceObservation) -> CGPoint? {
    guard let region, region.pointCount > 0 else {
        return nil
    }

    let points = normalizedPoints(region, in: face)
    return centroid(points)
}

private func normalizedPoint(_ point: CGPoint, in face: VNFaceObservation) -> CGPoint {
    let box = face.boundingBox
    let imageX = box.minX + point.x * box.width
    let imageYBottom = box.minY + point.y * box.height
    return CGPoint(x: imageX, y: 1.0 - imageYBottom)
}

private func topLeftRect(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: 1.0 - rect.maxY, width: rect.width, height: rect.height)
}

private func centroid(_ points: [CGPoint]) -> CGPoint {
    guard !points.isEmpty else {
        return .zero
    }

    let sum = points.reduce(CGPoint.zero) { partial, point in
        CGPoint(x: partial.x + point.x, y: partial.y + point.y)
    }
    let count = CGFloat(points.count)
    return CGPoint(x: sum.x / count, y: sum.y / count)
}

private func normalizedBounds(_ points: [CGPoint]) -> CGRect {
    guard let first = points.first else {
        return .zero
    }

    var minX = first.x
    var minY = first.y
    var maxX = first.x
    var maxY = first.y

    for point in points.dropFirst() {
        minX = Swift.min(minX, point.x)
        minY = Swift.min(minY, point.y)
        maxX = Swift.max(maxX, point.x)
        maxY = Swift.max(maxY, point.y)
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private func pixelPoint(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
    CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))
}

private func smoothstep(edge0: CGFloat, edge1: CGFloat, x: CGFloat) -> CGFloat {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }
}

do {
    let options = try parseOptions()
    let input = options.input!
    let output = options.output!
    let cgImage = try resizeIfNeeded(loadCGImage(path: input), maxWidth: options.maxWidth)
    let rgba = try rgbaImage(from: cgImage)
    let (left, right, faceBounds) = try analyze(image: cgImage, rgba: rgba, verbose: options.verbose)
    let corrected = renderEffect(source: rgba, left: left, right: right, strength: options.strength)
    let correctedImage = try makeCGImage(from: corrected)

    if let before = options.before {
        try writeJPEG(cgImage, to: before)
    }

    if let metadata = options.metadata {
        try writeMetadata(faceBounds: faceBounds, left: left, right: right, to: metadata)
    }

    try writeJPEG(correctedImage, to: output)
    if options.verbose {
        print(output)
    }
} catch {
    fputs("GazeEffectImageTool: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func writeMetadata(faceBounds: CGRect, left: EyeRenderData, right: EyeRenderData, to path: String) throws {
    let payload: [String: Any] = [
        "faceBounds": [faceBounds.minX, faceBounds.minY, faceBounds.width, faceBounds.height],
        "leftSourcePupil": [left.sourcePupil.x, left.sourcePupil.y],
        "leftTargetPupil": [left.targetPupil.x, left.targetPupil.y],
        "rightSourcePupil": [right.sourcePupil.x, right.sourcePupil.y],
        "rightTargetPupil": [right.targetPupil.x, right.targetPupil.y]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
