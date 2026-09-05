import AppKit
import AVFoundation
import CoreImage
import ImageIO
import GazeEffectBridge
import CryptoKit

private final class PreviewView: NSView {
    let imageView = NSImageView()
    let status = NSTextField(labelWithString: "Preparing camera")
    let mode = NSSegmentedControl(labels: ["Original", "Effect", "Debug"], trackingMode: .selectOne, target: nil, action: nil)
    let engine = NSPopUpButton()
    let profile = NSTextField(string: "default")
    let calibrate = NSButton(title: "Look at lens · Calibrate", target: nil, action: nil)
    let addPose = NSButton(title: "Add head angle", target: nil, action: nil)
    let reset = NSButton(title: "Reset", target: nil, action: nil)
    let apply = NSButton(title: "Apply profile", target: nil, action: nil)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        status.textColor = .white
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        mode.selectedSegment = 1
        engine.addItems(withTitles: ["Automatic", "Local warp", "Neural trial"])
        profile.placeholderString = "Person / eyewear profile"
        profile.toolTip = "Use a different name when changing person or glasses. Camera and image geometry are checked automatically."
        for view in [imageView, status, mode, engine, profile, calibrate, addPose, reset, apply] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        imageView.frame = NSRect(x: 0, y: 92, width: bounds.width, height: max(0,bounds.height-92))
        status.frame = NSRect(x: 16,y: 65,width: bounds.width-32,height: 20)
        mode.frame = NSRect(x:16,y:12,width:230,height:28)
        engine.frame = NSRect(x:256,y:12,width:145,height:28)
        profile.frame = NSRect(x:412,y:12,width:120,height:28)
        apply.frame = NSRect(x:540,y:12,width:110,height:28)
        calibrate.frame = NSRect(x:660,y:12,width:190,height:28)
        addPose.frame = NSRect(x:860,y:12,width:130,height:28)
        reset.frame = NSRect(x:998,y:12,width:70,height:28)
    }
}

