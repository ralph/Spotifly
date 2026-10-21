//
//  AudioOutputDevice.swift
//  Spotifly
//
//  The Mac's default output device, from Core Audio
//

import CoreAudio

/// The Mac's default output device, as Sound settings names it.
nonisolated enum AudioOutputDevice {
    private static let defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    /// The name now, then again each time the default output changes, as from Control Center or
    /// plugging in headphones, until the iteration ends.
    static func names() -> AsyncStream<String?> {
        AsyncStream { continuation in
            continuation.yield(defaultName())
            // `@Sendable`, on a queue of its own: Core Audio calls it off the main thread, and a
            // block that inherits the main actor traps on the first switch.
            let queue = DispatchQueue(label: "AudioOutputDevice")
            let listener: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
                continuation.yield(defaultName())
            }
            var address = defaultOutput
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            continuation.onTermination = { _ in
                var address = defaultOutput
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            }
        }
    }

    /// Its name, such as "MacBook Pro-Lautsprecher", or nil if Core Audio names none.
    static func defaultName() -> String? {
        var deviceId = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutput
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceId) == noErr,
              deviceId != kAudioObjectUnknown
        else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, &name) == noErr,
              let name
        else { return nil }
        return name.takeRetainedValue() as String
    }
}
