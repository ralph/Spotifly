import Testing

@testable import Spotifly

@MainActor
struct PlaybackViewModelReconnectTests {
    @Test func prepareForReconnectRecoveryClearsStaleResumeState() {
        let vm = PlaybackViewModel.shared
        vm.currentTrackUri = "spotify:track:stale"
        vm.isPlaying = false
        vm.trackDurationMs = 123_000
        vm.currentPositionMs = 45_000
        vm.errorMessage = "stale"
        vm.remoteVolume = 0.75

        vm.prepareForReconnectRecovery()

        #expect(vm.currentTrackUri == nil)
        #expect(vm.isPlaying == false)
        #expect(vm.trackDurationMs == 0)
        #expect(vm.currentPositionMs == 0)
        #expect(vm.errorMessage == nil)
        #expect(vm.remoteVolume == nil)
    }
}
