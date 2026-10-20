import Darwin
import Foundation
import Network
import Security

/// Opt-in localhost HTTP bridge for agents. Starts only when `XDECK_AGENT=1`.
/// Binds `127.0.0.1:18765`, requires bearer token from `/Users/Shared/XDeck-agent`
/// or Application Support (stable across restarts; never `/tmp`).
@MainActor
final class AgentBridge {
    static let shared = AgentBridge()

    static let defaultPort: UInt16 = 18765
    static let envFlag = "XDECK_AGENT"
    /// Opt-in for powerful `POST /eval` and `/columns/:i/eval`. Off by default.
    /// When unset, those routes return **HTTP 404** (same as an unregistered path).
    static let evalEnvFlag = "XDECK_AGENT_EVAL"

    private(set) var isRunning = false
    private(set) var port: UInt16 = AgentBridge.defaultPort
    private(set) var tokenPath: URL?

    private var listener: NWListener?
    private var token: String = ""
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init() {}

    static var isEnabledByEnvironment: Bool {
        envFlagEnabled(envFlag)
    }

    /// `XDECK_AGENT_EVAL=1` (or true/yes) enables HTTP eval. Default: disabled → 404.
    static var isEvalEnabledByEnvironment: Bool {
        envFlagEnabled(evalEnvFlag)
    }

    private static func envFlagEnabled(_ name: String) -> Bool {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    func startIfEnabled() {
        guard Self.isEnabledByEnvironment else {
            print("[AgentBridge] disabled (set \(Self.envFlag)=1 to enable)")
            return
        }
        guard !isRunning else { return }
        do {
            try start()
        } catch {
            print("[AgentBridge] failed to start: \(error.localizedDescription)")
        }
    }

    func start(port: UInt16 = AgentBridge.defaultPort) throws {
        self.port = port
        let loaded = try Self.loadOrCreateToken()
        token = loaded.token
        tokenPath = loaded.path
        if loaded.reused {
            print("[AgentBridge] reusing stable token from \(tokenPath?.path ?? "(unknown)")")
            Self.writeStatus("token reused path=\(tokenPath?.path ?? "?")")
        } else {
            print("[AgentBridge] minted new token → \(tokenPath?.path ?? "(unknown)")")
            Self.writeStatus("token minted path=\(tokenPath?.path ?? "?")")
        }

        // Bind explicitly to 127.0.0.1. Do NOT pass `on:` when using
        // requiredLocalEndpoint (that combo historically never reached .ready
        // under App Sandbox). Constructor throw *and* NWListener `.failed`
        // both fall back to interfaceType=.loopback — a silent `.failed` left
        // the bridge dead on some Macs.
        try attachListener(preferExplicitLoopback: true)
        print("[AgentBridge] token file \(tokenPath?.path ?? "(unknown)") (reused=\(loaded.reused))")
        Self.writeStatus("started token=\(tokenPath?.path ?? "?") reused=\(loaded.reused)")
    }

    /// Prefer explicit `127.0.0.1` bind; on constructor error or `.failed`, retry
    /// with `requiredInterfaceType = .loopback`. Never leave a `.failed` silent.
    private func attachListener(preferExplicitLoopback: Bool) throws {
        let port = self.port
        let listener: NWListener
        let bindMode: String
        let usedExplicit: Bool

        if preferExplicitLoopback {
            do {
                listener = try Self.makeLoopbackListener(port: port)
                bindMode = "requiredLocalEndpoint:127.0.0.1"
                usedExplicit = true
            } catch {
                print("[AgentBridge] explicit 127.0.0.1 bind threw (\(error)); falling back to requiredInterfaceType=.loopback")
                Self.writeStatus("explicit loopback bind threw: \(error); fallback interfaceType")
                listener = try Self.makeInterfaceLoopbackListener(port: port)
                bindMode = "requiredInterfaceType=.loopback"
                usedExplicit = false
            }
        } else {
            listener = try Self.makeInterfaceLoopbackListener(port: port)
            bindMode = "requiredInterfaceType=.loopback"
            usedExplicit = false
        }

        self.listener?.cancel()
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[AgentBridge] listening on 127.0.0.1:\(port) (\(bindMode))")
                Self.writeStatus("listening on 127.0.0.1:\(port) mode=\(bindMode)")
                Task { @MainActor in
                    self?.isRunning = true
                }
            case .failed(let error):
                print("[AgentBridge] listener .failed (\(bindMode)): \(error)")
                Self.writeStatus("listener .failed mode=\(bindMode): \(error)")
                Task { @MainActor in
                    guard let self else { return }
                    self.listener?.cancel()
                    self.listener = nil
                    self.isRunning = false
                    if usedExplicit {
                        print("[AgentBridge] primary bind .failed; retrying requiredInterfaceType=.loopback")
                        Self.writeStatus("primary .failed → fallback interfaceType=.loopback")
                        do {
                            try self.attachListener(preferExplicitLoopback: false)
                        } catch {
                            print("[AgentBridge] fallback bind also failed: \(error.localizedDescription)")
                            Self.writeStatus("fallback bind failed: \(error)")
                        }
                    } else {
                        print("[AgentBridge] fallback listener .failed; bridge not listening")
                        Self.writeStatus("fallback .failed; bridge down: \(error)")
                    }
                }
            case .waiting(let error):
                print("[AgentBridge] listener waiting (\(bindMode)): \(error)")
                Self.writeStatus("listener waiting mode=\(bindMode): \(error)")
            case .setup:
                break
            case .cancelled:
                print("[AgentBridge] listener cancelled (\(bindMode))")
            @unknown default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        isRunning = true
        print("[AgentBridge] bind=\(bindMode) (awaiting .ready)")
        Self.writeStatus("bind=\(bindMode) awaiting .ready")
    }

    /// Explicit IPv4 loopback via `requiredLocalEndpoint` (no `on:` port).
    private static func makeLoopbackListener(port: UInt16) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        return try NWListener(using: parameters)
    }

