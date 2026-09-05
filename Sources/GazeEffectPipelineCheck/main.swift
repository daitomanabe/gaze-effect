import Foundation
import CoreGraphics
import ImageIO
import GazeEffectBridge

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("Usage: GazeEffectPipelineCheck input.png output.png") }
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let pipeline = try GazePipelineBridge(engine: "hybrid", context: "runtime-check")
var timings: [Double] = []
var frame: PipelineFrame?
for i in 0..<8 {
    frame = try pipeline.processFrame(image, frameID: i, timestamp: Double(i)/30)
    precondition(frame!.image.width == image.width && frame!.image.height == image.height)
    precondition(frame!.record["frameID"] as? Int == i)
    timings.append(frame!.elapsedMS)
}
pipeline.stop()
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, frame!.image, nil)
precondition(CGImageDestinationFinalize(dest))
let report: [String: Any] = ["frames": 8, "matchedFrameIDs": true, "matchedTimestamps": true, "bridgeMS": timings, "lastRecord": frame!.record]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[2] + ".json"))
print("GazeEffectPipelineCheck passed: 8 matched frames; worker stopped")

if args.contains("--check-timeout") {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gaze-worker-timeout-" + UUID().uuidString)
    let scripts = temporary.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    // A controlled worker replies once, then stops consuming the input pipe.
    let fixture = """
    import sys, struct, json, time
    def read_exact(n):
        result=bytearray()
        while len(result)<n:
            result.extend(sys.stdin.buffer.read(n-len(result)))
        return bytes(result)
    size=struct.unpack('<I',read_exact(4))[0]
    header=read_exact(size)
    request=json.loads(header)
    pixels=read_exact(request['width']*request['height']*3)
    sys.stdout.buffer.write(struct.pack('<I',len(header))+header+pixels)
    sys.stdout.buffer.flush()
    time.sleep(60)
    """
    try fixture.write(to: scripts.appendingPathComponent("gaze-worker.py"), atomically: true, encoding: .utf8)
    let stalled = try GazePipelineBridge(root: temporary, engine: "geometry")
    _ = try stalled.processFrame(image, frameID: 0, timestamp: 0)
    let start = Date()
    do {
        _ = try stalled.processFrame(image, frameID: 1, timestamp: 1.0/30)
        fatalError("Stalled input unexpectedly succeeded")
    } catch {
        let elapsed = Date().timeIntervalSince(start)
        precondition(error.localizedDescription.contains("timed out"))
        precondition(elapsed >= 2.8 && elapsed < 4.5)
        print("GazeEffectPipelineCheck timeout passed: stopped blocked worker input in \(elapsed) seconds")
    }
    stalled.stop()
}
