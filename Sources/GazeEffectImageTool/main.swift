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
    var inputDir: String?
    var outputDir: String?
    var before: String?
    var metadata: String?
    var metadataDir: String?
    var landmarks: String?
    var landmarksDir: String?
    var maxWidth: Int = 1000
    var strength: CGFloat = 1.2
    var fillMode: EyeFillMode = .realtime
    var renderMode: RenderMode = .effect
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

private struct ExternalEyeLandmarks {
    var contour: [CGPoint]
    var pupil: CGPoint
}

private struct ExternalFrameLandmarks {
    var faceBounds: CGRect
    var confidence: CGFloat
    var leftEye: ExternalEyeLandmarks
    var rightEye: ExternalEyeLandmarks
}

private enum EyeFillMode: String {
    case realtime
    case inpaint
}

private enum RenderMode: String {
    case effect
    case whiteEyes = "white-eyes"
    case whiteEyesRedPupils = "white-eyes-red-pupils"
}

private struct MaskPixel {
    var x: Int
    var y: Int
    var alpha: CGFloat
}

private enum ToolError: LocalizedError {
    case missingArgument(String)
    case cannotLoadImage(String)
    case cannotCreateImage
    case noFace
    case noLandmarks
    case cannotListDirectory(String)
    case cannotReadLandmarks(String)
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
        case .cannotListDirectory(let path):
            return "Could not list directory: \(path)"
        case .cannotReadLandmarks(let path):
            return "Could not read landmarks: \(path)"
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
        case "--input-dir":
            options.inputDir = args.removeFirst()
        case "--output-dir":
            options.outputDir = args.removeFirst()
        case "--before":
            options.before = args.removeFirst()
        case "--metadata":
            options.metadata = args.removeFirst()
        case "--metadata-dir":
            options.metadataDir = args.removeFirst()
        case "--landmarks":
            options.landmarks = args.removeFirst()
        case "--landmarks-dir":
            options.landmarksDir = args.removeFirst()
        case "--max-width":
            options.maxWidth = Int(args.removeFirst()) ?? options.maxWidth
        case "--strength":
            options.strength = CGFloat(Double(args.removeFirst()) ?? Double(options.strength))
        case "--fill-mode":
            let value = args.removeFirst()
            guard let fillMode = EyeFillMode(rawValue: value) else {
                throw ToolError.missingArgument("--fill-mode realtime|inpaint")
            }
            options.fillMode = fillMode
        case "--render-mode":
            let value = args.removeFirst()
            guard let renderMode = RenderMode(rawValue: value) else {
                throw ToolError.missingArgument("--render-mode effect|white-eyes|white-eyes-red-pupils")
            }
            options.renderMode = renderMode
        case "--verbose":
            options.verbose = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw ToolError.missingArgument("unknown option \(arg)")
        }
    }

    if options.inputDir != nil {
        guard options.outputDir != nil else {
            throw ToolError.missingArgument("--output-dir")
        }
    } else {
        guard options.input != nil else {
            throw ToolError.missingArgument("--input")
        }
        guard options.output != nil else {
            throw ToolError.missingArgument("--output")
        }
    }

    return options
}

