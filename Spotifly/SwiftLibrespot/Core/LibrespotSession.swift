//
//  LibrespotSession.swift
//  SwiftLibrespot
//
//  Main session coordinator for Spotify connection
//

import Combine
import Foundation

/// Connection state for the Spotify session
public enum SessionState: Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

extension SessionState: Equatable {
    public nonisolated static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.authenticating, .authenticating),
             (.connected, .connected):
            true
        case let (.reconnecting(a), .reconnecting(b)):
            a == b
        case let (.failed(a), .failed(b)):
            a == b
        default:
            false
        }
    }
}

/// Main coordinator for Spotify connection
/// Manages AP connection, dealer WebSocket, and SPIRC controller
public actor LibrespotSession {
    // MARK: - Properties

    /// Current session state
    public private(set) var state: SessionState = .disconnected

    /// Device information for this session
    public let deviceInfo: DeviceInfo

    /// Current credentials
    private var credentials: SpotifyCredentials?

    /// AP resolver for endpoint discovery
    private var apResolver: APResolver?

    /// Cached resolved endpoints
    private var resolvedEndpoints: ResolvedEndpoints?

    /// Accesspoint connection for protocol communication
    public private(set) var accesspoint: Accesspoint?

    /// Dealer WebSocket connection for SPIRC
    private var dealerConnection: DealerConnection?

    /// SPIRC controller for Spotify Connect
    private var spircController: SpircController?

    /// State publisher
    private nonisolated(unsafe) let stateSubject = CurrentValueSubject<SessionState, Never>(.disconnected)

    /// Connection ID from Spotify (used for state publishing)
    private var connectionId: String?

    // MARK: - Publishers

    /// Publisher for session state changes
    public nonisolated var statePublisher: AnyPublisher<SessionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
        debugLog("LibrespotSession", "Session created for device: \(deviceInfo.deviceName)")
    }

    // MARK: - Connection Management

    /// Connect to Spotify with the given access token
    /// - Parameters:
    ///   - accessToken: The OAuth access token
    ///   - username: The Spotify username (required for AP authentication)
    public func connect(accessToken: String, username: String) async throws {
        debugLog("LibrespotSession", "Connecting with access token for user: \(username)...")
        credentials = SpotifyCredentials(accessToken: accessToken, username: username)

        updateState(.connecting)

        do {
            // Step 1: Resolve AP endpoints AND pre-generate DH keys in parallel
            apResolver = APResolver()
            var preGeneratedDH: DiffieHellman?

            async let resolveTask = apResolver!.resolve()
            async let dhTask: DiffieHellman? = {
                do {
                    return try DiffieHellman()
                } catch {
                    debugLog("LibrespotSession", "Failed to pre-generate DH: \(error)")
                    return nil
                }
            }()

            resolvedEndpoints = try await resolveTask
            preGeneratedDH = await dhTask
            debugLog("LibrespotSession", "Resolved \(resolvedEndpoints!.accesspoints.count) accesspoints, \(resolvedEndpoints!.dealers.count) dealers")

            // Step 2: Skip client token for now - it's used for spclient, not AP auth
            // try await requestClientToken()

            // Step 3: Connect to Accesspoint
            guard let apEndpoint = resolvedEndpoints?.accesspoints.first else {
                throw LibrespotError.connectionFailed("No accesspoints available")
            }
            updateState(.authenticating)

            accesspoint = Accesspoint(endpoint: apEndpoint, preGeneratedDH: preGeneratedDH)
            try await accesspoint!.connect(credentials: credentials!, deviceId: deviceInfo.deviceId)
            debugLog("LibrespotSession", "Connected to accesspoint")

            // Step 4: Connect to Dealer
            guard let dealerHost = resolvedEndpoints?.dealers.first else {
                throw LibrespotError.connectionFailed("No dealers available")
            }

            dealerConnection = DealerConnection(
                endpoint: dealerHost,
                accessToken: accessToken,
            )
            try await dealerConnection!.connect()
            debugLog("LibrespotSession", "Connected to dealer")

            // Step 5: Initialize SPIRC controller
            spircController = SpircController(
                deviceInfo: deviceInfo,
                accesspoint: accesspoint!,
                dealerConnection: dealerConnection!,
            )
            try await spircController!.initialize()
            setupSpircSubscriptions()
            debugLog("LibrespotSession", "SPIRC controller initialized")

            updateState(.connected)
            debugLog("LibrespotSession", "Session fully connected")

        } catch {
            updateState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Disconnect from Spotify
    public func disconnect() async {
        debugLog("LibrespotSession", "Disconnecting...")

        await spircController?.shutdown()
        await dealerConnection?.disconnect()
        await accesspoint?.disconnect()

        spircController = nil
        dealerConnection = nil
        accesspoint = nil
        apResolver = nil
        credentials = nil
        connectionId = nil

        updateState(.disconnected)
        debugLog("LibrespotSession", "Disconnected")
    }

    /// Attempt to reconnect with exponential backoff
    public func reconnect() async throws {
        guard let creds = credentials else {
            throw LibrespotError.notInitialized
        }

        var attempt = 1
        let maxAttempts = 10
        var delay: UInt64 = 1_000_000_000 // 1 second

        while attempt <= maxAttempts {
            updateState(.reconnecting(attempt: attempt))
            debugLog("LibrespotSession", "Reconnection attempt \(attempt)/\(maxAttempts)")

            do {
                // Username should be set from initial connect
                guard let username = creds.username else {
                    throw LibrespotError.authenticationFailed("No username available for reconnection")
                }
                try await connect(accessToken: creds.accessToken, username: username)
                return
            } catch {
                debugLog("LibrespotSession", "Reconnection attempt \(attempt) failed: \(error)")
                attempt += 1
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 30_000_000_000) // Max 30 seconds
            }
        }

        throw LibrespotError.connectionFailed("Max reconnection attempts exceeded")
    }

    // MARK: - State Management

    private func updateState(_ newState: SessionState) {
        state = newState
        stateSubject.send(newState)
    }

    // MARK: - Session Info

    /// Whether the session is connected and ready
    public var isConnected: Bool {
        state == .connected
    }

    /// Whether SPIRC is ready for commands
    public var isSpircReady: Bool {
        get async {
            await spircController?.isReady ?? false
        }
    }

    /// Current connection ID
    public var currentConnectionId: String? {
        connectionId
    }

    /// Dealer endpoint for direct connection info
    public var dealerEndpoint: String? {
        // Return the endpoint that was used for dealer connection
        resolvedEndpoints?.dealers.first
    }

    /// SPClient host for track metadata and CDN resolution
    public var spclientHost: String? {
        resolvedEndpoints?.spclients.first
    }

    // MARK: - SPIRC Publishers (forwarded from SpircController)

    /// Player state updates from SPIRC
    public nonisolated var playerStatePublisher: AnyPublisher<SpircController.SpircPlayerState?, Never> {
        spircPlayerStateSubject.eraseToAnyPublisher()
    }

    /// Cluster state updates from SPIRC
    public nonisolated var clusterStatePublisher: AnyPublisher<SpircController.ClusterState?, Never> {
        spircClusterStateSubject.eraseToAnyPublisher()
    }

    /// SPIRC commands from remote devices
    public nonisolated var commandsPublisher: AnyPublisher<SpircCommand, Never> {
        spircCommandSubject.eraseToAnyPublisher()
    }

    // Internal subjects for SPIRC events
    private nonisolated(unsafe) let spircPlayerStateSubject = CurrentValueSubject<SpircController.SpircPlayerState?, Never>(nil)
    private nonisolated(unsafe) let spircClusterStateSubject = CurrentValueSubject<SpircController.ClusterState?, Never>(nil)
    private nonisolated(unsafe) let spircCommandSubject = PassthroughSubject<SpircCommand, Never>()

    /// Subscriptions for SPIRC controller
    private var spircSubscriptions: Set<AnyCancellable> = []

    /// Setup subscriptions to SPIRC controller publishers
    private func setupSpircSubscriptions() {
        spircSubscriptions.removeAll()

        guard let spirc = spircController else { return }

        // Forward player state
        spirc.playerStatePublisher
            .sink { [weak self] state in
                self?.spircPlayerStateSubject.send(state)
            }
            .store(in: &spircSubscriptions)

        // Forward cluster state
        spirc.clusterStatePublisher
            .sink { [weak self] state in
                self?.spircClusterStateSubject.send(state)
            }
            .store(in: &spircSubscriptions)

        // Forward commands
        spirc.commands
            .sink { [weak self] command in
                self?.spircCommandSubject.send(command)
            }
            .store(in: &spircSubscriptions)
    }

    // MARK: - Client Token

    /// Request a client token from Spotify before AP authentication
    /// This is required on macOS/Windows to "register" the session
    private func requestClientToken() async throws {
        let clientId = SpotifyConfig.getClientId()
        debugLog("LibrespotSession", "Requesting client token with clientId: \(clientId.prefix(8))...")

        // Build the ClientTokenRequest protobuf (proto3)
        let requestData = buildClientTokenRequest(clientId: clientId)

        // Make HTTP request
        var request = URLRequest(url: URL(string: "https://clienttoken.spotify.com/v1/clienttoken")!)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            debugLog("LibrespotSession", "Client token request failed: invalid response")
            return
        }

        if httpResponse.statusCode == 200 {
            // Parse response to check if we got a granted token
            if let tokenInfo = parseClientTokenResponse(data) {
                debugLog("LibrespotSession", "Received client token (expires in \(tokenInfo.expiresAfterSeconds)s)")
            } else {
                debugLog("LibrespotSession", "Received client token response (unparsed)")
            }
        } else {
            debugLog("LibrespotSession", "Client token request failed: HTTP \(httpResponse.statusCode)")
            // Don't throw - continue anyway and see if AP auth works
        }
    }

    /// Build ClientTokenRequest protobuf for macOS
    private nonisolated func buildClientTokenRequest(clientId: String) -> Data {
        var data = Data()

        // Helper to encode varint
        func encodeVarint(_ value: UInt64) -> [UInt8] {
            var result: [UInt8] = []
            var v = value
            while v > 127 {
                result.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            result.append(UInt8(v))
            return result
        }

        // Helper to encode string field
        func encodeString(_ fieldNum: Int, _ str: String) -> Data {
            var fieldData = Data()
            let tag = (fieldNum << 3) | 2 // wire type 2 = length-delimited
            fieldData.append(contentsOf: encodeVarint(UInt64(tag)))
            let strData = str.data(using: .utf8)!
            fieldData.append(contentsOf: encodeVarint(UInt64(strData.count)))
            fieldData.append(strData)
            return fieldData
        }

        // Helper to encode embedded message field
        func encodeMessage(_ fieldNum: Int, _ msgData: Data) -> Data {
            var fieldData = Data()
            let tag = (fieldNum << 3) | 2
            fieldData.append(contentsOf: encodeVarint(UInt64(tag)))
            fieldData.append(contentsOf: encodeVarint(UInt64(msgData.count)))
            fieldData.append(msgData)
            return fieldData
        }

        // Build NativeDesktopMacOSData (fields: system_version=1, hw_model=2, compiled_cpu_type=3)
        var macosData = Data()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        macosData.append(encodeString(1, osVersion))
        macosData.append(encodeString(2, "iMac21,1"))
        #if arch(arm64)
        macosData.append(encodeString(3, "arm64"))
        #else
        macosData.append(encodeString(3, "x86_64"))
        #endif

        // Build PlatformSpecificData with desktop_macos (field 3)
        var platformData = Data()
        platformData.append(encodeMessage(3, macosData))

        // Build ConnectivitySdkData (platform_specific_data=1, device_id=2)
        var connectivityData = Data()
        connectivityData.append(encodeMessage(1, platformData))
        connectivityData.append(encodeString(2, deviceInfo.deviceId))

        // Build ClientDataRequest (client_version=1, client_id=2, connectivity_sdk_data=3)
        var clientData = Data()
        clientData.append(encodeString(1, "1.2.52.442")) // Spotify desktop version
        clientData.append(encodeString(2, clientId))
        clientData.append(encodeMessage(3, connectivityData))

        // Build ClientTokenRequest (request_type=1 as varint, client_data=2 as message)
        // request_type = 1 (REQUEST_CLIENT_DATA_REQUEST)
        let requestTypeTag = (1 << 3) | 0 // field 1, wire type 0 (varint)
        data.append(contentsOf: encodeVarint(UInt64(requestTypeTag)))
        data.append(contentsOf: encodeVarint(1)) // value = 1

        data.append(encodeMessage(2, clientData))

        return data
    }

    /// Parse ClientTokenResponse to extract token info
    private nonisolated func parseClientTokenResponse(_ data: Data) -> (token: String, expiresAfterSeconds: Int)? {
        // Simple parsing - look for response_type=1 (granted) and extract token
        var offset = 0

        func readVarint() -> UInt64? {
            guard offset < data.count else { return nil }
            var result: UInt64 = 0
            var shift = 0
            while offset < data.count {
                let byte = data[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return result
        }

        func readLengthDelimited() -> Data? {
            guard let length = readVarint(), offset + Int(length) <= data.count else { return nil }
            let result = data.subdata(in: offset..<(offset + Int(length)))
            offset += Int(length)
            return result
        }

        // Parse top-level message
        while offset < data.count {
            guard let tag = readVarint() else { break }
            let fieldNum = Int(tag >> 3)
            let wireType = Int(tag & 0x7)

            switch (fieldNum, wireType) {
            case (1, 0): // response_type (varint)
                guard let responseType = readVarint() else { break }
                if responseType != 1 { return nil } // Not a granted token
            case (2, 2): // granted_token (message)
                guard let grantedData = readLengthDelimited() else { break }
                // Parse GrantedTokenResponse
                var gOffset = 0
                var token: String?
                var expires: Int = 0
                while gOffset < grantedData.count {
                    var gResult: UInt64 = 0
                    var gShift = 0
                    while gOffset < grantedData.count {
                        let byte = grantedData[gOffset]
                        gOffset += 1
                        gResult |= UInt64(byte & 0x7F) << gShift
                        if byte & 0x80 == 0 { break }
                        gShift += 7
                    }
                    let gFieldNum = Int(gResult >> 3)
                    let gWireType = Int(gResult & 0x7)
                    if gWireType == 2 { // string
                        var len: UInt64 = 0
                        var lenShift = 0
                        while gOffset < grantedData.count {
                            let byte = grantedData[gOffset]
                            gOffset += 1
                            len |= UInt64(byte & 0x7F) << lenShift
                            if byte & 0x80 == 0 { break }
                            lenShift += 7
                        }
                        if gFieldNum == 1 && gOffset + Int(len) <= grantedData.count {
                            token = String(data: grantedData.subdata(in: gOffset..<(gOffset + Int(len))), encoding: .utf8)
                        }
                        gOffset += Int(len)
                    } else if gWireType == 0 { // varint
                        var val: UInt64 = 0
                        var valShift = 0
                        while gOffset < grantedData.count {
                            let byte = grantedData[gOffset]
                            gOffset += 1
                            val |= UInt64(byte & 0x7F) << valShift
                            if byte & 0x80 == 0 { break }
                            valShift += 7
                        }
                        if gFieldNum == 2 { expires = Int(val) }
                    }
                }
                if let t = token { return (t, expires) }
            default:
                // Skip unknown fields
                if wireType == 0 { _ = readVarint() }
                else if wireType == 2 { _ = readLengthDelimited() }
                else { break }
            }
        }
        return nil
    }
}
