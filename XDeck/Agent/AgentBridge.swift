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

    private(set) var isRunning = false
    private(set) var port: UInt16 = AgentBridge.defaultPort
    private(set) var tokenPath: URL?

    private var listener: NWListener?
    private var token: String = ""
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init() {}

    static var isEnabledByEnvironment: Bool {
        let value = ProcessInfo.processInfo.environment[envFlag]?
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

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Prefer loopback. Avoid requiredLocalEndpoint — it often fails to
        // reach .ready under App Sandbox even with network.server.
        parameters.requiredInterfaceType = .loopback

        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[AgentBridge] listening on 127.0.0.1:\(port)")
                Self.writeStatus("listening on 127.0.0.1:\(port)")
            case .failed(let error):
                print("[AgentBridge] listener failed: \(error)")
                Self.writeStatus("listener failed: \(error)")
                Task { @MainActor in
                    self?.isRunning = false
                }
            case .waiting(let error):
                print("[AgentBridge] listener waiting: \(error)")
                Self.writeStatus("listener waiting: \(error)")
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        isRunning = true
        print("[AgentBridge] token file \(tokenPath?.path ?? "(unknown)") (reused=\(loaded.reused))")
        Self.writeStatus("started token=\(tokenPath?.path ?? "?") reused=\(loaded.reused)")
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
        let path = pathAndQuery.split(separator: "?", maxSplits: 1).first.map(String.init) ?? pathAndQuery
        let headers = Self.parseHeaders(headerText)

        do {
            try authorize(headers: headers)
            let (status, json) = try await route(method: method, path: path, body: body)
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
        guard provided == token, !token.isEmpty else {
            throw AgentBridgeError.unauthorized
        }
    }

    private func route(method: String, path: String, body: Data) async throws -> (Int, String) {
        switch (method, path) {
        case ("GET", "/health"):
            return (200, try await healthJSON())
        case ("GET", "/columns"):
            return (200, columnsJSON())
        case ("GET", _) where path.hasPrefix("/columns/") && path.hasSuffix("/text"):
            let index = try parseColumnIndex(path: path, suffix: "/text")
            return (200, try await readColumnJSON(index: index, includeText: true))
        case ("GET", _) where path.hasPrefix("/columns/") && path.hasSuffix("/tweets"):
            let index = try parseColumnIndex(path: path, suffix: "/tweets")
            return (200, try await readColumnJSON(index: index, includeText: false))
        case ("POST", "/eval"):
            return try await handleEval(body: body, defaultColumn: nil)
        case ("POST", _) where path.hasPrefix("/columns/") && path.hasSuffix("/eval"):
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

    private func readColumnJSON(index: Int, includeText: Bool) async throws -> String {
        let challengeJSON = try await ColumnRegistry.shared.evaluateJavaScript(
            column: index,
            script: AgentDOM.challengeProbeJS
        )
        let tweetsJSON = try await ColumnRegistry.shared.evaluateJavaScript(
            column: index,
            script: AgentDOM.extractTweetsJS
        )
        var parts = [
            #""column":\#(index)"#,
            #""challenge":\#(challengeJSON)"#,
            #""tweets":\#(tweetsJSON)"#,
        ]
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
        try await ColumnRegistry.shared.navigate(column: column, to: url)
        return (200, #"{"ok":true,"column":\#(column),"url":\#(Self.jsonString(url.absoluteString))}"#)
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
            }
            colParts.append(
                """
                {"index":\(col.index),"type":\(Self.jsonString(col.type)),"url":\(col.url.map(Self.jsonString) ?? "null"),"isLoading":\(col.isLoading),"hasWebView":\(col.hasWebView),"needs_human":\(needsHuman ? "true" : "false"),"challenge":\(challengeJSON)}
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
