//
//  BatchInFlightRequests.swift
//  Spotifly
//
//  Single-flight registry for async work that covers many IDs at once.
//

import Foundation

/// Runs at most one operation per ID at a time, where one run covers a whole batch.
///
/// This is the many-IDs sibling of `InFlightRequests`, and exists because that registry
/// maps one key to one run. A `/v1/tracks` or `/me/tracks/contains` request carries
/// *many* IDs, and the next caller arrives with an overlapping but different set — it
/// has to join the runs already carrying some of its IDs and start one run for the rest.
/// Teaching `InFlightRequests` that many-to-one key relation would complicate it for
/// every caller that does not need it.
///
/// Deduplication matters here because the store alone does not provide it: it is only
/// written when a request *returns*, so two views asking about the same track in the
/// same frame — a row and the now-playing bar, say — both see it missing and both ask.
///
/// The runs are unstructured tasks, so they do not inherit their caller's cancellation.
/// SwiftUI cancels a view's `.task` whenever the view is torn down, and the result is
/// still useful to the queue and to whatever view replaces the one that went away.
@MainActor
final class BatchInFlightRequests {
    private var running: [String: (id: UUID, task: Task<Void, Error>)] = [:]

    /// Awaits every run covering an ID in `ids`, first starting one run for the IDs
    /// that no current run covers. `operation` receives exactly those uncovered IDs.
    ///
    /// A failure reaches every caller joined to the run, and the entries are dropped
    /// either way, so the next caller retries rather than inheriting the failure.
    func run(
        _ ids: [String],
        operation: @escaping @Sendable @MainActor ([String]) async throws -> Void,
    ) async throws {
        var joined: [(id: UUID, task: Task<Void, Error>)] = []
        var joinedRunIds = Set<UUID>()
        var uncoveredIds: [String] = []

        for id in ids {
            if let existing = running[id] {
                if joinedRunIds.insert(existing.id).inserted {
                    joined.append(existing)
                }
            } else {
                uncoveredIds.append(id)
            }
        }

        if !uncoveredIds.isEmpty {
            let runId = UUID()
            let task = Task { @MainActor in
                // Identity check: this run's cleanup must only drop its own entries,
                // never a successor that has since claimed the same ID.
                defer {
                    for id in uncoveredIds where self.running[id]?.id == runId {
                        self.running[id] = nil
                    }
                }
                try await operation(uncoveredIds)
            }
            let entry = (runId, task)
            for id in uncoveredIds {
                running[id] = entry
            }
            joined.append(entry)
        }

        for entry in joined {
            try await entry.task.value
        }
    }
}
