// Plays -120 dB noise through the app's AudioRenderer for `seconds`, fed the way
// AudioPipeline feeds it: 4096-frame chunks, each enqueue awaited. With `pause`,
// playback pauses for 4 s after 3 s. For revisions before the renderer took
// enqueue (macOS 27), run.sh builds legacy.swift instead.
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let seconds = Double(arguments.first ?? "75") ?? 75
let pauses = arguments.contains("pause")

let renderer = AudioRenderer()
await renderer.restart(paused: false)

_ = Task {
    let frames = 4096
    var samples = [Float](repeating: 0, count: frames * 2)
    var seed: UInt32 = 1
    while !Task.isCancelled {
        for i in samples.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            samples[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2e-6
        }
        let pcm = samples.withUnsafeBytes { Data($0) }
        _ = await renderer.enqueue(pcm, frames: frames)
    }
}

let start = ProcessInfo.processInfo.systemUptime
var pausedFor = 0.0
if pauses {
    try await Task.sleep(for: .seconds(3))
    await renderer.pause()
    try await Task.sleep(for: .seconds(4))
    await renderer.resume()
    pausedFor = 4
}

try await Task.sleep(for: .seconds(seconds - (ProcessInfo.processInfo.systemUptime - start)))
let played = Double(renderer.playedFrames) / 44100
let playing = ProcessInfo.processInfo.systemUptime - start - pausedFor
print(String(format: "played %.2f s of audio in %.2f s of playback", played, playing))
exit(0)
