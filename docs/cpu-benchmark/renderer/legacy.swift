// main.swift for revisions before the macOS 27 renderer, which were written to
// through AudioSink: plays -120 dB noise for `seconds`, written the way the
// decode thread wrote it, 2048-frame chunks as fast as `write` allowed, parked
// while paused. With `pause`, playback pauses for 4 s after 3 s.
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let seconds = Double(arguments.first ?? "75") ?? 75
let pauses = arguments.contains("pause")

nonisolated(unsafe) var paused = false
let renderer = AudioRenderer()
renderer.start()

let writer = Thread {
    let frames = 2048
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    var seed: UInt32 = 1
    while true {
        while paused {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for i in 0 ..< frames * 2 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            buffer[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2e-6
        }
        renderer.write(samples: buffer, count: frames * 2)
    }
}

writer.start()

let start = ProcessInfo.processInfo.systemUptime
var pausedFor = 0.0
if pauses {
    Thread.sleep(forTimeInterval: 3)
    paused = true
    renderer.stop()
    Thread.sleep(forTimeInterval: 4)
    paused = false
    renderer.resume()
    pausedFor = 4
}

Thread.sleep(forTimeInterval: seconds - (ProcessInfo.processInfo.systemUptime - start))
let played = Double(renderer.playedFramesSinceStart) / 44100
let playing = ProcessInfo.processInfo.systemUptime - start - pausedFor
print(String(format: "played %.2f s of audio in %.2f s of playback", played, playing))
exit(0)