    /// Fallback: prefer loopback interface (may show as `*:port` in lsof).
    private static func makeInterfaceLoopbackListener(port: UInt16) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        return try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        isRunning = false
    }

    // MARK: - Token file

    nonisolated private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("XDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Real (unsandboxed) home — sandboxed `homeDirectoryForCurrentUser` is the container.
    nonisolated private static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated private static func externalSupportDirectory() throws -> URL {
        let dir = realHomeDirectory
            .appendingPathComponent("Library/Application Support/XDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Prefer Client-facing paths first so CLI/MCP and the app agree.
    /// Never `/tmp` — only `/Users/Shared/XDeck-agent/` + App Support.
    nonisolated private static func tokenFileCandidates() -> [URL] {
        var urls: [URL] = [
            URL(fileURLWithPath: "/Users/Shared/XDeck-agent/agent.token"),
        ]
        if let external = try? externalSupportDirectory().appendingPathComponent("agent.token") {
            urls.append(external)
        }
        if let sandboxed = try? supportDirectory().appendingPathComponent("agent.token") {
            urls.append(sandboxed)
        }
        return urls
    }

    nonisolated private static func isValidToken(_ value: String) -> Bool {
        // makeToken() → 32 bytes → 64 lowercase hex chars
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    /// Reuse an existing well-formed token across app restarts so MCP/CLI clients
    /// that cached `XDECK_AGENT_TOKEN` or already opened the file keep working.
    /// Set `XDECK_AGENT_ROTATE_TOKEN=1` to force a new token.
    private static func loadOrCreateToken() throws -> (token: String, path: URL, reused: Bool) {
        let rotate = ProcessInfo.processInfo.environment["XDECK_AGENT_ROTATE_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let forceRotate = rotate == "1" || rotate == "true" || rotate == "yes"

        if !forceRotate {
            for url in tokenFileCandidates() {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let existing = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidToken(existing) else { continue }
                let written = try writeTokenFile(existing)
                return (existing, written, true)
            }
        }

        let minted = makeToken()
        let written = try writeTokenFile(minted)
        return (minted, written, false)
    }

    private static func writeTokenFile(_ token: String) throws -> URL {
        let url = try supportDirectory().appendingPathComponent("agent.token")
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        // Mirror outside the container so CLI/MCP can read the bearer (Debug entitlements).
        // Only: /Users/Shared/XDeck-agent + external App Support. Never /tmp.
        let mirrors: [URL] = [
            URL(fileURLWithPath: "/Users/Shared/XDeck-agent/agent.token"),
            (try? externalSupportDirectory().appendingPathComponent("agent.token")).flatMap { $0 },
        ].compactMap { $0 }
        for mirror in mirrors {
            do {
                try FileManager.default.createDirectory(
                    at: mirror.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try token.write(to: mirror, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: mirror.path
                )
                Self.writeStatus("token mirrored to \(mirror.path)")
            } catch {
                Self.writeStatus("token mirror failed \(mirror.path): \(error.localizedDescription)")
            }
        }
        return url
    }

    nonisolated private static func writeStatus(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        let candidates: [URL] = [
            (try? externalSupportDirectory().appendingPathComponent("agent-bridge.log")).flatMap { $0 },
            (try? supportDirectory().appendingPathComponent("agent-bridge.log")).flatMap { $0 },
        ].compactMap { $0 }
        for url in candidates {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = text.data(using: .utf8) { handle.write(data) }
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        // Defense in depth: drop anything that is not loopback.
        if let path = connection.currentPath,
           let remote = path.remoteEndpoint,
           !Self.isLoopback(remote) {
            print("[AgentBridge] rejecting non-loopback connection: \(remote)")
            connection.cancel()
            return
        }

        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.connections.removeValue(forKey: id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return addr == .loopback
            case .ipv6(let addr):
                return addr == .loopback
            case .name(let name, _):
                return name == "localhost" || name == "127.0.0.1" || name == "::1"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    print("[AgentBridge] receive error: \(error)")
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }

                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                    guard let headerText = String(data: headerData, encoding: .utf8) else {
                        self.respond(connection, status: 400, body: #"{"error":"invalid headers"}"#)
                        return
                    }
                    let headers = Self.parseHeaders(headerText)
                    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                    let bodyStart = headerEnd.upperBound
                    let bodyEnd = bodyStart + contentLength
                    if buffer.count < bodyEnd && !isComplete {
                        self.receiveRequest(on: connection, buffer: buffer)
                        return
                    }
                    let body = contentLength > 0 && bodyEnd <= buffer.endIndex
                        ? buffer.subdata(in: bodyStart..<bodyEnd)
                        : Data()
                    await self.handleHTTP(connection: connection, headerText: headerText, body: body)
                    return
                }

                if isComplete {
                    connection.cancel()
                    return
                }
                if buffer.count > 1_000_000 {
                    self.respond(connection, status: 413, body: #"{"error":"request too large"}"#)
                    return
                }
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private static func parseHeaders(_ headerText: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            let name = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            result[name] = value
        }
        return result
    }

    private func handleHTTP(connection: NWConnection, headerText: String, body: Data) async {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            respond(connection, status: 400, body: #"{"error":"bad request"}"#)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, status: 400, body: #"{"error":"bad request"}"#)
            return
        }
        let method = String(parts[0]).uppercased()
        let pathAndQuery = String(parts[1])
        let pathParts = pathAndQuery.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pathParts.first ?? pathAndQuery
        let query = pathParts.count > 1 ? Self.parseQuery(pathParts[1]) : [:]
        let headers = Self.parseHeaders(headerText)

        do {
            try authorize(headers: headers)
            let (status, json) = try await route(method: method, path: path, query: query, body: body)
            respond(connection, status: status, body: json)
        } catch let error as AgentBridgeError {
            let payload = #"{"error":\#(Self.jsonString(error.localizedDescription))}"#
            respond(connection, status: error.statusCode, body: payload)
        } catch {
            let payload = #"{"error":\#(Self.jsonString(error.localizedDescription))}"#
            respond(connection, status: 500, body: payload)
        }
    }

    private func authorize(headers: [String: String]) throws {
        guard let auth = headers["authorization"],
              auth.lowercased().hasPrefix("bearer ") else {
            throw AgentBridgeError.unauthorized
        }
        let provided = String(auth.dropFirst("bearer ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, Self.constantTimeEqual(provided, token) else {
            throw AgentBridgeError.unauthorized
        }
    }

    /// Constant-time UTF-8 compare (Darwin `timingsafe_bcmp`). Length mismatch → false.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count, !aBytes.isEmpty else { return false }
        return aBytes.withUnsafeBufferPointer { aBuf in
            bBytes.withUnsafeBufferPointer { bBuf in
                timingsafe_bcmp(aBuf.baseAddress, bBuf.baseAddress, aBytes.count) == 0
            }
        }
    }

    private func route(method: String, path: String, query: [String: String], body: Data) async throws -> (Int, String) {
        let limit = Self.parseLimit(query["limit"])
        switch (method, path) {
        case ("GET", "/health"):
            return (200, try await healthJSON())
        case ("GET", "/columns"):
            return (200, columnsJSON())
        case ("GET", _) where path.hasPrefix("/columns/") && path.hasSuffix("/text"):
            let index = try parseColumnIndex(path: path, suffix: "/text")
            return (200, try await readColumnJSON(index: index, includeText: true, limit: limit))
        case ("GET", _) where path.hasPrefix("/columns/") && path.hasSuffix("/tweets"):
            let index = try parseColumnIndex(path: path, suffix: "/tweets")
            return (200, try await readColumnJSON(index: index, includeText: false, limit: limit))
        case ("POST", "/eval"):
            try requireEvalEnabled()
            return try await handleEval(body: body, defaultColumn: nil)
        case ("POST", _) where path.hasPrefix("/columns/") && path.hasSuffix("/eval"):
            try requireEvalEnabled()
            let index = try parseColumnIndex(path: path, suffix: "/eval")
            return try await handleEval(body: body, defaultColumn: index)
        case ("POST", "/navigate"):
            return try await handleNavigate(body: body, defaultColumn: nil)
        case ("POST", _) where path.hasPrefix("/columns/") && path.hasSuffix("/navigate"):
            let index = try parseColumnIndex(path: path, suffix: "/navigate")
            return try await handleNavigate(body: body, defaultColumn: index)
        case ("POST", "/scroll"):
            return try await handleScroll(body: body, defaultColumn: nil)
        case ("POST", _) where path.hasPrefix("/columns/") && path.hasSuffix("/scroll"):
            let index = try parseColumnIndex(path: path, suffix: "/scroll")
            return try await handleScroll(body: body, defaultColumn: index)
        case ("POST", "/reload"):
            return try handleReload(body: body, defaultColumn: nil)
        case ("POST", _) where path.hasPrefix("/columns/") && path.hasSuffix("/reload"):
            let index = try parseColumnIndex(path: path, suffix: "/reload")
            return try handleReload(body: body, defaultColumn: index)
        case ("POST", "/click"), ("POST", "/type"), ("POST", "/post_tweet"),
             ("POST", "/reply"), ("POST", "/retweet"), ("POST", "/like"):
            throw AgentBridgeError.notImplemented("DOM write / \(path)")
        default:
            if method != "GET" && method != "POST" {
                throw AgentBridgeError.methodNotAllowed
            }
            throw AgentBridgeError.notFound
        }
    }

    private func readColumnJSON(index: Int, includeText: Bool, limit: Int?) async throws -> String {
        let challengeJSON = try await ColumnRegistry.shared.evaluateJavaScript(
            column: index,
            script: AgentDOM.challengeProbeJS
        )
        var tweetsJSON = try await ColumnRegistry.shared.evaluateJavaScript(
            column: index,
            script: AgentDOM.extractTweetsJS
        )
        if let limit, limit > 0,
           let data = tweetsJSON.data(using: .utf8),
           var arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            if arr.count > limit {
                arr = Array(arr.prefix(limit))
                if let truncated = try? JSONSerialization.data(withJSONObject: arr),
                   let s = String(data: truncated, encoding: .utf8) {
                    tweetsJSON = s
                }
            }
        }
        // Notifications column: typed events (likes/follows/reposts of own posts).
        var notificationsJSON: String?
        let snap = ColumnRegistry.shared.snapshot().first(where: { $0.index == index })
        let colURL = snap?.url ?? ColumnRegistry.shared.webView(at: index)?.url?.absoluteString
        let onNotifications = snap?.type == "notifications" ||
            (colURL?.range(of: "/notifications", options: .caseInsensitive) != nil)
        if onNotifications {
            notificationsJSON = try await ColumnRegistry.shared.evaluateJavaScript(
                column: index,
                script: AgentDOM.extractNotificationsJS
            )
            if let limit, limit > 0,
               let data = notificationsJSON?.data(using: .utf8),
               var arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               arr.count > limit {
                arr = Array(arr.prefix(limit))
                if let truncated = try? JSONSerialization.data(withJSONObject: arr),
                   let s = String(data: truncated, encoding: .utf8) {
                    notificationsJSON = s
                }
            }
        }
        var parts = [
            #""column":\#(index)"#,
            #""challenge":\#(challengeJSON)"#,
            #""tweets":\#(tweetsJSON)"#,
        ]
        if let notificationsJSON {
            parts.append(#""notifications":\#(notificationsJSON)"#)
            if let data = notificationsJSON.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                parts.append(#""notificationCount":\#(arr.count)"#)
            }
        }
        if let challengeNeedsHuman = Self.needsHuman(fromChallengeJSON: challengeJSON) {
            parts.append(#""needs_human":\#(challengeNeedsHuman ? "true" : "false")"#)
        } else {
            parts.append(#""needs_human":false"#)
        }
        // tweetCount from parsed array length when possible
        if let data = tweetsJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            parts.append(#""tweetCount":\#(arr.count)"#)
        }
        if includeText {
            let textJSON = try await ColumnRegistry.shared.evaluateJavaScript(
                column: index,
                script: AgentDOM.innerTextJS(maxChars: 200_000)
            )
            parts.append(#""text":\#(textJSON)"#)
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first, !key.isEmpty else { continue }
            let value = kv.count > 1
                ? (kv[1].removingPercentEncoding ?? kv[1])
                : ""
            out[key.lowercased()] = value
        }
        return out
    }

    private static func parseLimit(_ raw: String?) -> Int? {
        guard let raw, let n = Int(raw), n > 0 else { return nil }
        return min(n, 500)
    }

    private static func needsHuman(fromChallengeJSON json: String) -> Bool? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flag = obj["needs_human"] as? Bool else {
            return nil
        }
        return flag
    }

    private func columnFromBody(_ obj: [String: Any], defaultColumn: Int?) throws -> Int {
        if let defaultColumn { return defaultColumn }
        if let n = obj["column"] as? Int { return n }
        if let n = obj["column"] as? NSNumber { return n.intValue }
        throw AgentBridgeError.badRequest("Missing column index")
    }

    private func handleNavigate(body: Data, defaultColumn: Int?) async throws -> (Int, String) {
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AgentBridgeError.badRequest("JSON body required: { \"url\": \"https://x.com/...\", \"column\": 0 }")
        }
        guard let urlString = obj["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AgentBridgeError.badRequest("Missing or invalid url (http/https only)")
        }
        let column = try columnFromBody(obj, defaultColumn: defaultColumn)
        let result = try await ColumnRegistry.shared.navigate(column: column, to: url)
        // HTTP 200 with ok:false when SPA did not become ready — agents should read fields.
        let repliesLoadedJSON: String = {
            if let flag = result.repliesLoaded {
                return #","repliesLoaded":\#(flag ? "true" : "false")"#
            }
            return ""
        }()
        return (200, """
        {"ok":\(result.ok ? "true" : "false"),"column":\(result.column),"url":\(Self.jsonString(result.url)),"finalUrl":\(Self.jsonString(result.finalURL)),"method":\(Self.jsonString(result.method)),"ready":\(result.ready ? "true" : "false"),"tweetCount":\(result.tweetCount),"errorShell":\(result.errorShell ? "true" : "false"),"challenge":\(result.challenge ? "true" : "false"),"retries":\(result.retries),"waitedMs":\(result.waitedMs)\(repliesLoadedJSON)}
        """)
    }

    private func handleScroll(body: Data, defaultColumn: Int?) async throws -> (Int, String) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let column = try columnFromBody(obj, defaultColumn: defaultColumn)
        var delta = 800
        if let n = obj["deltaY"] as? Int { delta = n }
        else if let n = obj["deltaY"] as? NSNumber { delta = n.intValue }
        else if let n = obj["pixels"] as? Int { delta = n }
        else if let n = obj["pixels"] as? NSNumber { delta = n.intValue }
        let result = try await ColumnRegistry.shared.scroll(column: column, deltaY: delta)
        return (200, #"{"ok":true,"column":\#(column),"deltaY":\#(delta),"result":\#(result)}"#)
    }

    private func handleReload(body: Data, defaultColumn: Int?) throws -> (Int, String) {
        let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let column = try columnFromBody(obj, defaultColumn: defaultColumn)
        try ColumnRegistry.shared.reload(column: column)
        return (200, #"{"ok":true,"column":\#(column),"reloaded":true}"#)
    }

    /// Eval is opt-in. Unset → **HTTP 404** (route treated as unregistered; not 401/403).
    private func requireEvalEnabled() throws {
        guard Self.isEvalEnabledByEnvironment else {
            throw AgentBridgeError.evalDisabled
        }
    }

    private func handleEval(body: Data, defaultColumn: Int?) async throws -> (Int, String) {
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AgentBridgeError.badRequest("JSON body required: { \"js\": \"...\", \"column\": 0 }")
        }
        guard let js = obj["js"] as? String, !js.isEmpty else {
            throw AgentBridgeError.badRequest("Missing js string")
        }
        let column: Int
        if let defaultColumn {
            column = defaultColumn
        } else if let n = obj["column"] as? Int {
            column = n
        } else if let n = obj["column"] as? NSNumber {
            column = n.intValue
        } else {
            throw AgentBridgeError.badRequest("Missing column index")
        }
        let result = try await ColumnRegistry.shared.evaluateJavaScript(column: column, script: js)
        return (200, #"{"column":\#(column),"result":\#(result)}"#)
    }

    private func parseColumnIndex(path: String, suffix: String) throws -> Int {
        // /columns/:i/text or /columns/:i/eval
        let trimmed = String(path.dropFirst("/columns/".count).dropLast(suffix.count))
        // trimmed may still contain a trailing slash if suffix matched oddly; normalize
        let indexPart = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let index = Int(indexPart) else {
            throw AgentBridgeError.badRequest("Invalid column path: \(path)")
        }
        return index
    }

    private func healthJSON() async throws -> String {
        let columns = ColumnRegistry.shared.snapshot()
        let user = ColumnRegistry.shared.userHandle
        let userJSON = user.map { Self.jsonString($0) } ?? "null"
        var anyNeedsHuman = false
        var colParts: [String] = []
        for col in columns {
            var challengeJSON = "null"
            var needsHuman = false
            var visibilityState = "null"
            if col.hasWebView {
                if let probed = try? await ColumnRegistry.shared.evaluateJavaScript(
                    column: col.index,
                    script: AgentDOM.challengeProbeJS
                ) {
                    challengeJSON = probed
                    if Self.needsHuman(fromChallengeJSON: probed) == true {
                        needsHuman = true
                        anyNeedsHuman = true
                    }
                }
                if let vis = try? await ColumnRegistry.shared.evaluateJavaScript(
                    column: col.index,
                    script: AgentDOM.visibilityStateJS
                ) {
                    // evaluateJavaScript stringifies JS strings with quotes already
                    visibilityState = vis
                }
            }
            colParts.append(
                """
                {"index":\(col.index),"type":\(Self.jsonString(col.type)),"url":\(col.url.map(Self.jsonString) ?? "null"),"isLoading":\(col.isLoading),"hasWebView":\(col.hasWebView),"visibilityState":\(visibilityState),"needs_human":\(needsHuman ? "true" : "false"),"challenge":\(challengeJSON)}
                """
            )
        }
        let cols = colParts.joined(separator: ",")
        return """
        {"ok":true,"agent":true,"port":\(port),"user":\(userJSON),"needs_human":\(anyNeedsHuman ? "true" : "false"),"columns":[\(cols)],"columnCount":\(columns.count),"token_stable":true}
        """
    }

    private func columnsJSON() -> String {
        let columns = ColumnRegistry.shared.snapshot()
        let cols = columns.map { col -> String in
            """
            {"index":\(col.index),"type":\(Self.jsonString(col.type)),"url":\(col.url.map(Self.jsonString) ?? "null"),"isLoading":\(col.isLoading),"hasWebView":\(col.hasWebView)}
            """
        }.joined(separator: ",")
        return #"{"columns":[\#(cols)]}"#
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 501: reason = "Not Implemented"
        default: reason = "Error"
        }
        let bodyData = Data(body.utf8)
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        var data = Data(response.utf8)
        data.append(bodyData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
