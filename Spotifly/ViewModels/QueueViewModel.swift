//
//  QueueViewModel.swift
//  Spotifly
//
//  Manages current playback queue state
//

import SwiftUI

@MainActor
@Observable
final class QueueViewModel {
    var queueItems: [QueueItem] = []
    var currentIndex: Int = 0
    var errorMessage: String?

    func loadQueue() {
        errorMessage = nil

        do {
            queueItems = try SpotifyPlayer.getAllQueueItems()
            currentIndex = SpotifyPlayer.currentIndex
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        loadQueue()
    }
}
