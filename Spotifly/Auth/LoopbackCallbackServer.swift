//
//  LoopbackCallbackServer.swift
//  Spotifly
//
//  A one-shot HTTP listener on loopback, for OAuth redirects that are not a custom scheme.
//

import Foundation
import Network

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
    private var delivered = false

    /// Starts listening on a system-assigned loopback port and returns it.
    func start() throws -> UInt16 {
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

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener

        guard let port = listener.port?.rawValue else {
            listener.cancel()
            self.listener = nil
            throw ServerError.listenerFailed("no port assigned")
        }
        return port
    }

    /// Waits for the redirect, or gives up.
    ///
    /// The wait is bounded because the other end of it is a person: closing the browser tab
    /// without authorizing produces no request at all, and an unbounded wait would strand the
    /// caller — which is exactly what a user pressing Cancel in the browser looks like.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> URLComponents {
        defer { stop() }

        return try await withThrowingTaskGroup(of: URLComponents.self) { group in
            group.addTask { try await self.awaitDelivery() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ServerError.timedOut
            }

            guard let first = try await group.next() else {
                throw ServerError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: ServerError.timedOut)
        }
    }

    private func awaitDelivery() async throws -> URLComponents {
        try await withCheckedThrowingContinuation { continuation in
            // The request can arrive before anyone waits for it; resume straight away rather
            // than parking on a callback that has already fired.
            if delivered {
                continuation.resume(throwing: ServerError.malformedRequest)
                return
            }
            waiter = continuation
        }
    }

    private func deliver(_ result: Result<URLComponents, Error>) {
        guard !delivered else { return }
        delivered = true

        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(with: result)
    }

    /// Reads one HTTP request and answers it, so the browser tab shows something human.
    private nonisolated static func receiveRequest(
        on connection: NWConnection,
        completion: @escaping @Sendable (Result<URLComponents, Error>) -> Void,
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
            if let error {
                completion(.failure(ServerError.listenerFailed(String(describing: error))))
                connection.cancel()
                return
            }

            guard let data, let request = String(data: data, encoding: .utf8),
                  let components = parseRequestLine(request)
            else {
                completion(.failure(ServerError.malformedRequest))
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
            completion(.success(components))
        }
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
