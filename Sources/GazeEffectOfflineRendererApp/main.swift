import AppKit
import Foundation
import UniformTypeIdentifiers

private enum DetectorMode: String {
    case realtime
    case offline

    var fillMode: String {
        switch self {
        case .realtime:
            return "realtime"
        case .offline:
            return "inpaint"
        }
    }
}

private enum OfflineRenderMode: String, CaseIterable {
    case effect
    case whiteEyes = "white-eyes"
    case whiteEyesRedPupils = "white-eyes-red-pupils"

    var label: String {
        switch self {
        case .effect:
            return "Effect"
        case .whiteEyes:
            return "White eyes"
        case .whiteEyesRedPupils:
            return "White eyes + red pupils"
        }
    }
}

private struct RenderSettings {
    var inputURL: URL
    var outputURL: URL
    var detectorMode: DetectorMode
    var renderMode: OfflineRenderMode
    var strength: Double
    var maxWidth: Int
}

private enum OfflineRendererError: LocalizedError {
    case missingInput(String)
    case missingHelper(String)
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .missingInput(let path):
            return "Input file does not exist: \(path)"
        case .missingHelper(let path):
            return "Required helper was not found: \(path)"
        case .commandFailed(let command, let status):
            return "Command failed with status \(status): \(command)"
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var rendererView: OfflineRendererView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = OfflineRendererView(frame: NSRect(x: 0, y: 0, width: 920, height: 660))
        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Gaze Effect Offline Renderer"
        window.contentMinSize = NSSize(width: 780, height: 560)
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.rendererView = content

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class OfflineRendererView: NSView {
    private let inputField = NSTextField()
    private let outputField = NSTextField()
    private let detectorControl = NSSegmentedControl(labels: ["Realtime", "Offline"], trackingMode: .selectOne, target: nil, action: nil)
    private let renderModePopup = NSPopUpButton()
    private let strengthField = NSTextField()
    private let maxWidthField = NSTextField()
    private let runButton = NSButton(title: "Render", target: nil, action: nil)
    private let openOutputButton = NSButton(title: "Open Output", target: nil, action: nil)
    private let logScrollView = NSScrollView()
    private let logView = NSTextView()
    private let repoRootURL: URL

    private var isRunning = false {
        didSet {
            runButton.isEnabled = !isRunning
            detectorControl.isEnabled = !isRunning
            renderModePopup.isEnabled = !isRunning
            inputField.isEnabled = !isRunning
            outputField.isEnabled = !isRunning
            strengthField.isEnabled = !isRunning
            maxWidthField.isEnabled = !isRunning
        }
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        self.repoRootURL = Self.defaultRepoRootURL()
        super.init(frame: frameRect)
        configureSubviews()
        populateDefaults()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        let inset: CGFloat = 24
        let labelWidth: CGFloat = 112
        let buttonWidth: CGFloat = 92
        let rowHeight: CGFloat = 30
        let gap: CGFloat = 12
        var y: CGFloat = inset
        let contentWidth = bounds.width - inset * 2

        layoutLabel("Input video", x: inset, y: y, width: labelWidth)
        inputField.frame = NSRect(x: inset + labelWidth, y: y, width: contentWidth - labelWidth - buttonWidth - gap, height: rowHeight)
        viewWithTag(1001)?.frame = NSRect(x: bounds.width - inset - buttonWidth, y: y, width: buttonWidth, height: rowHeight)

        y += rowHeight + gap
        layoutLabel("Output MP4", x: inset, y: y, width: labelWidth)
        outputField.frame = NSRect(x: inset + labelWidth, y: y, width: contentWidth - labelWidth - buttonWidth - gap, height: rowHeight)
        viewWithTag(1002)?.frame = NSRect(x: bounds.width - inset - buttonWidth, y: y, width: buttonWidth, height: rowHeight)

        y += rowHeight + gap
        layoutLabel("Detector", x: inset, y: y, width: labelWidth)
        detectorControl.frame = NSRect(x: inset + labelWidth, y: y, width: 220, height: rowHeight)
        layoutLabel("Render", x: inset + labelWidth + 246, y: y, width: 68)
        renderModePopup.frame = NSRect(x: inset + labelWidth + 314, y: y, width: 220, height: rowHeight)

        y += rowHeight + gap
        layoutLabel("Strength", x: inset, y: y, width: labelWidth)
        strengthField.frame = NSRect(x: inset + labelWidth, y: y, width: 80, height: rowHeight)
        layoutLabel("Max width", x: inset + labelWidth + 114, y: y, width: 86)
        maxWidthField.frame = NSRect(x: inset + labelWidth + 202, y: y, width: 80, height: rowHeight)
        runButton.frame = NSRect(x: bounds.width - inset - 210, y: y, width: 96, height: rowHeight)
        openOutputButton.frame = NSRect(x: bounds.width - inset - 106, y: y, width: 106, height: rowHeight)

        y += rowHeight + 18
        logScrollView.frame = NSRect(x: inset, y: y, width: contentWidth, height: max(120, bounds.height - y - inset))
    }

    private func configureSubviews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        addLabel(tag: 2001)
        addLabel(tag: 2002)
        addLabel(tag: 2003)
        addLabel(tag: 2004)
        addLabel(tag: 2005)
        addLabel(tag: 2006)

        inputField.placeholderString = "Select an input movie"
        outputField.placeholderString = "Select output MP4"
        inputField.lineBreakMode = .byTruncatingMiddle
        outputField.lineBreakMode = .byTruncatingMiddle
        addSubview(inputField)
        addSubview(outputField)

        let chooseInput = NSButton(title: "Choose", target: self, action: #selector(chooseInputVideo))
        chooseInput.tag = 1001
        addSubview(chooseInput)

        let chooseOutput = NSButton(title: "Choose", target: self, action: #selector(chooseOutputVideo))
        chooseOutput.tag = 1002
        addSubview(chooseOutput)

        detectorControl.selectedSegment = 1
        detectorControl.toolTip = "Realtime uses MediaPipe iris landmarks. Offline adds dark-blob refinement and inpaint fill."
        addSubview(detectorControl)

        for mode in OfflineRenderMode.allCases {
            renderModePopup.addItem(withTitle: mode.label)
        }
        renderModePopup.selectItem(at: 0)
        addSubview(renderModePopup)

        strengthField.stringValue = "1.4"
        maxWidthField.stringValue = "480"
        addSubview(strengthField)
        addSubview(maxWidthField)

        runButton.target = self
        runButton.action = #selector(startRender)
        runButton.bezelStyle = .rounded
        addSubview(runButton)

        openOutputButton.target = self
        openOutputButton.action = #selector(openOutput)
        openOutputButton.bezelStyle = .rounded
        addSubview(openOutputButton)

        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.textColor = .labelColor
        logView.backgroundColor = .textBackgroundColor
        logScrollView.hasVerticalScroller = true
        logScrollView.borderType = .bezelBorder
        logScrollView.documentView = logView
        addSubview(logScrollView)
    }

    private func populateDefaults() {
        let defaultInput = repoRootURL.appendingPathComponent("Assets/test-video-2.mp4")
        let defaultOutput = repoRootURL.appendingPathComponent("build/offline-renderer/gaze-effect-offline-corrected.mp4")
        inputField.stringValue = defaultInput.path
        outputField.stringValue = defaultOutput.path
        appendLog("Repository: \(repoRootURL.path)\n")
        appendLog("Default input: \(defaultInput.path)\n")
    }

    private func addLabel(tag: Int) {
        let label = NSTextField(labelWithString: "")
        label.tag = tag
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        addSubview(label)
    }

    private func layoutLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        let tags = [2001, 2002, 2003, 2004, 2005, 2006]
        for tag in tags {
            guard let label = viewWithTag(tag) as? NSTextField, label.stringValue.isEmpty || label.stringValue == text else {
                continue
            }
            label.stringValue = text
            label.frame = NSRect(x: x, y: y + 6, width: width, height: 20)
            return
        }
    }

    @objc private func chooseInputVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.inputField.stringValue = url.path
        }
    }

    @objc private func chooseOutputVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = URL(fileURLWithPath: outputField.stringValue).lastPathComponent
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.outputField.stringValue = url.path
        }
    }

    @objc private func startRender() {
        guard !isRunning else {
            return
        }

        let detectorMode: DetectorMode = detectorControl.selectedSegment == 0 ? .realtime : .offline
        let renderMode = OfflineRenderMode.allCases[min(max(renderModePopup.indexOfSelectedItem, 0), OfflineRenderMode.allCases.count - 1)]
        let settings = RenderSettings(
            inputURL: URL(fileURLWithPath: inputField.stringValue),
            outputURL: URL(fileURLWithPath: outputField.stringValue),
            detectorMode: detectorMode,
            renderMode: renderMode,
            strength: Double(strengthField.stringValue) ?? 1.4,
            maxWidth: Int(maxWidthField.stringValue) ?? 480
        )

        logView.string = ""
        appendLog("Starting offline render\n")
        appendLog("Input: \(settings.inputURL.path)\n")
        appendLog("Output: \(settings.outputURL.path)\n")
        isRunning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.performRender(settings: settings)
                DispatchQueue.main.async {
                    self?.appendLog("Done\n")
                    self?.isRunning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self?.appendLog("Error: \(error.localizedDescription)\n")
                    self?.isRunning = false
                }
            }
        }
    }

    @objc private func openOutput() {
        let url = URL(fileURLWithPath: outputField.stringValue)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func performRender(settings: RenderSettings) throws {
        guard FileManager.default.fileExists(atPath: settings.inputURL.path) else {
            throw OfflineRendererError.missingInput(settings.inputURL.path)
        }

        let helperURL = try imageToolURL()
        let landmarksScriptURL = try mediapipeScriptURL()
        let outputParent = settings.outputURL.deletingLastPathComponent()
        let workURL = outputParent
            .appendingPathComponent(settings.outputURL.deletingPathExtension().lastPathComponent + "-work", isDirectory: true)
        let framesURL = workURL.appendingPathComponent("frames", isDirectory: true)
        let landmarksURL = workURL.appendingPathComponent("landmarks", isDirectory: true)
        let correctedURL = workURL.appendingPathComponent("corrected", isDirectory: true)

        try FileManager.default.createDirectory(at: outputParent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: workURL.path) {
            try FileManager.default.removeItem(at: workURL)
        }
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: landmarksURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: correctedURL, withIntermediateDirectories: true)

        appendLog("Work: \(workURL.path)\n")
        try run("/usr/bin/env", arguments: [
            "ffmpeg", "-y",
            "-i", settings.inputURL.path,
            "-vf", "fps=12,scale=\(settings.maxWidth):-2",
            framesURL.appendingPathComponent("frame-%05d.jpg").path
        ], currentDirectory: repoRootURL)

        try run("/usr/bin/env", arguments: [
            "python3", landmarksScriptURL.path,
            "--input-dir", framesURL.path,
            "--output-dir", landmarksURL.path,
            "--mode", settings.detectorMode.rawValue
        ], currentDirectory: repoRootURL)

        try run(helperURL.path, arguments: [
            "--input-dir", framesURL.path,
            "--output-dir", correctedURL.path,
            "--landmarks-dir", landmarksURL.path,
            "--max-width", String(settings.maxWidth),
            "--strength", String(format: "%.3f", settings.strength),
            "--fill-mode", settings.detectorMode.fillMode,
            "--render-mode", settings.renderMode.rawValue,
            "--verbose"
        ], currentDirectory: repoRootURL)

        try run("/usr/bin/env", arguments: [
            "ffmpeg", "-y",
            "-framerate", "36",
            "-i", correctedURL.appendingPathComponent("frame-%05d.jpg").path,
            "-an",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-profile:v", "main",
            "-level", "3.1",
            "-crf", "30",
            "-preset", "veryfast",
            "-movflags", "+faststart",
            settings.outputURL.path
        ], currentDirectory: repoRootURL)
    }

    private func run(_ executable: String, arguments: [String], currentDirectory: URL) throws {
        let commandLine = ([executable] + arguments).joined(separator: " ")
        appendLog("\n$ \(commandLine)\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else {
                return
            }
            self?.appendLog(message)
        }

        try process.run()
        process.waitUntilExit()
        handle.readabilityHandler = nil

        if process.terminationStatus != 0 {
            throw OfflineRendererError.commandFailed(commandLine, process.terminationStatus)
        }
    }

    private func appendLog(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.logView.string += text
            self.logView.scrollRangeToVisible(NSRange(location: self.logView.string.count, length: 0))
        }
    }

    private func imageToolURL() throws -> URL {
        let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("GazeEffectImageTool")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let localBuild = repoRootURL.appendingPathComponent(".build/release/GazeEffectImageTool")
        if FileManager.default.isExecutableFile(atPath: localBuild.path) {
            return localBuild
        }

        throw OfflineRendererError.missingHelper(bundled?.path ?? localBuild.path)
    }

    private func mediapipeScriptURL() throws -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("scripts/mediapipe-eye-landmarks.py")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        let repoScript = repoRootURL.appendingPathComponent("scripts/mediapipe-eye-landmarks.py")
        if FileManager.default.fileExists(atPath: repoScript.path) {
            return repoScript
        }

        throw OfflineRendererError.missingHelper(repoScript.path)
    }

    private static func defaultRepoRootURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