private final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "ws.daito.gaze.pipeline", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingCommand: String?
    private var selectedMode = 1
    private var selectedEngine = "hybrid"
    private var profileName = "default"
    private var revision = 0
    private var activeRevision = -1
    private var worker: GazePipelineBridge?
    private let context = CIContext(options: [.cacheIntermediates:false])
    private weak var view: PreviewView?
    private var cameraID = "replay"
    private var frameID = 0
    private var origin: Double?
    private var records: [[String:Any]] = []
    private var latencies: [Double] = []
    private var dropped = 0
    private var workerFailed = false
    private var activity: NSObjectProtocol?

    init(view: PreviewView) {
        self.view = view
        super.init()
        for button in [view.calibrate,view.addPose,view.reset] { button.target = self; button.action = #selector(command(_:)) }
        view.apply.target = self; view.apply.action = #selector(settingsChanged)
        view.engine.target = self; view.engine.action = #selector(settingsChanged)
        view.mode.target = self; view.mode.action = #selector(settingsChanged)
    }

    @objc private func command(_ button: NSButton) {
        lock.lock()
        pendingCommand = button === view?.reset ? "reset" : (button === view?.addPose ? "calibrate-add" : "calibrate")
        lock.unlock()
    }
    @objc private func settingsChanged() {
        guard let view else { return }
        lock.lock()
        selectedMode = view.mode.selectedSegment
        let newEngine = ["hybrid","geometry","neural"][view.engine.indexOfSelectedItem]
        let newProfile = view.profile.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newEngine != selectedEngine || newProfile != profileName || workerFailed { revision += 1 }
        selectedEngine = newEngine; profileName = newProfile.isEmpty ? "default" : newProfile
        lock.unlock()
    }
    private func status(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.view?.status.stringValue = text }
    }
    func start(replay: URL? = nil, report: URL? = nil) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Camera eye-contact processing")
        if let replay {
            queue.async { [weak self] in self?.replay(replay,report: report) }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: queue.async { [weak self] in self?.configure() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
                if allowed { self?.queue.async { self?.configure() } }
                else { self?.status("Camera access was not granted") }
            }
        default: status("Allow camera access in System Settings, then reopen this app")
        }
    }
    private func configure() {
        do {
            guard let camera = AVCaptureDevice.default(for:.video) else { throw PipelineError.invalid("No camera available") }
            cameraID = camera.uniqueID
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            let input = try AVCaptureDeviceInput(device:camera)
            guard session.canAddInput(input) else { throw PipelineError.invalid("Cannot open camera input") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self,queue:queue)
            guard session.canAddOutput(output) else { throw PipelineError.invalid("Cannot open camera output") }
            session.addOutput(output)
            if let connection = output.connection(with:.video), connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            session.commitConfiguration()
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 24 && $0.maxFrameRate >= 24 }) {
                try camera.lockForConfiguration()
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
                camera.unlockForConfiguration()
            }
            session.startRunning()
        } catch { status(error.localizedDescription) }
    }
    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            worker?.stop(); worker = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sample: CMSampleBuffer,from connection: AVCaptureConnection) {
        process(sample,live:true)
    }
    func captureOutput(_ output: AVCaptureOutput,didDrop sample: CMSampleBuffer,from connection: AVCaptureConnection) {
        dropped += 1
    }
    private func process(_ sample: CMSampleBuffer,live: Bool) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let ci = CIImage(cvPixelBuffer:buffer)
        guard let image = context.createCGImage(ci,from:ci.extent) else { return }
        let captureTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if origin == nil { origin = captureTime }
        let timestamp = captureTime-origin!
        lock.lock()
        let mode = selectedMode, engine = selectedEngine, key = profileName, newRevision = revision
        let command = pendingCommand; pendingCommand = nil
        lock.unlock()
        var rendered = image
        var text = "Original"
        do {
            if workerFailed && activeRevision == newRevision { throw PipelineError.invalid("Worker stopped; Apply profile to retry") }
            if worker == nil || activeRevision != newRevision {
                activeRevision = newRevision
                worker?.stop()
                let signature = cameraID+"/"+key
                let hash = SHA256.hash(data:Data(signature.utf8)).map { String(format:"%02x",$0) }.joined()
                let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("GazeEffect/Profiles")
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                worker = try GazePipelineBridge(engine:engine,context:signature,calibrationPath:folder.appendingPathComponent(hash+".json").path)
                activeRevision = newRevision
                workerFailed = false
            }
            let result = try worker!.processFrame(image,frameID:frameID,timestamp:timestamp,command:command,renderMode:mode==2 ? "debug":"effect")
            let age = live ? max(0,CMClockGetTime(CMClockGetHostTimeClock()).seconds-captureTime)*1000 : result.elapsedMS
            latencies.append(age)
            if live && latencies.count > 1200 { latencies.removeFirst(600) }
            // Always display the matching source frame if a result misses the live budget.
            let late = live && age>150 && frameID>0
            rendered = mode==0 || late ? image : result.image
            text = "Frame \(frameID) · \(String(format:"%.1f",result.elapsedMS)) ms · \(result.record["calibration"] as? String ?? "automatic")"
            if late { text += " · late result: original" }
            if !live { records.append(result.record) }
        } catch {
            workerFailed = true
            text = "Original · \(error.localizedDescription) · Apply profile to retry"
            // Preserve the source; no old corrected frame is reused.
        }
        frameID += 1
        DispatchQueue.main.async { [weak self] in
            self?.view?.imageView.image = NSImage(cgImage:rendered,size:.zero)
            self?.view?.status.stringValue = text
        }
    }
    private func replay(_ url: URL,report: URL?) {
        do {
            let asset = AVURLAsset(url:url)
            guard let track = asset.tracks(withMediaType:.video).first else { throw PipelineError.invalid("Replay has no video track") }
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? PipelineError.invalid("Replay could not start") }
            while let sample = output.copyNextSampleBuffer() { autoreleasepool { process(sample,live:false) } }
            guard reader.status == .completed else { throw reader.error ?? PipelineError.invalid("Replay did not complete") }
            worker?.stop(); worker = nil
            if let report {
                try FileManager.default.createDirectory(at:report,withIntermediateDirectories:true)
                let result: [String:Any] = ["source":"AVAssetReader replay through camera processing path","frames":frameID,"successfulFrames":records.count,"dropped":dropped,"latenciesMS":latencies,"records":records]
                try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:report.appendingPathComponent("replay.json"))
                DispatchQueue.main.async { [weak self] in
                    guard let view = self?.view, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:report.appendingPathComponent("preview.png"))
                    NSApp.terminate(nil)
                }
            }
            status("Replay complete: \(records.count)/\(frameID) matched frames")
        } catch { status("Replay failed: \(error.localizedDescription)") }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var controller: CameraController?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let view = PreviewView(frame:NSRect(x:0,y:0,width:1120,height:722))
        let window = NSWindow(contentRect:view.bounds,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Gaze Effect · Automatic Eye Contact"
        window.contentMinSize = NSSize(width:1080,height:620)
        window.contentView = view
        window.setFrameAutosaveName("GazeEffectV2")
        window.orderFront(nil)
        self.window = window
        let args = CommandLine.arguments
        func value(_ flag:String) -> URL? {
            guard let i=args.firstIndex(of:flag),i+1<args.count else { return nil }
            return URL(fileURLWithPath:args[i+1])
        }
        controller = CameraController(view:view)
        controller?.start(replay:value("--replay"),report:value("--report"))
    }
    func applicationWillTerminate(_ notification:Notification) { controller?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
