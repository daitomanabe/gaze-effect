import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import GazeEffectCore
import QuartzCore
import Vision

private enum PreviewMode: Int {
    case debug = 0
    case effect = 1

    var label: String {
        switch self {
        case .debug:
            return "Debug"
        case .effect:
            return "Effect"
        }
    }
}

private struct AnalysisState {
    var statusText: String
    var faceBounds: CGRect?
    var leftEye: EyeOverlay?
    var rightEye: EyeOverlay?

    static let starting = AnalysisState(
        statusText: "Starting camera",
        faceBounds: nil,
        leftEye: nil,
        rightEye: nil
    )
}

private struct EyeOverlay {
    var contour: [CGPoint]
    var sourcePupil: CGPoint?
    var targetPupil: CGPoint?
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var previewView: PreviewContainerView?
    private var cameraController: CameraController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = PreviewContainerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))

        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gaze Effect Preview"
        window.contentMinSize = NSSize(width: 960, height: 540)
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.previewView = content

        let controller = CameraController(containerView: content)
        self.cameraController = controller
        controller.start()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        cameraController?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class PreviewContainerView: NSView {
    let renderView = FrameRenderView()
    private let modeControl = NSSegmentedControl(labels: ["Debug", "Effect"], trackingMode: .selectOne, target: nil, action: nil)

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        renderView.autoresizingMask = [.width, .height]
        addSubview(renderView)

        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentStyle = .rounded
        modeControl.selectedSegment = PreviewMode.effect.rawValue
        modeControl.toolTip = "Switch between debug overlay and corrected eye-contact preview"
        addSubview(modeControl)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        renderView.frame = bounds
        modeControl.frame = NSRect(x: bounds.width - 190, y: 12, width: 172, height: 30)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        renderView.mode = PreviewMode(rawValue: sender.selectedSegment) ?? .effect
    }
}

private final class FrameRenderView: NSView {
    var mode: PreviewMode = .effect {
        didSet {
            needsDisplay = true
        }
    }

    var cameraImage: CGImage? {
        didSet {
            needsDisplay = true
        }
    }

    var state: AnalysisState = .starting {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let cameraImage else {
            drawEmptyState()
            drawStatus()
            return
        }

        guard let context = NSGraphicsContext.current else {
            return
        }

        context.imageInterpolation = .high

        let imageRect = aspectFitRect(
            imageSize: CGSize(width: cameraImage.width, height: cameraImage.height),
            in: bounds
        )

        drawCameraImage(cameraImage, in: imageRect, fraction: 1.0)

        if mode == .effect {
            drawEyeShiftEffect(state.leftEye, image: cameraImage, imageRect: imageRect)
            drawEyeShiftEffect(state.rightEye, image: cameraImage, imageRect: imageRect)
        }

        if mode == .debug {
            drawDebugOverlay(in: imageRect)
        }

        drawStatus()
    }

    private func drawEmptyState() {
        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    private func drawStatus() {
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 54, width: bounds.width, height: 54)).fill()

