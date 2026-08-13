//
//  LoopbackCallbackServer.swift
//  Spotifly
//
//  A one-shot HTTP listener on loopback, for OAuth redirects that are not a custom scheme.
//

import Foundation
import Network

/// Guards a one-time transition across threads, where the callback that performs it can fire
/// more than once: `NWListener` reports state repeatedly, and a connection can both deliver
/// and fail.
private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True exactly once, for the first caller.
    func claim() -> Bool {
        lock.withLock {
            if claimed {
                return false
            }
            claimed = true
            return true
        }
    }
}

/// Receives a single OAuth redirect on `http://127.0.0.1:<port>/login`.
///
/// `ASWebAuthenticationSession` cannot serve this flow: Spotify's desktop client id is
/// registered with a plain-HTTP loopback redirect rather than a custom scheme, and
/// `ASWebAuthenticationSession` only intercepts custom schemes and associated-domain HTTPS.
/// So the browser opens normally and the redirect lands here.
///
/// One request, one answer, then the listener closes — nothing about this outlives the grant.
/// The port is assigned by the system rather than fixed: Spotify accepts any loopback port for
/// a first-party client id, and a hardcoded one would collide with whatever else is listening.
actor LoopbackCallbackServer {
    enum ServerError: Error, LocalizedError {
        case listenerFailed(String)
        case timedOut
        case malformedRequest

        var errorDescription: String? {
            switch self {
            case let .listenerFailed(message):
                "Could not listen for the Spotify redirect: \(message)"
            case .timedOut:
                "Timed out waiting for the Spotify redirect"
            case .malformedRequest:
                "The Spotify redirect could not be read"
            }
        }
    }

    private var listener: NWListener?
    private var waiter: CheckedContinuation<URLComponents, Error>?
    /// A result that arrived before anyone was waiting for it. The browser can redirect faster
    /// than the caller gets from `start()` to `waitForCallback()`, and a valid authorization
    /// must not be lost to that race.
    private var pending: Result<URLComponents, Error>?
    private var finished = false
    private var timeout: Task<Void, Never>?

    /// Starts listening on a system-assigned loopback port and returns it.
    ///
    /// Waits for the listener to reach `.ready`: until then the port is a placeholder, and
    /// advertising it would send Spotify a redirect to `127.0.0.1:0`, which reaches nothing.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only. The redirect never leaves this machine, so nothing else should be
        // able to reach the listener.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.listenerFailed(String(describing: error))
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receiveRequest(on: connection) { [weak self] result in
                Task { await self?.deliver(result) }
            }
        }

        self.listener = listener

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, port != 0 else {
                        guard once.claim() else { return }
                        continuation.resume(throwing: ServerError.listenerFailed("no port assigned"))
                        return
                    }
                    guard once.claim() else { return }
                    continuation.resume(returning: port)
                case let .failed(error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: ServerError.listenerFailed(String(describing: error)))
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: ServerError.listenerFailed("listener cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Waits for the redirect, or gives up.
    ///
    /// The wait is bounded because the other end of it is a person: closing the browser tab
    /// without authorizing produces no request at all, and an unbounded wait would strand the
    /// caller — which is exactly what a user pressing Cancel in the browser looks like.
    ///
    /// The timeout delivers into the same one-shot path as a real callback rather than racing
    /// it in a task group, so whichever arrives first is the answer and the other cannot leave
    /// a continuation dangling.
    func waitForCallback(timeout duration: Duration = .seconds(300)) async throws -> URLComponents {
        if let pending {
            self.pending = nil
            stop()
            return try pending.get()
        }

        timeout = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.deliver(.failure(ServerError.timedOut))
        }

        defer { stop() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil

        // A caller still parked here would wait forever otherwise.
        if let waiter {
            self.waiter = nil
            finished = true
            waiter.resume(throwing: ServerError.timedOut)
        }
    }

    /// The single point where a result becomes *the* result — first one wins, later ones are
    /// dropped rather than resuming a continuation twice.
    private func deliver(_ result: Result<URLComponents, Error>) {
        guard !finished else { return }
        finished = true

        timeout?.cancel()
        timeout = nil

        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else {
            pending = result
        }
    }

    /// Reads one HTTP request and answers it, so the browser tab shows something human.
    ///
    /// Accumulates until the request line is complete: `receive` returns as soon as a single
    /// byte is available, and TCP does not promise the browser's request arrives in one piece,
    /// so parsing the first chunk would reject a perfectly good redirect that happened to be
    /// split.
    private nonisolated static func receiveRequest(
        on connection: NWConnection,
        completion: @escaping @Sendable (Result<URLComponents, Error>) -> Void,
    ) {
        let once = OnceFlag()

        func finish(_ result: Result<URLComponents, Error>) {
            guard once.claim() else { return }
            completion(result)
        }

        func read(_ accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                if let error {
                    finish(.failure(ServerError.listenerFailed(String(describing: error))))
                    connection.cancel()
                    return
                }

                let buffer = accumulated + (data ?? Data())

                guard let text = String(data: buffer, encoding: .utf8),
                      text.contains("\r\n") || text.contains("\n")
                else {
                    // Not a whole request line yet. Keep reading unless the peer is done or
                    // the request is implausibly large for what a redirect can carry.
                    if isComplete || buffer.count >= 8192 {
                        finish(.failure(ServerError.malformedRequest))
                        connection.cancel()
                    } else {
                        read(buffer)
                    }
                    return
                }

                guard let components = parseRequestLine(text) else {
                    finish(.failure(ServerError.malformedRequest))
                    connection.cancel()
                    return
                }

                let body = "<html><body>Spotifly is authorized. You can close this tab.</body></html>"
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """

                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                finish(.success(components))
            }
        }

        read(Data())
    }

    /// Pulls the query out of an HTTP request line: `GET /login?code=…&state=… HTTP/1.1`.
    ///
    /// Split out so the parsing can be tested without a socket.
    nonisolated static func parseRequestLine(_ request: String) -> URLComponents? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first ?? request.split(separator: "\n").first
        else { return nil }

        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }

        return URLComponents(string: "http://127.0.0.1\(parts[1])")
    }
}
