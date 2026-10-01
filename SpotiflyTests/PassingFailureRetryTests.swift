//
//  PassingFailureRetryTests.swift
//  SpotiflyTests
//
//  A read that fails while the network stays up is asked for again, a few times.
//

import Foundation
@testable import Spotifly
import Testing

struct PassingFailureRetryTests {
    private let searchPayload = Data(#"""
    {"data":{"searchV2":{"tracksV2":{"totalCount":1,
      "items":[{"item":{"data":{"uri":"spotify:track:t1","name":"Good"}}}]}}}}
    """#.utf8)

    /// Answers each attempt in turn from `answers`, the last one for every attempt after it, a
    /// 200 with the search payload. spclient's CORS preflight goes through unless
    /// `answeringPreflight`, which gives it the answers instead.
    private func transport(
        _ answers: [Result<Int, URLError>],
        answeringPreflight: Bool = false,
        attempts: Tally,
    ) -> PartnerAPI.Transport {
        { request in
            let index = min(attempts.count, answers.count - 1)
            if request.httpMethod == "OPTIONS", !answeringPreflight {
                return (Data(), httpResponse(200, url: request.url!))
            }
            attempts.increment()
            switch answers[index] {
            case let .success(status):
                return (status == 200 ? searchPayload : Data(), httpResponse(status, url: request.url!))
            case let .failure(error):
                throw error
            }
        }
    }

    @Test func `a server error is asked for again, and the answer that follows is used`() async throws {
        let attempts = Tally()
        let pauses = Recorder<Duration>()
        let api = partnerAPI(pause: { pauses.record($0) }, transport: transport([.success(503), .success(200)], attempts: attempts))

        let results = try await api.searchTracks("x")

        #expect(results.first?.name == "Good")
        #expect(attempts.count == 2)
        #expect(pauses.values == [.seconds(1)])
    }

    @Test func `a failure that goes on is reported after the last retry, with growing pauses`() async throws {
        let attempts = Tally()
        let pauses = Recorder<Duration>()
        let api = partnerAPI(pause: { pauses.record($0) }, transport: transport([.success(500)], attempts: attempts))

        await #expect(throws: PartnerAPIError.requestFailed(500, "")) {
            _ = try await api.searchTracks("x")
        }
        #expect(attempts.count == 3)
        #expect(pauses.values == [.seconds(1), .seconds(3)])
    }

    @Test func `a connection that dropped or could not be made is asked for again`() async throws {
        for code in [URLError.Code.networkConnectionLost, .cannotConnectToHost] {
            let attempts = Tally()
            let api = partnerAPI(transport: transport([.failure(URLError(code)), .success(200)], attempts: attempts))

            _ = try await api.searchTracks("x")

            #expect(attempts.count == 2, "\(code)")
        }
    }

    /// A 404 answers the same every time. A 429 is a limit on the whole client, which asking
    /// again at once only adds to.
    @Test func `an answer that would not change, or a rate limit, is not asked for again`() async throws {
        for status in [404, 429] {
            let attempts = Tally()
            let api = partnerAPI(transport: transport([.success(status)], attempts: attempts))

            await #expect(throws: PartnerAPIError.self) {
                _ = try await api.searchTracks("x")
            }
            #expect(attempts.count == 1, "\(status)")
        }
    }

    /// A timeout has already waited a minute; two more would keep the page waiting three.
    @Test func `a request that timed out is not asked for again`() async throws {
        let attempts = Tally()
        let api = partnerAPI(transport: transport([.failure(URLError(.timedOut))], attempts: attempts))

        await #expect(throws: URLError.self) {
            _ = try await api.searchTracks("x")
        }
        #expect(attempts.count == 1)
    }

    /// The network's return asks again, so failing at once shows the error at once.
    @Test func `a request made with no network is not asked for again`() async throws {
        let attempts = Tally()
        let api = partnerAPI(transport: transport([.failure(URLError(.notConnectedToInternet))], attempts: attempts))

        await #expect(throws: URLError.self) {
            _ = try await api.searchTracks("x")
        }
        #expect(attempts.count == 1)
    }

    /// A write that failed may have happened, and must not happen twice: a save asked again
    /// could land after the remove that undid it.
    @Test func `a playlist change or a library save is not asked for again`() async throws {
        let playlist = Tally()
        let changes = partnerAPI(transport: transport([.success(503)], attempts: playlist))
        await #expect(throws: PartnerAPIError.self) {
            try await changes.addToPlaylist(playlistId: "p", trackUris: ["spotify:track:t1"])
        }
        #expect(playlist.count == 1)

        let library = Tally()
        let saves = partnerAPI(transport: transport([.success(503)], attempts: library))
        await #expect(throws: PartnerAPIError.self) {
            try await saves.addToLibrary(uris: ["spotify:track:t1"])
        }
        #expect(library.count == 1)
    }

    /// Every heart on screen asks on its own, and a failed check leaves the heart as it was.
    @Test func `a check of what is in the library is not asked for again`() async throws {
        let attempts = Tally()
        let api = partnerAPI(transport: transport([.success(503)], attempts: attempts))

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.entitiesInLibrary(uris: ["spotify:track:t1"])
        }
        #expect(attempts.count == 1)
    }

    @Test func `spclient's reads are asked for again, and its writes are not`() async throws {
        let reads = Tally()
        let read = spclientAPI(transport: transport([.success(502)], attempts: reads))
        await #expect(throws: SpclientError.self) {
            _ = try await read.track(id: "4PTG3Z6ehGkBFwjybzWkR8")
        }
        #expect(reads.count == 3)

        // The preflight goes first, so a server error meets it there.
        let preflights = Tally()
        let preflighted = spclientAPI(transport: transport([.success(503)], answeringPreflight: true, attempts: preflights))
        await #expect(throws: SpclientError.self) {
            _ = try await preflighted.track(id: "4PTG3Z6ehGkBFwjybzWkR8")
        }
        #expect(preflights.count == 3)

        let writes = Tally()
        let write = spclientAPI(transport: transport([.success(502)], attempts: writes))
        await #expect(throws: SpclientError.self) {
            _ = try await write.createPlaylist(name: "New")
        }
        #expect(writes.count == 1)
    }
}