private func printUsage() {
    print("""
    Usage:
      GazeEffectImageTool --input source.jpg --output after.jpg [--before before.jpg] [--metadata data.json] [--landmarks landmarks.json] [--max-width 1000] [--strength 1.2] [--fill-mode realtime|inpaint] [--render-mode effect|white-eyes|white-eyes-red-pupils] [--verbose]
      GazeEffectImageTool --input-dir frames --output-dir corrected [--metadata-dir metadata] [--landmarks-dir landmarks] [--max-width 1000] [--strength 1.2] [--fill-mode realtime|inpaint] [--render-mode effect|white-eyes|white-eyes-red-pupils] [--verbose]
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

private func analyze(
    image: CGImage,
    rgba: RGBAImage,
    estimator: inout EyeContactEstimator,
    externalLandmarks: ExternalFrameLandmarks?,
    verbose: Bool
) throws -> (EyeRenderData, EyeRenderData, CGRect) {
    if let externalLandmarks {
        return try analyzeExternalLandmarks(
            externalLandmarks,
            estimator: &estimator,
            verbose: verbose
        )
    }

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
    let visionLeftPupil = normalizedPupil(landmarks.leftPupil, in: face)
    let visionRightPupil = normalizedPupil(landmarks.rightPupil, in: face)
    let leftPupil = detectDarkPupil(contour: leftContour, visionPupil: visionLeftPupil, in: rgba)
        ?? visionLeftPupil
        ?? centroid(leftContour)
    let rightPupil = detectDarkPupil(contour: rightContour, visionPupil: visionRightPupil, in: rgba)
        ?? visionRightPupil
        ?? centroid(rightContour)

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

private func analyzeExternalLandmarks(
    _ landmarks: ExternalFrameLandmarks,
    estimator: inout EyeContactEstimator,
    verbose: Bool
) throws -> (EyeRenderData, EyeRenderData, CGRect) {
    let result = estimator.estimate(
        from: FaceLandmarks(
            leftEye: EyeLandmarks(contour: landmarks.leftEye.contour, pupil: landmarks.leftEye.pupil),
            rightEye: EyeLandmarks(contour: landmarks.rightEye.contour, pupil: landmarks.rightEye.pupil),
            faceBounds: landmarks.faceBounds,
            confidence: landmarks.confidence
        )
    )

    guard let leftCorrection = result.left, let rightCorrection = result.right else {
        throw ToolError.noLandmarks
    }

    if verbose {
        print("external face confidence: \(landmarks.confidence)")
        print("left delta: \(leftCorrection.delta.dx), \(leftCorrection.delta.dy)")
        print("right delta: \(rightCorrection.delta.dx), \(rightCorrection.delta.dy)")
    }

    return (
        EyeRenderData(
            contour: landmarks.leftEye.contour,
            sourcePupil: landmarks.leftEye.pupil,
            targetPupil: leftCorrection.targetPupil
        ),
        EyeRenderData(
            contour: landmarks.rightEye.contour,
            sourcePupil: landmarks.rightEye.pupil,
            targetPupil: rightCorrection.targetPupil
        ),
        landmarks.faceBounds
    )
}

private func renderEffect(source: RGBAImage, left: EyeRenderData, right: EyeRenderData, strength: CGFloat, fillMode: EyeFillMode, renderMode: RenderMode) -> RGBAImage {
    var output = source
    switch renderMode {
    case .effect:
        applyEyeRedirection(eye: left, source: source, output: &output, strength: strength, fillMode: fillMode)
        applyEyeRedirection(eye: right, source: source, output: &output, strength: strength, fillMode: fillMode)
    case .whiteEyes:
        applyWhiteEyeDiagnostic(eye: left, source: source, output: &output, strength: strength, drawRedPupil: false)
        applyWhiteEyeDiagnostic(eye: right, source: source, output: &output, strength: strength, drawRedPupil: false)
    case .whiteEyesRedPupils:
        applyWhiteEyeDiagnostic(eye: left, source: source, output: &output, strength: strength, drawRedPupil: true)
        applyWhiteEyeDiagnostic(eye: right, source: source, output: &output, strength: strength, drawRedPupil: true)
    }
    return output
}

private func makeEstimator(smoothingAlpha: CGFloat) -> EyeContactEstimator {
    EyeContactEstimator(
        configuration: EyeContactConfiguration(
            blinkAspectRatioThreshold: 0.04,
            maxShiftAsEyeWidth: 0.38,
            maxVerticalShiftAsEyeHeight: 0.18,
            targetVerticalBiasAsEyeHeight: 0.03,
            smoothingAlpha: smoothingAlpha,
            pupilSmoothingAlpha: smoothingAlpha,
            minConfidence: 0.05
        )
    )
}

private func applyEyeRedirection(eye: EyeRenderData, source: RGBAImage, output: inout RGBAImage, strength: CGFloat, fillMode: EyeFillMode) {
    let geometry = eyeGeometry(eye: eye, source: source, strength: strength)
    let sourcePoint = geometry.sourcePoint
    let destination = geometry.destination
    let dx = destination.x - sourcePoint.x
    let dy = destination.y - sourcePoint.y

    guard hypot(dx, dy) >= 0.35 else {
        return
    }

    let radiusX = geometry.radiusX
    let radiusY = geometry.radiusY
    let sclera = estimateScleraColor(eye: eye, source: source, sourcePoint: sourcePoint, radiusX: radiusX, radiusY: radiusY)

    eraseOriginalPupil(
        source: source,
        output: &output,
        eye: eye,
        point: sourcePoint,
        radiusX: radiusX * 1.18,
        radiusY: radiusY * 1.08,
        sclera: sclera,
        fillMode: fillMode
    )
    paintIrisPatch(
        source: source,
        output: &output,
        sourcePoint: sourcePoint,
        destination: destination,
        radiusX: radiusX,
        radiusY: radiusY,
        sclera: sclera
    )
}

private struct EyeGeometry {
    var sourcePoint: CGPoint
    var destination: CGPoint
    var eyeBounds: CGRect
    var eyeWidth: CGFloat
    var eyeHeight: CGFloat
    var radiusX: CGFloat
    var radiusY: CGFloat
}

private func eyeGeometry(eye: EyeRenderData, source: RGBAImage, strength: CGFloat) -> EyeGeometry {
    let width = source.width
    let height = source.height
    let eyeBounds = normalizedBounds(eye.contour)
    let eyeWidth = max(1, eyeBounds.width * CGFloat(width))
    let eyeHeight = max(1, eyeBounds.height * CGFloat(height))
    let sourcePoint = pixelPoint(eye.sourcePupil, width: width, height: height)
    let targetPoint = pixelPoint(eye.targetPupil, width: width, height: height)
    var dx = (targetPoint.x - sourcePoint.x) * strength
    var dy = (targetPoint.y - sourcePoint.y) * strength
    dx = min(max(dx, -eyeWidth * 0.42), eyeWidth * 0.42)
    dy = min(max(dy, -eyeHeight * 0.22), eyeHeight * 0.22)

    return EyeGeometry(
        sourcePoint: sourcePoint,
        destination: CGPoint(x: sourcePoint.x + dx, y: sourcePoint.y + dy),
        eyeBounds: eyeBounds,
        eyeWidth: eyeWidth,
        eyeHeight: eyeHeight,
        radiusX: max(4.0, eyeWidth * 0.30),
        radiusY: max(3.0, eyeHeight * 0.62)
    )
}

private func applyWhiteEyeDiagnostic(
    eye: EyeRenderData,
    source: RGBAImage,
    output: inout RGBAImage,
    strength: CGFloat,
    drawRedPupil: Bool
) {
    let geometry = eyeGeometry(eye: eye, source: source, strength: strength)
    let diagnosticSclera: [CGFloat] = [242, 242, 236, 255]
    fillEyeRegion(
        source: source,
        output: &output,
        contour: eye.contour,
        bounds: geometry.eyeBounds,
        color: diagnosticSclera
    )

    guard drawRedPupil else {
        return
    }

    drawDiagnosticPupil(
        output: &output,
        center: geometry.destination,
        radius: max(2.8, geometry.eyeWidth * 0.14)
    )
}

private func fillEyeRegion(
    source: RGBAImage,
    output: inout RGBAImage,
    contour: [CGPoint],
    bounds: CGRect,
    color: [CGFloat]
) {
    let width = source.width
    let height = source.height
    let paddingX = max(2, Int(ceil(bounds.width * CGFloat(width) * 0.18)))
    let paddingY = max(2, Int(ceil(bounds.height * CGFloat(height) * 0.30)))
    let minX = max(0, Int(floor(bounds.minX * CGFloat(width))) - paddingX)
    let maxX = min(width - 1, Int(ceil(bounds.maxX * CGFloat(width))) + paddingX)
    let minY = max(0, Int(floor(bounds.minY * CGFloat(height))) - paddingY)
    let maxY = min(height - 1, Int(ceil(bounds.maxY * CGFloat(height))) + paddingY)

    guard minX <= maxX, minY <= maxY else {
        return
    }

    for y in minY...maxY {
        for x in minX...maxX {
            let normalized = CGPoint(
                x: (CGFloat(x) + 0.5) / CGFloat(width),
                y: (CGFloat(y) + 0.5) / CGFloat(height)
            )
            let insideContour = pointInPolygon(normalized, polygon: contour)
            let insideExpandedEye = pointInExpandedEyeRegion(normalized, bounds: bounds)

            guard insideContour || insideExpandedEye else {
                continue
            }

            let nx = (normalized.x - bounds.midX) / max(bounds.width * 0.66, CGFloat.ulpOfOne)
            let ny = (normalized.y - bounds.midY) / max(bounds.height * 0.92, CGFloat.ulpOfOne)
            let distance = sqrt(nx * nx + ny * ny)
            var alpha = insideContour ? CGFloat(0.96) : smoothstep(edge0: 1.0, edge1: 0.72, x: distance) * 0.86
            alpha = min(max(alpha, 0), 0.98)

            let index = (y * width + x) * 4
            for c in 0..<3 {
                let original = CGFloat(output.pixels[index + c])
                let corrected = color[c]
                output.pixels[index + c] = UInt8(clamping: Int(original * (1 - alpha) + corrected * alpha))
            }
            output.pixels[index + 3] = 255
        }
    }
}

private func drawDiagnosticPupil(output: inout RGBAImage, center: CGPoint, radius: CGFloat) {
    let width = output.width
    let height = output.height
    let minX = max(0, Int(floor(center.x - radius)))
    let maxX = min(width - 1, Int(ceil(center.x + radius)))
    let minY = max(0, Int(floor(center.y - radius)))
    let maxY = min(height - 1, Int(ceil(center.y + radius)))

    guard minX <= maxX, minY <= maxY else {
        return
    }

    for y in minY...maxY {
        for x in minX...maxX {
            let nx = (CGFloat(x) - center.x) / radius
            let ny = (CGFloat(y) - center.y) / radius
            let distance = sqrt(nx * nx + ny * ny)
            guard distance <= 1 else {
                continue
            }

            let alpha = smoothstep(edge0: 1.0, edge1: 0.68, x: distance)
            let index = (y * width + x) * 4
            output.pixels[index] = UInt8(clamping: Int(CGFloat(output.pixels[index]) * (1 - alpha) + 255 * alpha))
            output.pixels[index + 1] = UInt8(clamping: Int(CGFloat(output.pixels[index + 1]) * (1 - alpha) + 20 * alpha))
            output.pixels[index + 2] = UInt8(clamping: Int(CGFloat(output.pixels[index + 2]) * (1 - alpha) + 20 * alpha))
            output.pixels[index + 3] = 255
        }
    }
}

private func paintIrisPatch(
    source: RGBAImage,
    output: inout RGBAImage,
    sourcePoint: CGPoint,
    destination: CGPoint,
    radiusX: CGFloat,
    radiusY: CGFloat,
    sclera: [CGFloat]
) {
    let width = source.width
    let height = source.height
    let dx = destination.x - sourcePoint.x
    let dy = destination.y - sourcePoint.y
    let minX = max(0, Int(floor(destination.x - radiusX)))
    let maxX = min(width - 1, Int(ceil(destination.x + radiusX)))
    let minY = max(0, Int(floor(destination.y - radiusY)))
    let maxY = min(height - 1, Int(ceil(destination.y + radiusY)))

    guard minX <= maxX, minY <= maxY else {
        return
    }

    for y in minY...maxY {
        for x in minX...maxX {
            let nx = (CGFloat(x) - destination.x) / radiusX
            let ny = (CGFloat(y) - destination.y) / radiusY
            let distance = sqrt(nx * nx + ny * ny)

            guard distance < 1 else {
                continue
            }

            let alpha = smoothstep(edge0: 1.0, edge1: 0.18, x: distance) * 0.98
            guard alpha > 0 else {
                continue
            }

            let sample = bilinearSample(source, x: CGFloat(x) - dx, y: CGFloat(y) - dy)
            let sampleLuma = luma(sample)
            let scleraLuma = max(luma(sclera), 1)
            let darkWeight = min(max((scleraLuma + 46 - sampleLuma) / 125, 0), 1)
            guard darkWeight > 0.03 else {
                continue
            }

            let index = (y * width + x) * 4
            let finalAlpha = alpha * darkWeight

            for c in 0..<3 {
                let original = CGFloat(output.pixels[index + c])
                let corrected = CGFloat(sample[c])
                output.pixels[index + c] = UInt8(clamping: Int(original * (1 - finalAlpha) + corrected * finalAlpha))
            }
            output.pixels[index + 3] = 255
        }
    }
}

private func eraseOriginalPupil(
    source: RGBAImage,
    output: inout RGBAImage,
    eye: EyeRenderData,
    point: CGPoint,
    radiusX: CGFloat,
    radiusY: CGFloat,
    sclera: [CGFloat],
    fillMode: EyeFillMode
) {
    let maskPixels = pupilMaskPixels(
        source: source,
        contour: eye.contour,
        center: point,
        radiusX: radiusX,
        radiusY: radiusY,
        sclera: sclera
    )

    guard !maskPixels.isEmpty else {
        return
    }

    switch fillMode {
    case .realtime:
        realtimeScleraFill(source: source, output: &output, maskPixels: maskPixels, sclera: sclera)
    case .inpaint:
        inpaintScleraFill(source: source, output: &output, maskPixels: maskPixels, sclera: sclera)
    }
}

private func pupilMaskPixels(
    source: RGBAImage,
    contour: [CGPoint],
    center: CGPoint,
    radiusX: CGFloat,
    radiusY: CGFloat,
    sclera: [CGFloat]
) -> [MaskPixel] {
    let width = source.width
    let height = source.height
    let bounds = normalizedBounds(contour)
    let scleraLuma = max(luma(sclera), 1)
    let minX = max(0, Int(floor(center.x - radiusX)))
    let maxX = min(width - 1, Int(ceil(center.x + radiusX)))
    let minY = max(0, Int(floor(center.y - radiusY)))
    let maxY = min(height - 1, Int(ceil(center.y + radiusY)))

    guard minX <= maxX, minY <= maxY else {
        return []
    }

    var pixels: [MaskPixel] = []
    for y in minY...maxY {
        for x in minX...maxX {
            let nx = (CGFloat(x) - center.x) / radiusX
            let ny = (CGFloat(y) - center.y) / radiusY
            let distance = sqrt(nx * nx + ny * ny)

            guard distance < 1 else {
                continue
            }

            let normalized = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(width), y: (CGFloat(y) + 0.5) / CGFloat(height))
            let insideContour = pointInPolygon(normalized, polygon: contour)
            let insideExpandedEye = pointInExpandedEyeRegion(normalized, bounds: bounds)
            let pixelLuma = luminance(source, x: x, y: y)
            let darkWeight = min(max((scleraLuma + 40 - pixelLuma) / 130, 0), 1)

            guard insideContour || (insideExpandedEye && darkWeight > 0.25) else {
                continue
            }

            var alpha = smoothstep(edge0: 1.0, edge1: 0.20, x: distance) * min(1, 0.28 + darkWeight * 0.92)
            if !insideContour {
                alpha *= darkWeight
            }

            if alpha > 0.04 {
                pixels.append(MaskPixel(x: x, y: y, alpha: alpha))
            }
        }
    }
    return pixels
}

private func realtimeScleraFill(source: RGBAImage, output: inout RGBAImage, maskPixels: [MaskPixel], sclera: [CGFloat]) {
    for pixel in maskPixels {
        let index = (pixel.y * source.width + pixel.x) * 4
        for c in 0..<3 {
            let original = CGFloat(output.pixels[index + c])
            let corrected = sclera[c]
            output.pixels[index + c] = UInt8(clamping: Int(original * (1 - pixel.alpha) + corrected * pixel.alpha))
        }
        output.pixels[index + 3] = 255
    }
}

private func inpaintScleraFill(source: RGBAImage, output: inout RGBAImage, maskPixels: [MaskPixel], sclera: [CGFloat]) {
    let width = source.width
    let height = source.height
    var work = output.pixels
    var isMasked = [Bool](repeating: false, count: width * height)

    for pixel in maskPixels {
        isMasked[pixel.y * width + pixel.x] = true
    }

    for pixel in maskPixels {
        let index = (pixel.y * width + pixel.x) * 4
        for c in 0..<3 {
            work[index + c] = UInt8(clamping: Int(sclera[c]))
        }
        work[index + 3] = 255
    }

    for _ in 0..<48 {
        var next = work
        for pixel in maskPixels {
            let averaged = neighborAverage(
                pixels: work,
                isMasked: nil,
                width: width,
                height: height,
                x: pixel.x,
                y: pixel.y,
                fallback: sclera
            )
            let index = (pixel.y * width + pixel.x) * 4
            for c in 0..<3 {
                let corrected = averaged[c] * 0.68 + sclera[c] * 0.32
                next[index + c] = UInt8(clamping: Int(corrected))
            }
            next[index + 3] = 255
        }
        work = next
    }

    for pixel in maskPixels {
        let index = (pixel.y * width + pixel.x) * 4
        for c in 0..<3 {
            let original = CGFloat(output.pixels[index + c])
            let corrected = CGFloat(work[index + c])
            output.pixels[index + c] = UInt8(clamping: Int(original * (1 - pixel.alpha) + corrected * pixel.alpha))
        }
        output.pixels[index + 3] = 255
    }
}

private func neighborAverage(
    pixels: [UInt8],
    isMasked: [Bool]?,
    width: Int,
    height: Int,
    x: Int,
    y: Int,
    fallback: [CGFloat]
) -> [CGFloat] {
    let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
    var sums = [CGFloat](repeating: 0, count: 3)
    var count: CGFloat = 0

    for offset in offsets {
        let nx = x + offset.0
        let ny = y + offset.1
        guard nx >= 0, nx < width, ny >= 0, ny < height else {
            continue
        }

        if let isMasked, isMasked[ny * width + nx] {
            continue
        }

        let index = (ny * width + nx) * 4
        for c in 0..<3 {
            sums[c] += CGFloat(pixels[index + c])
        }
        count += 1
    }

    guard count > 0 else {
        return fallback
    }

    return sums.map { $0 / count }
}

private func estimateScleraColor(eye: EyeRenderData, source: RGBAImage, sourcePoint: CGPoint, radiusX: CGFloat, radiusY: CGFloat) -> [CGFloat] {
    let bounds = normalizedBounds(eye.contour)
    let width = source.width
    let height = source.height
    let minX = max(0, Int(floor(bounds.minX * CGFloat(width))))
    let maxX = min(width - 1, Int(ceil(bounds.maxX * CGFloat(width))))
    let minY = max(0, Int(floor(bounds.minY * CGFloat(height))))
    let maxY = min(height - 1, Int(ceil(bounds.maxY * CGFloat(height))))
    var candidates: [(luma: CGFloat, color: [CGFloat])] = []

    guard minX <= maxX, minY <= maxY else {
        return [205, 205, 205, 255]
    }

    for y in minY...maxY {
        for x in minX...maxX {
            let normalized = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(width), y: (CGFloat(y) + 0.5) / CGFloat(height))
            guard pointInPolygon(normalized, polygon: eye.contour) else {
                continue
            }

            let nx = (CGFloat(x) - sourcePoint.x) / max(radiusX * 1.35, 1)
            let ny = (CGFloat(y) - sourcePoint.y) / max(radiusY * 1.20, 1)
            guard nx * nx + ny * ny > 1.0 else {
                continue
            }

            let index = (y * width + x) * 4
            let color = [
                CGFloat(source.pixels[index]),
                CGFloat(source.pixels[index + 1]),
                CGFloat(source.pixels[index + 2]),
                CGFloat(source.pixels[index + 3])
            ]
            let pixelLuma = luma(color)
            guard pixelLuma > 45 else {
                continue
            }
            candidates.append((pixelLuma, color))
        }
    }

    guard !candidates.isEmpty else {
        return [205, 205, 205, 255]
    }

    let sorted = candidates.sorted { $0.luma > $1.luma }
    let selected = sorted.prefix(max(4, sorted.count / 3))
    var sums = [CGFloat](repeating: 0, count: 4)
    var totalWeight: CGFloat = 0

    for item in selected {
        let weight = max(item.luma, 1)
        for c in 0..<4 {
            sums[c] += item.color[c] * weight
        }
        totalWeight += weight
    }

    guard totalWeight > 0 else {
        return [205, 205, 205, 255]
    }

    return sums.map { $0 / totalWeight }
}

private func luma(_ color: [CGFloat]) -> CGFloat {
    guard color.count >= 3 else {
        return 0
    }
    return 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
}

private func luma(_ color: [UInt8]) -> CGFloat {
    guard color.count >= 3 else {
        return 0
    }
    return 0.2126 * CGFloat(color[0]) + 0.7152 * CGFloat(color[1]) + 0.0722 * CGFloat(color[2])
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

private func detectDarkPupil(contour: [CGPoint], visionPupil: CGPoint?, in image: RGBAImage) -> CGPoint? {
    guard contour.count >= 4 else {
        return nil
    }

    let bounds = normalizedBounds(contour)
    let width = image.width
    let height = image.height
    let paddingX = max(2, Int(ceil(bounds.width * CGFloat(width) * 0.10)))
    let paddingY = max(2, Int(ceil(bounds.height * CGFloat(height) * 0.16)))
    let minX = max(0, Int(floor(bounds.minX * CGFloat(width))) - paddingX)
    let maxX = min(width - 1, Int(ceil(bounds.maxX * CGFloat(width))) + paddingX)
    let minY = max(0, Int(floor(bounds.minY * CGFloat(height))) - paddingY)
    let maxY = min(height - 1, Int(ceil(bounds.maxY * CGFloat(height))) + paddingY)
    let roiWidth = maxX - minX + 1
    let roiHeight = maxY - minY + 1

    guard roiWidth > 1, roiHeight > 1 else {
        return nil
    }

    var mask = [Bool](repeating: false, count: roiWidth * roiHeight)
    var lumas: [CGFloat] = []

    for y in minY...maxY {
        for x in minX...maxX {
            let normalized = CGPoint(
                x: (CGFloat(x) + 0.5) / CGFloat(width),
                y: (CGFloat(y) + 0.5) / CGFloat(height)
            )
            let inMask = pointInPolygon(normalized, polygon: contour)
                || pointInExpandedEyeRegion(normalized, bounds: bounds)
            if inMask {
                mask[(y - minY) * roiWidth + (x - minX)] = true
                lumas.append(luminance(image, x: x, y: y))
            }
        }
    }

    guard lumas.count >= 6 else {
        return nil
    }

    let threshold = percentile(lumas, p: 0.18)
    let minArea = max(2, Int(Double(lumas.count) * 0.006))
    let maxArea = max(minArea + 1, Int(Double(lumas.count) * 0.30))
    var visited = [Bool](repeating: false, count: roiWidth * roiHeight)
    var bestScore: CGFloat = -1
    var bestCenter: CGPoint?

    for y in minY...maxY {
        for x in minX...maxX {
            let localIndex = (y - minY) * roiWidth + (x - minX)
            guard mask[localIndex], !visited[localIndex], luminance(image, x: x, y: y) <= threshold else {
                continue
            }

            let component = floodDarkComponent(
                startX: x,
                startY: y,
                minX: minX,
                minY: minY,
                maxX: maxX,
                maxY: maxY,
                roiWidth: roiWidth,
                threshold: threshold,
                mask: mask,
                visited: &visited,
                image: image
            )

            guard component.area >= minArea, component.area <= maxArea else {
                continue
            }

            let center = CGPoint(
                x: component.sumX / CGFloat(component.area),
                y: component.sumY / CGFloat(component.area)
            )
            let bboxArea = max(1, CGFloat((component.maxX - component.minX + 1) * (component.maxY - component.minY + 1)))
            let compactness = min(CGFloat(component.area) / bboxArea, 1)
            let idealArea = max(CGFloat(minArea), CGFloat(lumas.count) * 0.045)
            let areaScore = 1 - min(abs(CGFloat(component.area) - idealArea) / idealArea, 1)
            let darknessScore = 1 - min((component.lumaSum / CGFloat(component.area)) / 255, 1)
            let distanceScore = pupilDistanceScore(
                center: center,
                fallbackCenter: CGPoint(x: bounds.midX * CGFloat(width), y: bounds.midY * CGFloat(height)),
                visionPupil: visionPupil,
                eyeWidth: bounds.width * CGFloat(width),
                width: width,
                height: height
            )
            let verticalScore = pupilVerticalScore(
                center: center,
                bounds: bounds,
                width: width,
                height: height
            )
            let score = darknessScore * 0.32 + distanceScore * 0.32 + areaScore * 0.16 + compactness * 0.12 + verticalScore * 0.08

            if score > bestScore {
                bestScore = score
                bestCenter = center
            }
        }
    }

    guard let bestCenter, bestScore >= 0.28 else {
        return nil
    }

    return CGPoint(x: bestCenter.x / CGFloat(width), y: bestCenter.y / CGFloat(height))
}

private func pointInExpandedEyeRegion(_ point: CGPoint, bounds: CGRect) -> Bool {
    guard bounds.width > 0, bounds.height > 0 else {
        return false
    }

    let nx = (point.x - bounds.midX) / max(bounds.width * 0.62, CGFloat.ulpOfOne)
    let ny = (point.y - bounds.midY) / max(bounds.height * 0.86, CGFloat.ulpOfOne)
    return nx * nx + ny * ny <= 1
}

private struct DarkComponent {
    var area: Int = 0
    var sumX: CGFloat = 0
    var sumY: CGFloat = 0
    var lumaSum: CGFloat = 0
    var minX: Int = .max
    var minY: Int = .max
    var maxX: Int = .min
    var maxY: Int = .min
}

private func floodDarkComponent(
    startX: Int,
    startY: Int,
    minX: Int,
    minY: Int,
    maxX: Int,
    maxY: Int,
    roiWidth: Int,
    threshold: CGFloat,
    mask: [Bool],
    visited: inout [Bool],
    image: RGBAImage
) -> DarkComponent {
    var component = DarkComponent()
    var queue = [(x: startX, y: startY)]
    var head = 0

    while head < queue.count {
        let current = queue[head]
        head += 1

        guard current.x >= minX, current.x <= maxX, current.y >= minY, current.y <= maxY else {
            continue
        }

        let localIndex = (current.y - minY) * roiWidth + (current.x - minX)
        guard mask[localIndex], !visited[localIndex] else {
            continue
        }

        let luma = luminance(image, x: current.x, y: current.y)
        guard luma <= threshold else {
            continue
        }

        visited[localIndex] = true
        component.area += 1
        component.sumX += CGFloat(current.x)
        component.sumY += CGFloat(current.y)
        component.lumaSum += luma
        component.minX = min(component.minX, current.x)
        component.minY = min(component.minY, current.y)
        component.maxX = max(component.maxX, current.x)
        component.maxY = max(component.maxY, current.y)

        queue.append((current.x + 1, current.y))
        queue.append((current.x - 1, current.y))
        queue.append((current.x, current.y + 1))
        queue.append((current.x, current.y - 1))
    }

    return component
}

private func pupilDistanceScore(
    center: CGPoint,
    fallbackCenter: CGPoint,
    visionPupil: CGPoint?,
    eyeWidth: CGFloat,
    width: Int,
    height: Int
) -> CGFloat {
    let reference = visionPupil.map {
        CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height))
    } ?? fallbackCenter
    let distance = hypot(center.x - reference.x, center.y - reference.y)
    return 1 - min(distance / max(eyeWidth * 0.45, 1), 1)
}

private func pupilVerticalScore(center: CGPoint, bounds: CGRect, width: Int, height: Int) -> CGFloat {
    let eyeHeight = max(bounds.height * CGFloat(height), 1)
    let targetY = bounds.midY * CGFloat(height)
    let distance = abs(center.y - targetY)
    return 1 - min(distance / max(eyeHeight * 0.70, 1), 1)
}

private func percentile(_ values: [CGFloat], p: CGFloat) -> CGFloat {
    guard !values.isEmpty else {
        return 0
    }

    let sorted = values.sorted()
    let index = min(max(Int(CGFloat(sorted.count - 1) * p), 0), sorted.count - 1)
    return sorted[index]
}

private func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
    guard polygon.count >= 3 else {
        return false
    }

    var isInside = false
    var j = polygon.count - 1
    for i in 0..<polygon.count {
        let pi = polygon[i]
        let pj = polygon[j]
        if (pi.y > point.y) != (pj.y > point.y) {
            let denominator = pj.y - pi.y
            let safeDenominator = abs(denominator) < CGFloat.ulpOfOne ? CGFloat.ulpOfOne : denominator
            let xIntersection = (pj.x - pi.x) * (point.y - pi.y) / safeDenominator + pi.x
            if point.x < xIntersection {
                isInside.toggle()
            }
        }
        j = i
    }
    return isInside
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
    if options.inputDir != nil {
        try processSequence(options)
    } else {
        try processSingle(options)
    }
} catch {
    fputs("GazeEffectImageTool: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private func processSingle(_ options: Options) throws {
    let input = options.input!
    let output = options.output!
    let cgImage = try resizeIfNeeded(loadCGImage(path: input), maxWidth: options.maxWidth)
    let rgba = try rgbaImage(from: cgImage)
    var estimator = makeEstimator(smoothingAlpha: 1.0)
    let externalLandmarks = try options.landmarks.map { try loadExternalLandmarks(path: $0) }
    let (left, right, faceBounds) = try analyze(
        image: cgImage,
        rgba: rgba,
        estimator: &estimator,
        externalLandmarks: externalLandmarks,
        verbose: options.verbose
    )
    let corrected = renderEffect(
        source: rgba,
        left: left,
        right: right,
        strength: options.strength,
        fillMode: options.fillMode,
        renderMode: options.renderMode
    )
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
}

private func processSequence(_ options: Options) throws {
    let inputDir = options.inputDir!
    let outputDir = options.outputDir!
    let inputURL = URL(fileURLWithPath: inputDir)
    let outputURL = URL(fileURLWithPath: outputDir)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    let frames = try listFrameURLs(in: inputURL)
    var estimator = makeEstimator(smoothingAlpha: 1.0)
    var processed = 0
    var fallback = 0

    for frameURL in frames {
        let outputFrameURL = outputURL.appendingPathComponent(frameURL.lastPathComponent)
        let cgImage = try resizeIfNeeded(loadCGImage(path: frameURL.path), maxWidth: options.maxWidth)
        let rgba = try rgbaImage(from: cgImage)

        do {
            let externalLandmarks = try externalLandmarksForFrame(frameURL, landmarksDir: options.landmarksDir)
            let (left, right, faceBounds) = try analyze(
                image: cgImage,
                rgba: rgba,
                estimator: &estimator,
                externalLandmarks: externalLandmarks,
                verbose: false
            )
            let corrected = renderEffect(
                source: rgba,
                left: left,
                right: right,
                strength: options.strength,
                fillMode: options.fillMode,
                renderMode: options.renderMode
            )
            let correctedImage = try makeCGImage(from: corrected)
            try writeJPEG(correctedImage, to: outputFrameURL.path)

            if let metadataDir = options.metadataDir {
                let metadataURL = URL(fileURLWithPath: metadataDir)
                    .appendingPathComponent(frameURL.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension("json")
                try writeMetadata(faceBounds: faceBounds, left: left, right: right, to: metadataURL.path)
            }
            processed += 1
        } catch {
            estimator.reset()
            try writeJPEG(cgImage, to: outputFrameURL.path)
            fallback += 1
            if options.verbose {
                fputs("fallback \(frameURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    if options.verbose {
        print("processed=\(processed) fallback=\(fallback)")
    }
}

private func listFrameURLs(in url: URL) throws -> [URL] {
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        throw ToolError.cannotListDirectory(url.path)
    }

    let allowed = Set(["jpg", "jpeg", "png"])
    return urls
        .filter { allowed.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func externalLandmarksForFrame(_ frameURL: URL, landmarksDir: String?) throws -> ExternalFrameLandmarks? {
    guard let landmarksDir else {
        return nil
    }

    let landmarksURL = URL(fileURLWithPath: landmarksDir)
        .appendingPathComponent(frameURL.deletingPathExtension().lastPathComponent)
        .appendingPathExtension("json")
    return try loadExternalLandmarks(path: landmarksURL.path)
}

private func loadExternalLandmarks(path: String) throws -> ExternalFrameLandmarks {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ToolError.cannotReadLandmarks(path)
    }

    guard let leftContour = pointList(object["leftContour"]),
          let rightContour = pointList(object["rightContour"]),
          let leftPupil = pointValue(object["leftPupil"] ?? object["leftSourcePupil"]),
          let rightPupil = pointValue(object["rightPupil"] ?? object["rightSourcePupil"]) else {
        throw ToolError.cannotReadLandmarks(path)
    }

    let faceBounds = rectValue(object["faceBounds"])
        ?? normalizedBounds(leftContour + rightContour).insetBy(dx: -0.08, dy: -0.12)
    let confidence = CGFloat(numberValue(object["confidence"]) ?? 0.95)

    return ExternalFrameLandmarks(
        faceBounds: faceBounds,
        confidence: confidence,
        leftEye: ExternalEyeLandmarks(contour: leftContour, pupil: leftPupil),
        rightEye: ExternalEyeLandmarks(contour: rightContour, pupil: rightPupil)
    )
}

private func pointList(_ value: Any?) -> [CGPoint]? {
    guard let rawPoints = value as? [Any] else {
        return nil
    }

    let points = rawPoints.compactMap { pointValue($0) }
    return points.count == rawPoints.count && !points.isEmpty ? points : nil
}

private func pointValue(_ value: Any?) -> CGPoint? {
    guard let raw = value as? [Any],
          raw.count >= 2,
          let x = numberValue(raw[0]),
          let y = numberValue(raw[1]) else {
        return nil
    }
    return CGPoint(x: CGFloat(x), y: CGFloat(y))
}

private func rectValue(_ value: Any?) -> CGRect? {
    guard let raw = value as? [Any],
          raw.count >= 4,
          let x = numberValue(raw[0]),
          let y = numberValue(raw[1]),
          let width = numberValue(raw[2]),
          let height = numberValue(raw[3]) else {
        return nil
    }
    return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
}

private func numberValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        return value
    case let value as Float:
        return Double(value)
    case let value as Int:
        return Double(value)
    case let value as NSNumber:
        return value.doubleValue
    default:
        return nil
    }
}

private func writeMetadata(faceBounds: CGRect, left: EyeRenderData, right: EyeRenderData, to path: String) throws {
    let payload: [String: Any] = [
        "faceBounds": [faceBounds.minX, faceBounds.minY, faceBounds.width, faceBounds.height],
        "leftSourcePupil": [left.sourcePupil.x, left.sourcePupil.y],
        "leftTargetPupil": [left.targetPupil.x, left.targetPupil.y],
        "leftContour": left.contour.map { [$0.x, $0.y] },
        "leftEyeBounds": boundsPayload(for: left.contour),
        "rightSourcePupil": [right.sourcePupil.x, right.sourcePupil.y],
        "rightTargetPupil": [right.targetPupil.x, right.targetPupil.y],
        "rightContour": right.contour.map { [$0.x, $0.y] },
        "rightEyeBounds": boundsPayload(for: right.contour)
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

private func boundsPayload(for points: [CGPoint]) -> [CGFloat] {
    let bounds = normalizedBounds(points)
    return [bounds.minX, bounds.minY, bounds.width, bounds.height]
}
