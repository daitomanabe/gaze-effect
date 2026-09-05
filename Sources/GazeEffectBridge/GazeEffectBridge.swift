import Foundation
import CoreGraphics
import Darwin

public struct PipelineFrame {
    public let image: CGImage
    public let record: [String: Any]
    public let elapsedMS: Double
}

public enum PipelineError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// A single caller owns the worker. No sockets, frame queue, or shared latest-result state.
public final class GazePipelineBridge {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var started = false
    private var firstRequest = true
    public let root: URL

    public static func repositoryRoot() -> URL {
        if let path = ProcessInfo.processInfo.environment["GAZE_EFFECT_ROOT"] {
            return URL(fileURLWithPath: path)
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    public init(root: URL = GazePipelineBridge.repositoryRoot(), engine: String = "hybrid", context: String = "default", calibrationPath: String? = nil) throws {
        self.root = root
        signal(SIGPIPE, SIG_IGN)
        let localPython = root.appendingPathComponent(".venv/bin/python3").path
        let python = ProcessInfo.processInfo.environment["GAZE_EFFECT_PYTHON"] ?? (FileManager.default.isExecutableFile(atPath: localPython) ? localPython : "/opt/homebrew/bin/python3")
        let resources = Bundle.main.resourceURL
        let bundled = resources?.appendingPathComponent("scripts/gaze-worker.py")
        let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? root.appendingPathComponent("scripts/gaze-worker.py")
        let bundledModels = resources?.appendingPathComponent("models")
        let models = bundledModels.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("face_landmarker.task").path) ? $0 : nil } ?? root.appendingPathComponent("Assets/models")
        guard FileManager.default.isExecutableFile(atPath: python), FileManager.default.fileExists(atPath: script.path) else {
            throw PipelineError.invalid("Python or the Gaze Effect worker is missing. Run the setup instructions in README.")
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script.path, "--models", models.path, "--engine", engine, "--context", context]
        if let calibrationPath { process.arguments! += ["--calibration", calibrationPath] }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        try process.run()
        started = true
        // Only the child's corresponding handles should keep these pipe ends open.
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let inputFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
    }

    deinit { stop() }

    public func stop() {
        guard started else { return }
        started = false
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    private func readExactly(_ count: Int, deadline: Date) throws -> Data {
        guard count >= 0, count <= 128 * 1024 * 1024 else { throw PipelineError.invalid("Invalid worker payload size") }
        var result = Data(count: count)
        var offset = 0
        let fd = output.fileHandleForReading.fileDescriptor
        try result.withUnsafeMutableBytes { raw in
            while offset < count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw PipelineError.invalid("Gaze analysis timed out") }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let polled = poll(&descriptor, 1, Int32(min(remaining * 1000, 500)))
                if polled < 0 && errno != EINTR { throw PipelineError.invalid("Worker pipe polling failed") }
                if polled <= 0 { continue }
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                if n == 0 { throw PipelineError.invalid("Gaze worker stopped before completing the frame") }
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw PipelineError.invalid("Gaze worker read failed")
                }
                offset += n
            }
        }
        return result
    }

    private func writeExactly(_ data: Data, deadline: Date) throws {
        let fd = input.fileHandleForWriting.fileDescriptor
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < data.count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw PipelineError.invalid("Gaze worker input timed out") }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&descriptor, 1, Int32(min(remaining * 1000, 500)))
                if polled < 0 && errno != EINTR { throw PipelineError.invalid("Worker input polling failed") }
                if polled <= 0 { continue }
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count-offset)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw PipelineError.invalid("Gaze worker input closed")
                }
                offset += n
            }
        }
    }

    public func processFrame(_ image: CGImage, frameID: Int, timestamp: Double, command: String? = nil, renderMode: String = "effect") throws -> PipelineFrame {
        guard started, process.isRunning else { throw PipelineError.invalid("Gaze worker is not running") }
        let start = Date()
        let width = image.width, height = image.height
        guard width <= 7680, height <= 4320 else { throw PipelineError.invalid("Frame is too large") }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let valid = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let cg = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard valid else { throw PipelineError.invalid("Could not read source image") }
        var bgr = Data(count: width * height * 3)
        bgr.withUnsafeMutableBytes { bytes in
            let p = bytes.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                p[i*3] = rgba[i*4+2]; p[i*3+1] = rgba[i*4+1]; p[i*3+2] = rgba[i*4]
            }
        }
        var header: [String: Any] = ["width": width, "height": height, "frameID": frameID, "timestamp": timestamp, "renderMode": renderMode]
        if let command { header["command"] = command }
        let json = try JSONSerialization.data(withJSONObject: header)
        var size = UInt32(json.count).littleEndian
        do {
            let deadline = Date().addingTimeInterval(firstRequest ? 30 : 3)
            firstRequest = false
            try writeExactly(withUnsafeBytes(of: &size) { Data($0) }, deadline: deadline)
            try writeExactly(json, deadline: deadline)
            try writeExactly(bgr, deadline: deadline)
            let length = try readExactly(4, deadline: deadline).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            guard length <= 4 * 1024 * 1024 else { throw PipelineError.invalid("Worker metadata is oversized") }
            let recordData = try readExactly(Int(length), deadline: deadline)
            guard let record = try JSONSerialization.jsonObject(with: recordData) as? [String: Any],
                  (record["frameID"] as? Int) == frameID,
                  let returnedTimestamp = record["timestamp"] as? Double, abs(returnedTimestamp-timestamp) < 0.000001 else {
                throw PipelineError.invalid("Worker returned a mismatched frame or timestamp")
            }
            let pixels = try readExactly(width * height * 3, deadline: deadline)
            pixels.withUnsafeBytes { bytes in
                let p = bytes.bindMemory(to: UInt8.self)
                for i in 0..<(width * height) {
                    rgba[i*4] = p[i*3+2]; rgba[i*4+1] = p[i*3+1]; rgba[i*4+2] = p[i*3]; rgba[i*4+3] = 255
                }
            }
            let data = Data(rgba) as CFData
            guard let provider = CGDataProvider(data: data), let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw PipelineError.invalid("Could not create processed image")
            }
            return PipelineFrame(image: result, record: record, elapsedMS: Date().timeIntervalSince(start) * 1000)
        } catch {
            stop()
            throw error
        }
    }
}
