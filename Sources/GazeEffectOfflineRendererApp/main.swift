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
    var calibrationPath: String
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
        window.orderFront(nil)

        self.window = window
        self.rendererView = content

        NSApp.setActivationPolicy(.regular)
        let args = CommandLine.arguments
        if let input = args.firstIndex(of: "--render-input"), input+1 < args.count,
           let output = args.firstIndex(of: "--render-output"), output+1 < args.count,
           let report = args.firstIndex(of: "--report"), report+1 < args.count {
            content.renderFromArguments(input: args[input+1], output: args[output+1], report: args[report+1])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class OfflineRendererView: NSView {
    private let inputField = NSTextField()
    private let outputField = NSTextField()
    private let detectorControl = NSSegmentedControl(labels: ["Local warp", "Automatic"], trackingMode: .selectOne, target: nil, action: nil)
    private let renderModePopup = NSPopUpButton()
    private let calibrationField = NSTextField()
    private let chooseCalibrationButton = NSButton(title: "Choose profile", target: nil, action: nil)
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
            calibrationField.isEnabled = !isRunning
            chooseCalibrationButton.isEnabled = !isRunning
        }
    }
    private var reportURL: URL?

    func renderFromArguments(input: String, output: String, report: String) {
        inputField.stringValue = input
        outputField.stringValue = output
        reportURL = URL(fileURLWithPath: report)
        startRender()
    }

    private func finishArgumentRun(error: String?) {
        guard let reportURL else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: reportURL, withIntermediateDirectories: true)
                let result: [String: Any] = ["success": error == nil, "error": error as Any? ?? NSNull(),
                                           "input": self.inputField.stringValue, "output": self.outputField.stringValue]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: reportURL.appendingPathComponent("result.json"))
                try self.logView.string.write(to: reportURL.appendingPathComponent("render.log"), atomically: true, encoding: .utf8)
                if let bitmap = self.bitmapImageRepForCachingDisplay(in: self.bounds) {
                    self.cacheDisplay(in: self.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: reportURL.appendingPathComponent("preview.png"))
                }
            } catch { self.appendLog("Report error: \(error.localizedDescription)\n") }
            NSApp.terminate(nil)
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
        layoutLabel("Method", x: inset, y: y, width: labelWidth)
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

        y += rowHeight + 12
        calibrationField.frame = NSRect(x: inset, y: y, width: contentWidth - 150, height: rowHeight)
        chooseCalibrationButton.frame = NSRect(x: bounds.width - inset - 138, y: y, width: 138, height: rowHeight)
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
        detectorControl.toolTip = "Automatic evaluates learned eye warping and falls back to local geometry when needed."
        addSubview(detectorControl)

        for mode in OfflineRenderMode.allCases {
            renderModePopup.addItem(withTitle: mode.label)
        }
        renderModePopup.selectItem(at: 0)
        addSubview(renderModePopup)

        strengthField.stringValue = "1.0"
        maxWidthField.stringValue = "0"
        maxWidthField.toolTip = "0 keeps the original resolution"
        calibrationField.placeholderString = "Optional calibration JSON; empty uses automatic mode"
        addSubview(calibrationField)
        chooseCalibrationButton.target = self
        chooseCalibrationButton.action = #selector(chooseCalibration)
        addSubview(chooseCalibrationButton)
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
            strength: min(1, max(0, Double(strengthField.stringValue) ?? 1)),
            maxWidth: max(0, Int(maxWidthField.stringValue) ?? 0),
            calibrationPath: calibrationField.stringValue
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
                    self?.finishArgumentRun(error: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.appendLog("Error: \(error.localizedDescription)\n")
                    self?.isRunning = false
                    self?.finishArgumentRun(error: error.localizedDescription)
                }
            }
        }
    }

    @objc private func openOutput() {
        let url = URL(fileURLWithPath: outputField.stringValue)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func chooseCalibration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { calibrationField.stringValue = url.path }
    }

    private func performRender(settings: RenderSettings) throws {
        guard FileManager.default.fileExists(atPath: settings.inputURL.path) else {
            throw OfflineRendererError.missingInput(settings.inputURL.path)
        }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("scripts/render-gaze-video.py")
        let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? repoRootURL.appendingPathComponent("scripts/render-gaze-video.py")
        let bundledModels = Bundle.main.resourceURL?.appendingPathComponent("models")
        let models = bundledModels.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("face_landmarker.task").path) ? $0 : nil }
            ?? repoRootURL.appendingPathComponent("Assets/models")
        let localPython = repoRootURL.appendingPathComponent(".venv/bin/python3").path
        let python = ProcessInfo.processInfo.environment["GAZE_EFFECT_PYTHON"] ?? (FileManager.default.isExecutableFile(atPath: localPython) ? localPython : "/opt/homebrew/bin/python3")
        var arguments = ["-B", script.path, "--input", settings.inputURL.path, "--output", settings.outputURL.path,
                         "--models", models.path, "--engine", settings.detectorMode == .realtime ? "geometry" : "hybrid",
                         "--strength", String(settings.strength), "--max-width", String(settings.maxWidth),
                         "--render-mode", settings.renderMode.rawValue, "--comparison", "--debug-video"]
        if !settings.calibrationPath.isEmpty {
            arguments += ["--calibration", settings.calibrationPath]
            if let data = FileManager.default.contents(atPath: settings.calibrationPath),
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let signature = json["signature"] as? [String: Any], let context = signature["context"] as? String {
                arguments += ["--context", context]
            }
        }
        appendLog("Processing all frames at original timestamps with audio. Width 0 preserves source size.\n")
        try run(python, arguments: arguments, currentDirectory: repoRootURL)
    }

    private func run(_ executable: String, arguments: [String], currentDirectory: URL) throws {
        let commandLine = ([executable] + arguments).joined(separator: " ")
        appendLog("\n$ \(commandLine)\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
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

    private static func defaultRepoRootURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["GAZE_EFFECT_ROOT"] {
            return URL(fileURLWithPath: path)
        }
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