        let text = "\(mode.label) | \(state.statusText)"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        ]

        text.draw(
            in: NSRect(x: 18, y: bounds.height - 38, width: max(0, bounds.width - 222), height: 24),
            withAttributes: attributes
        )
    }

    private func drawDebugOverlay(in imageRect: NSRect) {
        if let faceBounds = state.faceBounds {
            drawRect(faceBounds, in: imageRect, color: NSColor.systemTeal.withAlphaComponent(0.86), lineWidth: 2)
        }

        drawEyeDebug(state.leftEye, in: imageRect, color: .systemYellow)
        drawEyeDebug(state.rightEye, in: imageRect, color: .systemGreen)
    }

    private func drawEyeDebug(_ eye: EyeOverlay?, in imageRect: NSRect, color: NSColor) {
        guard let eye else {
            return
        }

        drawPolyline(eye.contour, in: imageRect, color: color, lineWidth: 2, close: true)

        if let sourcePupil = eye.sourcePupil {
            drawCircle(sourcePupil, in: imageRect, radius: 5, color: .systemOrange)
        }

        if let targetPupil = eye.targetPupil {
            drawCircle(targetPupil, in: imageRect, radius: 4, color: .systemCyan)
        }

        if let sourcePupil = eye.sourcePupil, let targetPupil = eye.targetPupil {
            drawLine(from: sourcePupil, to: targetPupil, in: imageRect, color: .systemPink, lineWidth: 2)
        }
    }

    private func drawEyeShiftEffect(_ eye: EyeOverlay?, image: CGImage, imageRect: NSRect) {
        guard let eye,
              let sourcePupil = eye.sourcePupil,
              let targetPupil = eye.targetPupil,
              eye.contour.count >= 4 else {
            return
        }

        let sourceView = viewPoint(sourcePupil, in: imageRect)
        let targetView = viewPoint(targetPupil, in: imageRect)
        let eyeRect = normalizedBounds(eye.contour).viewRect(in: imageRect)
        var dx = (targetView.x - sourceView.x) * 1.4
        var dy = (targetView.y - sourceView.y) * 1.4
        dx = min(max(dx, -eyeRect.width * 0.34), eyeRect.width * 0.34)
        dy = min(max(dy, -eyeRect.height * 0.72), eyeRect.height * 0.72)

        guard hypot(dx, dy) >= 0.75 else {
            return
        }

        let destination = NSPoint(x: sourceView.x + dx, y: sourceView.y + dy)
        let radiusX = max(4, eyeRect.width * 0.23)
        let radiusY = max(3, eyeRect.height * 0.50)
        let sourceMask = NSRect(
            x: sourceView.x - radiusX * 1.18,
            y: sourceView.y - radiusY * 1.08,
            width: radiusX * 2.36,
            height: radiusY * 2.16
        )
        let destinationMask = NSRect(
            x: destination.x - radiusX,
            y: destination.y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: sourceMask).addClip()
        drawCameraImage(image, in: imageRect.offsetBy(dx: -dx * 0.82, dy: -dy * 0.82), fraction: 0.48)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: destinationMask).addClip()
        drawCameraImage(image, in: imageRect.offsetBy(dx: dx, dy: dy), fraction: 0.98)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCameraImage(_ image: CGImage, in rect: NSRect, fraction: CGFloat) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        nsImage.draw(
            in: rect,
            from: NSRect(x: 0, y: 0, width: image.width, height: image.height),
            operation: .sourceOver,
            fraction: fraction
        )
    }

    private func drawRect(_ rect: CGRect, in imageRect: NSRect, color: NSColor, lineWidth: CGFloat) {
        let frame = rect.viewRect(in: imageRect)

        color.setStroke()
        let path = NSBezierPath(rect: frame)
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawPolyline(_ points: [CGPoint], in imageRect: NSRect, color: NSColor, lineWidth: CGFloat, close: Bool) {
        guard let first = points.first else {
            return
        }

        let path = NSBezierPath()
        path.move(to: viewPoint(first, in: imageRect))

        for point in points.dropFirst() {
            path.line(to: viewPoint(point, in: imageRect))
        }

        if close {
            path.close()
        }

        color.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, in imageRect: NSRect, color: NSColor, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.move(to: viewPoint(start, in: imageRect))
        path.line(to: viewPoint(end, in: imageRect))

        color.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    private func drawCircle(_ point: CGPoint, in imageRect: NSRect, radius: CGFloat, color: NSColor) {
        let center = viewPoint(point, in: imageRect)
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func viewPoint(_ normalized: CGPoint, in imageRect: NSRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + normalized.x * imageRect.width,
            y: imageRect.maxY - normalized.y * imageRect.height
        )
    }

    private func aspectFitRect(imageSize: CGSize, in container: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }

        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale

        return NSRect(
            x: container.midX - width / 2,
            y: container.midY - height / 2,
            width: width,
            height: height
        )
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
}

private final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ws.daito.gaze-effect.session")
    private let videoQueue = DispatchQueue(label: "ws.daito.gaze-effect.video")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private weak var containerView: PreviewContainerView?
    private var estimator = EyeContactEstimator()
    private var lastAnalysisTime: CFTimeInterval = 0
    private var isAnalyzing = false
    private let analysisFrameInterval: CFTimeInterval = 1.0 / 30.0
    private let analysisMaxDimension: CGFloat = 640

    init(containerView: PreviewContainerView) {
        self.containerView = containerView
        super.init()
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            updateStatus("Waiting for camera permission")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureAndStart()
                    } else {
                        self?.updateStatus("Camera permission denied")
                    }
                }
            }
        default:
            updateStatus("Camera permission unavailable")
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureAndStart() {
        updateStatus("Starting camera")

        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                try self.configureSession()
                self.session.startRunning()
                self.updateStatus("Camera running | Face: searching")
            } catch {
                self.updateStatus("Camera error: \(error.localizedDescription)")
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        session.sessionPreset = .hd1280x720

        for input in session.inputs {
            session.removeInput(input)
        }

        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        publishFrame(pixelBuffer)

        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= analysisFrameInterval, !isAnalyzing else {
            return
        }
        lastAnalysisTime = now
        isAnalyzing = true

        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let self else {
                return
            }

            defer {
                self.isAnalyzing = false
            }

            if let error {
                self.updateStatus("Vision error: \(error.localizedDescription)")
                return
            }

            self.handleVisionResults(request.results as? [VNFaceObservation] ?? [], pixelBuffer: pixelBuffer)
        }

        guard let analysisImage = makeAnalysisImage(from: pixelBuffer) else {
            isAnalyzing = false
            updateStatus("Vision error: could not prepare analysis frame")
            return
        }

        let handler = VNImageRequestHandler(cgImage: analysisImage, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            isAnalyzing = false
            updateStatus("Vision error: \(error.localizedDescription)")
        }
    }

    private func publishFrame(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.containerView?.renderView.cameraImage = cgImage
        }
    }

    private func makeAnalysisImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        let longestEdge = max(extent.width, extent.height)
        let scale = longestEdge > analysisMaxDimension ? analysisMaxDimension / longestEdge : 1

        guard scale < 1 else {
            return ciContext.createCGImage(ciImage, from: extent)
        }

        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = CGRect(
            x: 0,
            y: 0,
            width: floor(extent.width * scale),
            height: floor(extent.height * scale)
        )
        return ciContext.createCGImage(scaledImage, from: scaledExtent)
    }

    private func handleVisionResults(_ observations: [VNFaceObservation], pixelBuffer: CVPixelBuffer) {
        guard let face = observations.max(by: { $0.boundingBox.area < $1.boundingBox.area }),
              let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye else {
            estimator.reset()
            updateState(AnalysisState(statusText: "Camera running | Face: searching", faceBounds: nil, leftEye: nil, rightEye: nil))
            return
        }

        let leftContour = normalizedPoints(leftEye, in: face)
        let rightContour = normalizedPoints(rightEye, in: face)
        let visionLeftPupil = normalizedPupil(landmarks.leftPupil, in: face)
        let visionRightPupil = normalizedPupil(landmarks.rightPupil, in: face)
        let leftPupil = detectDarkPupil(contour: leftContour, visionPupil: visionLeftPupil, in: pixelBuffer)
            ?? visionLeftPupil
        let rightPupil = detectDarkPupil(contour: rightContour, visionPupil: visionRightPupil, in: pixelBuffer)
            ?? visionRightPupil

        let result = estimator.estimate(
            from: FaceLandmarks(
                leftEye: EyeLandmarks(contour: leftContour, pupil: leftPupil),
                rightEye: EyeLandmarks(contour: rightContour, pupil: rightPupil),
                faceBounds: topLeftRect(face.boundingBox),
                confidence: CGFloat(face.confidence)
            )
        )

        let state = AnalysisState(
            statusText: "Camera running | Face: detected | Eye contact: \(result.shouldRender ? "active" : "pass-through")",
            faceBounds: topLeftRect(face.boundingBox),
            leftEye: EyeOverlay(contour: leftContour, sourcePupil: leftPupil, targetPupil: result.left?.targetPupil),
            rightEye: EyeOverlay(contour: rightContour, sourcePupil: rightPupil, targetPupil: result.right?.targetPupil)
        )

        updateState(state)
    }

    private func updateStatus(_ status: String) {
        updateState(AnalysisState(statusText: status, faceBounds: nil, leftEye: nil, rightEye: nil))
    }

    private func updateState(_ state: AnalysisState) {
        DispatchQueue.main.async { [weak self] in
            self?.containerView?.renderView.state = state
        }
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
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let count = CGFloat(points.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
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

    private func detectDarkPupil(contour: [CGPoint], visionPupil: CGPoint?, in pixelBuffer: CVPixelBuffer) -> CGPoint? {
        guard contour.count >= 4 else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bounds = normalizedBounds(contour)
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
                if pointInPolygon(normalized, polygon: contour) {
                    mask[(y - minY) * roiWidth + (x - minX)] = true
                    lumas.append(bgraLuminance(buffer: buffer, bytesPerRow: bytesPerRow, x: x, y: y))
                }
            }
        }

        guard lumas.count >= 6 else {
            return nil
        }

        let threshold = percentile(lumas, p: 0.28)
        let minArea = max(2, Int(Double(lumas.count) * 0.015))
        let maxArea = max(minArea + 1, Int(Double(lumas.count) * 0.55))
        var visited = [Bool](repeating: false, count: roiWidth * roiHeight)
        var bestScore: CGFloat = -1
        var bestCenter: CGPoint?

        for y in minY...maxY {
            for x in minX...maxX {
                let localIndex = (y - minY) * roiWidth + (x - minX)
                guard mask[localIndex],
                      !visited[localIndex],
                      bgraLuminance(buffer: buffer, bytesPerRow: bytesPerRow, x: x, y: y) <= threshold else {
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
                    buffer: buffer,
                    bytesPerRow: bytesPerRow
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
                let idealArea = max(CGFloat(minArea), CGFloat(lumas.count) * 0.08)
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
                let score = darknessScore * 0.42 + areaScore * 0.22 + compactness * 0.16 + distanceScore * 0.20

                if score > bestScore {
                    bestScore = score
                    bestCenter = center
                }
            }
        }

        guard let bestCenter, bestScore >= 0.32 else {
            return nil
        }

        return CGPoint(
            x: bestCenter.x / CGFloat(width),
            y: bestCenter.y / CGFloat(height)
        )
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
        buffer: UnsafePointer<UInt8>,
        bytesPerRow: Int
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

            let luma = bgraLuminance(buffer: buffer, bytesPerRow: bytesPerRow, x: current.x, y: current.y)
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

    private func bgraLuminance(buffer: UnsafePointer<UInt8>, bytesPerRow: Int, x: Int, y: Int) -> CGFloat {
        let index = y * bytesPerRow + x * 4
        let b = CGFloat(buffer[index])
        let g = CGFloat(buffer[index + 1])
        let r = CGFloat(buffer[index + 2])
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
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
}

private enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No video camera found"
        case .cannotAddInput:
            return "Could not add camera input"
        case .cannotAddOutput:
            return "Could not add video output"
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }

    func viewRect(in imageRect: NSRect) -> NSRect {
        NSRect(
            x: imageRect.minX + minX * imageRect.width,
            y: imageRect.maxY - maxY * imageRect.height,
            width: width * imageRect.width,
            height: height * imageRect.height
        )
    }
}

private extension NSRect {
    func expanded(widthScale: CGFloat, heightScale: CGFloat, minWidth: CGFloat, minHeight: CGFloat) -> NSRect {
        let targetWidth = max(width * (1 + widthScale), minWidth)
        let targetHeight = max(height * (1 + heightScale), minHeight)
        return NSRect(
            x: midX - targetWidth / 2,
            y: midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
