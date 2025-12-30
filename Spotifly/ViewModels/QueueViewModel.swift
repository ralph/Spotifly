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
    var errorMessage: String?

    func loadQueue() {
        errorMessage = nil

        do {
            queueItems = try SpotifyPlayer.getAllQueueItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        loadQueue()
    }
}
