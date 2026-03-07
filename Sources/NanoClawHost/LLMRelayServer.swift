import Foundation
import Hummingbird
import HTTPTypes
import Logging
import MCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LLMRelayServer: @unchecked Sendable {
    private struct FocusRelayRunResult {
        let command: String
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let durationMs: Int
    }

    private let settings: LLMRelaySettings
    private let logger: Logger
    private let session: URLSession
    private let focusRelayEnabled: Bool
    private let focusRelayCommand: String
    private let hostMCPRuntime: HostMCPRuntime
    private var serverTask: Task<Void, Never>?

    init(
        settings: LLMRelaySettings,
        logger: Logger,
        focusRelayEnabled: Bool,
        focusRelayCommand: String,
        session: URLSession = .shared
    ) {
        self.settings = settings
        self.logger = logger
        self.session = session
        self.focusRelayEnabled = focusRelayEnabled
        self.focusRelayCommand = focusRelayCommand
        self.hostMCPRuntime = HostMCPRuntime()
    }

    func start() throws {
        guard serverTask == nil else { return }

        let router = Router()
        router.get("web/healthz") { _, _ async throws -> Response in
            self.jsonResponse(["ok": true], status: .ok)
        }
        router.post("web/policy/list") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            let payload = try await self.decodeJSONBody(request: request)
            let groupFolder = (payload["groupFolder"] as? String) ?? "unknown-group"
            return self.jsonResponse([
                "ok": true,
                "groupFolder": groupFolder,
                "global": [
                    "allow": ["public-internet"],
                    "deny": ["localhost", "private-network", "link-local", "metadata-service"],
                ],
                "overlay": [
                    "allow": [],
                    "deny": [],
                ],
                "effective": [
                    "allow": ["public-internet"],
                    "deny": ["localhost", "private-network", "link-local", "metadata-service"],
                ],
            ], status: .ok)
        }
        router.post("web/search") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            do {
                let payload = try await self.decodeJSONBody(request: request)
                let query = (payload["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !query.isEmpty else {
                    return self.jsonResponse(["ok": false, "error": "Missing query"], status: .badRequest)
                }
                let limit = max(1, min((payload["limit"] as? Int) ?? 5, 20))
                let search = try await self.performWebSearch(query: query, limit: limit)
                return self.jsonResponse([
                    "ok": true,
                    "provider": search.provider,
                    "query": query,
                    "count": search.results.count,
                    "results": search.results,
                ], status: .ok)
            } catch {
                return self.jsonResponse(["ok": false, "error": error.localizedDescription], status: .badGateway)
            }
        }
        router.post("web/fetch") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            do {
                let payload = try await self.decodeJSONBody(request: request)
                let urlString = (payload["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let targetURL = URL(string: urlString), !urlString.isEmpty else {
                    return self.jsonResponse(["ok": false, "error": "Missing or invalid url"], status: .badRequest)
                }
                guard Self.isSafePublicURL(targetURL) else {
                    return self.jsonResponse(["ok": false, "error": "Target URL blocked by policy"], status: .forbidden)
                }

                let method = ((payload["method"] as? String) ?? "GET").uppercased()
                let maxBytes = max(1_024, min((payload["maxBytes"] as? Int) ?? 200_000, 1_000_000))
                let headers = payload["headers"] as? [String: Any] ?? [:]

                var upstream = URLRequest(url: targetURL)
                upstream.httpMethod = method
                upstream.timeoutInterval = 60
                for (name, value) in headers {
                    upstream.setValue("\(value)", forHTTPHeaderField: name)
                }

                let (rawData, response) = try await self.session.data(for: upstream)
                guard let http = response as? HTTPURLResponse else {
                    return self.jsonResponse(["ok": false, "error": "Non-HTTP response"], status: .badGateway)
                }

                let clipped = rawData.prefix(maxBytes)
                let bodyText = String(data: clipped, encoding: .utf8) ?? ""
                return self.jsonResponse([
                    "ok": true,
                    "url": targetURL.absoluteString,
                    "status": http.statusCode,
                    "truncated": rawData.count > clipped.count,
                    "bytes": clipped.count,
                    "contentType": http.value(forHTTPHeaderField: "Content-Type") ?? "",
                    "body": bodyText,
                ], status: .ok)
            } catch {
                return self.jsonResponse(["ok": false, "error": error.localizedDescription], status: .badGateway)
            }
        }
        router.get("mcp/host/status") { [weak self] _, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return await self.mcpHostStatusResponse()
        }
        router.post("mcp/host/status") { [weak self] _, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return await self.mcpHostStatusResponse()
        }
        router.post("mcp/host/bootstrap") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            let payload = try await self.decodeJSONBody(request: request)
            return await self.mcpHostBootstrapResponse(payload: payload)
        }
        router.post("mcp/host/call") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            let payload = try await self.decodeJSONBody(request: request)
            return await self.mcpHostCallResponse(payload: payload)
        }
        router.post("mcp/host/cli") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            let payload = try await self.decodeJSONBody(request: request)
            return await self.mcpHostCLIResponse(payload: payload)
        }
        router.get("focusrelay/healthz") { [weak self] _, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return await self.focusRelayBridgeHealthResponse()
        }
        router.post("focusrelay/healthz") { [weak self] _, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return await self.focusRelayBridgeHealthResponse()
        }
        router.post("focusrelay/inbox") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            let payload = try await self.decodeJSONBody(request: request)
            return await self.focusRelayInboxResponse(payload: payload)
        }
        router.post("focusrelay/cli") { [weak self] request, _ async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            let payload = try await self.decodeJSONBody(request: request)
            return await self.focusRelayCLIResponse(payload: payload)
        }
        router.post("relay/**") { [weak self] request, context async throws -> Response in
            guard let self else {
                return Response(status: .internalServerError)
            }
            return try await self.proxy(request: request, context: context)
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(settings.bindHost, port: settings.port),
                serverName: "NanoClaw-LLMRelay"
            ),
            onServerRunning: { [logger, settings] _ in
                logger.info("Swift LLM relay started bind=\(settings.bindHost):\(settings.port)")
            },
            logger: logger
        )

        serverTask = Task { [logger] in
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                logger.info("Swift LLM relay stopped")
            } catch {
                logger.error("Swift LLM relay failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
        Task { await hostMCPRuntime.shutdown() }
    }

    private func mcpHostStatusResponse() async -> Response {
        let snapshot = await hostMCPRuntime.status()
        return jsonResponse(
            [
                "ok": true,
                "loadedServers": snapshot.serverIDs,
                "loadedServerCount": snapshot.serverIDs.count,
                "toolCountByServer": snapshot.toolCountByServer,
                "diagnostics": snapshot.diagnostics,
            ],
            status: .ok
        )
    }

    private func mcpHostBootstrapResponse(payload: [String: Any]) async -> Response {
        guard let rawServers = payload["servers"] as? [Any], rawServers.count <= 32 else {
            return jsonResponse(
                ["ok": false, "error": "Missing or invalid servers payload"],
                status: .badRequest
            )
        }

        var specs: [HostMCPRuntime.ServerSpec] = []
        specs.reserveCapacity(rawServers.count)

        for rawServer in rawServers {
            guard let serverObject = rawServer as? [String: Any] else {
                return jsonResponse(
                    ["ok": false, "error": "Invalid server entry"],
                    status: .badRequest
                )
            }

            let id = (serverObject["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard Self.validateMCPServerID(id) else {
                return jsonResponse(
                    ["ok": false, "error": "Invalid server id: \(id)"],
                    status: .badRequest
                )
            }

            let command = (serverObject["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard Self.validateHostCLICommand(command) else {
                return jsonResponse(
                    ["ok": false, "error": "Invalid command for server \(id)"],
                    status: .badRequest
                )
            }

            let args = (serverObject["args"] as? [Any] ?? []).compactMap { $0 as? String }
            guard Self.validateHostCLIArguments(args) else {
                return jsonResponse(
                    ["ok": false, "error": "Invalid arguments for server \(id)"],
                    status: .badRequest
                )
            }

            let rawEnvironment = serverObject["env"] as? [String: Any] ?? [:]
            var environment: [String: String] = [:]
            for (key, value) in rawEnvironment {
                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.validateEnvironmentKey(trimmedKey) else {
                    return jsonResponse(
                        ["ok": false, "error": "Invalid env key for server \(id): \(key)"],
                        status: .badRequest
                    )
                }
                let renderedValue = "\(value)"
                guard Self.validateEnvironmentValue(renderedValue) else {
                    return jsonResponse(
                        ["ok": false, "error": "Invalid env value for server \(id): \(key)"],
                        status: .badRequest
                    )
                }
                environment[trimmedKey] = renderedValue
            }

            let cwd = (serverObject["cwd"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cwd.isEmpty && !Self.validateWorkingDirectory(cwd) {
                return jsonResponse(
                    ["ok": false, "error": "Invalid working directory for server \(id)"],
                    status: .badRequest
                )
            }

            specs.append(
                HostMCPRuntime.ServerSpec(
                    id: id,
                    command: command,
                    arguments: args,
                    environment: environment,
                    workingDirectory: cwd
                )
            )
        }

        do {
            let result = try await hostMCPRuntime.bootstrap(specs: specs)
            let payloadServers: [[String: Any]] = result.servers.map { server in
                let toolPayloads: [[String: Any]] = server.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description ?? "",
                        "inputSchema": Self.jsonObject(fromMCPValue: tool.inputSchema),
                    ]
                }
                return [
                    "id": server.id,
                    "tools": toolPayloads,
                ]
            }

            return jsonResponse(
                [
                    "ok": true,
                    "loadedServerCount": result.servers.count,
                    "loadedToolCount": payloadServers.reduce(0) { partial, server in
                        partial + ((server["tools"] as? [[String: Any]])?.count ?? 0)
                    },
                    "servers": payloadServers,
                    "diagnostics": result.diagnostics,
                ],
                status: .ok
            )
        } catch {
            return jsonResponse(
                ["ok": false, "error": error.localizedDescription],
                status: .badGateway
            )
        }
    }

    private func mcpHostCallResponse(payload: [String: Any]) async -> Response {
        let serverID = (payload["serverId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.validateMCPServerID(serverID) else {
            return jsonResponse(
                ["ok": false, "error": "Invalid serverId"],
                status: .badRequest
            )
        }

        let toolName = (payload["toolName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.validateMCPToolName(toolName) else {
            return jsonResponse(
                ["ok": false, "error": "Invalid toolName"],
                status: .badRequest
            )
        }

        let rawArguments = payload["arguments"] as? [String: Any] ?? [:]
        guard rawArguments.count <= 100 else {
            return jsonResponse(
                ["ok": false, "error": "Too many tool arguments"],
                status: .badRequest
            )
        }

        do {
            var arguments: [String: MCP.Value] = [:]
            arguments.reserveCapacity(rawArguments.count)
            for (key, value) in rawArguments {
                guard Self.validateMCPToolArgumentName(key) else {
                    return jsonResponse(
                        ["ok": false, "error": "Invalid argument name: \(key)"],
                        status: .badRequest
                    )
                }
                arguments[key] = try Self.mcpValue(fromJSONObject: value)
            }

            let result = try await hostMCPRuntime.callTool(
                serverID: serverID,
                toolName: toolName,
                arguments: arguments
            )
            return jsonResponse(
                [
                    "ok": true,
                    "output": result.output,
                    "isError": result.isError,
                ],
                status: .ok
            )
        } catch {
            return jsonResponse(
                ["ok": false, "error": error.localizedDescription],
                status: .badGateway
            )
        }
    }

    private func mcpHostCLIResponse(payload: [String: Any]) async -> Response {
        let serverID = (payload["serverId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.validateMCPServerID(serverID) else {
            return jsonResponse(
                ["ok": false, "error": "Invalid serverId"],
                status: .badRequest
            )
        }

        let args = (payload["args"] as? [Any] ?? []).compactMap { $0 as? String }
        guard Self.validateHostCLIArguments(args) else {
            return jsonResponse(
                ["ok": false, "error": "Arguments are invalid or exceed limits"],
                status: .badRequest
            )
        }

        do {
            let run = try await hostMCPRuntime.runCLI(serverID: serverID, arguments: args)
            return jsonResponse(
                [
                    "ok": run.exitCode == 0,
                    "command": run.command,
                    "durationMs": run.durationMs,
                    "exitCode": Int(run.exitCode),
                    "stdout": run.stdout,
                    "stderr": run.stderr,
                ],
                status: .ok
            )
        } catch {
            return jsonResponse(
                ["ok": false, "error": error.localizedDescription],
                status: .badGateway
            )
        }
    }

    private func focusRelayBridgeHealthResponse() async -> Response {
        guard focusRelayEnabled else {
            return jsonResponse(
                ["ok": false, "error": "FocusRelay integration is disabled"],
                status: .serviceUnavailable
            )
        }

        do {
            let run = try runFocusRelay(arguments: ["bridge-health-check"])
            let parsedJSON = try parseJSONObject(run.stdout)
            return jsonResponse(
                [
                    "ok": run.exitCode == 0,
                    "exitCode": Int(run.exitCode),
                    "durationMs": run.durationMs,
                    "command": run.command,
                    "result": parsedJSON,
                    "stderr": run.stderr,
                ],
                status: .ok
            )
        } catch {
            return jsonResponse(
                ["ok": false, "error": error.localizedDescription],
                status: .badGateway
            )
        }
    }

    private func focusRelayInboxResponse(payload: [String: Any]) async -> Response {
        guard focusRelayEnabled else {
            return jsonResponse(
                ["ok": false, "error": "FocusRelay integration is disabled"],
                status: .serviceUnavailable
            )
        }

        let limit = max(1, min(Self.intValue(payload["limit"]) ?? 20, 100))
        let availableOnly = Self.boolValue(payload["availableOnly"]) ?? false
        let fields = "id,name,available,projectName,dueDate,deferDate"

        var arguments = [
            "list-tasks",
            "--inbox-only", "true",
            "--inbox-view", "everything",
            "--limit", "\(limit)",
            "--fields", fields,
        ]
        if availableOnly {
            arguments.append(contentsOf: ["--available-only", "true"])
        }

        do {
            let run = try runFocusRelay(arguments: arguments)
            let parsedJSON = try parseJSONObject(run.stdout)
            guard let items = parsedJSON["items"] as? [[String: Any]] else {
                return jsonResponse(
                    [
                        "ok": false,
                        "error": "FocusRelay returned an unexpected inbox payload",
                        "stdout": run.stdout,
                        "stderr": run.stderr,
                    ],
                    status: .badGateway
                )
            }
            return jsonResponse(
                [
                    "ok": true,
                    "command": run.command,
                    "durationMs": run.durationMs,
                    "returnedCount": items.count,
                    "items": items,
                ],
                status: .ok
            )
        } catch {
            return jsonResponse(
                ["ok": false, "error": error.localizedDescription],
                status: .badGateway
            )
        }
    }

    private func focusRelayCLIResponse(payload: [String: Any]) async -> Response {
        guard focusRelayEnabled else {
            return jsonResponse(
                ["ok": false, "error": "FocusRelay integration is disabled"],
                status: .serviceUnavailable
            )
        }

        guard let rawSubcommand = (payload["subcommand"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawSubcommand.isEmpty else {
            return jsonResponse(
                ["ok": false, "error": "Missing subcommand"],
                status: .badRequest
            )
        }

        let subcommand = Self.normalizeFocusRelaySubcommand(rawSubcommand)
        guard Self.isAllowedFocusRelaySubcommand(subcommand) else {
            return jsonResponse(
                ["ok": false, "error": "Subcommand not allowed: \(rawSubcommand)"],
                status: .forbidden
            )
        }

        let args = (payload["args"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        guard Self.validateFocusRelayArguments(args) else {
            return jsonResponse(
                ["ok": false, "error": "Arguments are invalid or exceed limits"],
                status: .badRequest
            )
        }

        do {
            let run = try runFocusRelay(arguments: [subcommand] + args)
            let payload: [String: Any] = [
                "ok": run.exitCode == 0,
                "command": run.command,
                "durationMs": run.durationMs,
                "exitCode": Int(run.exitCode),
                "stdout": run.stdout,
                "stderr": run.stderr,
            ]
            return jsonResponse(payload, status: .ok)
        } catch {
            return jsonResponse(
                ["ok": false, "error": error.localizedDescription],
                status: .badGateway
            )
        }
    }

    private func runFocusRelay(arguments: [String]) throws -> FocusRelayRunResult {
        let command = focusRelayCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw NSError(
                domain: "NanoClawHost.FocusRelay",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "FocusRelay command path is not configured"]
            )
        }
        guard FileManager.default.isExecutableFile(atPath: command) else {
            throw NSError(
                domain: "NanoClawHost.FocusRelay",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "FocusRelay command is not executable: \(command)"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Date()
        try process.run()
        process.waitUntilExit()
        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let renderedCommand = ([command] + arguments).joined(separator: " ")

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "NanoClawHost.FocusRelay",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "focusrelay exited with status \(process.terminationStatus): \(stderr.isEmpty ? stdout : stderr)",
                ]
            )
        }

        return FocusRelayRunResult(
            command: renderedCommand,
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            durationMs: durationMs
        )
    }

    private func parseJSONObject(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "NanoClawHost.FocusRelay",
                code: 502,
                userInfo: [NSLocalizedDescriptionKey: "FocusRelay returned non-JSON output"]
            )
        }
        return json
    }

    private func proxy(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        guard request.method == .post else {
            return Response(status: .methodNotAllowed)
        }

        guard let resolved = LLMRelayConfig.resolveRelayRoute(path: request.uri.path) else {
            return Response(status: .notFound)
        }

        var upstreamURL = resolved.upstreamURL
        if let query = request.uri.query, !query.isEmpty {
            var components = URLComponents(url: upstreamURL, resolvingAgainstBaseURL: false)
            components?.percentEncodedQuery = query
            if let updated = components?.url {
                upstreamURL = updated
            }
        }

        var requestCopy = request
        let bodyBuffer = try await requestCopy.collectBody(upTo: 4 * 1024 * 1024)
        let bodyData = Data(bodyBuffer.readableBytesView)

        var urlRequest = URLRequest(url: upstreamURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData

        for header in request.headers {
            let name = header.name.canonicalName
            if name == "host" || name == "content-length" || name == "connection" {
                continue
            }
            urlRequest.setValue(header.value, forHTTPHeaderField: name)
        }

        do {
            let (responseBody, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return relayErrorResponse(
                    status: HTTPTypes.HTTPResponse.Status(code: 502),
                    message: "Invalid upstream response"
                )
            }

            var headers = HTTPFields()
            if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"), !contentType.isEmpty {
                headers[.contentType] = contentType
            }
            headers[.contentLength] = "\(responseBody.count)"

            let buffer = ByteBuffer(bytes: responseBody)
            return Response(
                status: .init(code: httpResponse.statusCode),
                headers: headers,
                body: .init(byteBuffer: buffer)
            )
        } catch {
            context.logger.error("Swift LLM relay upstream error provider=\(resolved.provider.rawValue) path=\(request.uri.path) error=\(error.localizedDescription)")
            return relayErrorResponse(
                status: HTTPTypes.HTTPResponse.Status(code: 502),
                message: "Upstream request failed: \(error.localizedDescription)"
            )
        }
    }

    private func relayErrorResponse(status: HTTPTypes.HTTPResponse.Status, message: String) -> Response {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let bodyString = "{\"error\":\"\(escaped)\"}"
        let buffer = ByteBuffer(string: bodyString)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.contentLength] = "\(buffer.readableBytes)"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: buffer)
        )
    }

    private func jsonResponse(_ payload: [String: Any], status: HTTPTypes.HTTPResponse.Status) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        let buffer = ByteBuffer(bytes: data)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.contentLength] = "\(buffer.readableBytes)"
        return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
    }

    private func decodeJSONBody(request: Request) async throws -> [String: Any] {
        var copy = request
        let bodyBuffer = try await copy.collectBody(upTo: 2 * 1024 * 1024)
        let data = Data(bodyBuffer.readableBytesView)
        guard !data.isEmpty else { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NanoClawHost", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON body"])
        }
        return value
    }

    private func performWebSearch(query: String, limit: Int) async throws -> (provider: String, results: [[String: String]]) {
        if Self.isNewsLikeQuery(query) {
            let newsResults = try await performGoogleNewsRSSSearch(query: query, limit: limit)
            if !newsResults.isEmpty {
                return ("google_news_rss", newsResults)
            }
        }

        let ddgResults = try await performDuckDuckGoSearch(query: query, limit: limit)
        if !ddgResults.isEmpty,
           !ddgResults.allSatisfy({ ($0["url"] ?? "").contains("duckduckgo.com/") }) {
            return ("duckduckgo", ddgResults)
        }
        let newsResults = try await performGoogleNewsRSSSearch(query: query, limit: limit)
        if !newsResults.isEmpty {
            return ("google_news_rss", newsResults)
        }
        return ("duckduckgo", ddgResults)
    }

    private func performDuckDuckGoSearch(query: String, limit: Int) async throws -> [[String: String]] {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        guard let url = components.url else {
            return []
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "NanoClawHost", code: 502, userInfo: [NSLocalizedDescriptionKey: "Search provider unavailable"])
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [[String: String]] = []
        func appendTopic(_ value: [String: Any]) {
            if results.count >= limit { return }
            if let firstURL = value["FirstURL"] as? String, Self.isSafePublicURL(URL(string: firstURL)),
               let text = value["Text"] as? String {
                results.append([
                    "title": text,
                    "url": firstURL,
                    "snippet": text,
                ])
            }
            if let topics = value["Topics"] as? [[String: Any]] {
                for nested in topics {
                    appendTopic(nested)
                    if results.count >= limit { return }
                }
            }
        }

        if let related = payload["RelatedTopics"] as? [[String: Any]] {
            for topic in related {
                appendTopic(topic)
                if results.count >= limit { break }
            }
        }

        return results
    }

    private func performGoogleNewsRSSSearch(query: String, limit: Int) async throws -> [[String: String]] {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: "en-US"),
            URLQueryItem(name: "gl", value: "US"),
            URLQueryItem(name: "ceid", value: "US:en"),
        ]
        guard let url = components.url else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }

        guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else {
            return []
        }
        return Self.parseGoogleNewsRSS(xml: xml, limit: limit)
    }

    nonisolated static func parseGoogleNewsRSS(xml: String, limit: Int) -> [[String: String]] {
        guard limit > 0 else { return [] }
        let itemPattern = #"<item>([\s\S]*?)<\/item>"#
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern, options: []) else {
            return []
        }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = itemRegex.matches(in: xml, options: [], range: nsRange)
        var results: [[String: String]] = []

        for match in matches {
            if results.count >= limit { break }
            guard match.numberOfRanges >= 2,
                  let itemRange = Range(match.range(at: 1), in: xml) else {
                continue
            }
            let itemBody = String(xml[itemRange])
            let title = extractFirstXMLTagValue("title", from: itemBody) ?? ""
            let link = extractFirstXMLTagValue("link", from: itemBody) ?? ""
            let pubDate = extractFirstXMLTagValue("pubDate", from: itemBody)
            let source = extractFirstXMLTagValue("source", from: itemBody)

            guard !title.isEmpty,
                  let linkURL = URL(string: link),
                  isSafePublicURL(linkURL) else {
                continue
            }
            var entry: [String: String] = [
                "title": title,
                "url": link,
                "snippet": title,
            ]
            if let pubDate, !pubDate.isEmpty {
                entry["published_at"] = pubDate
            }
            if let source, !source.isEmpty {
                entry["source"] = source
            }
            results.append(entry)
        }
        return results
    }

    nonisolated static func isNewsLikeQuery(_ query: String) -> Bool {
        let normalized = query.lowercased()
        let markers = [
            "news",
            "headline",
            "digest",
            "report",
            "latest",
            "today",
            "announcement",
            "launch",
            "release"
        ]
        return markers.contains { normalized.contains($0) }
    }

    nonisolated private static func extractFirstXMLTagValue(_ tag: String, from xml: String) -> String? {
        let pattern = "<\(tag)(?:\\s[^>]*)?>\\s*(?:<!\\[CDATA\\[)?(.*?)(?:\\]\\]>)?\\s*</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return xml[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizeFocusRelaySubcommand(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    nonisolated static func validateMCPServerID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            return false
        }
        guard let regex = try? NSRegularExpression(pattern: #"^[A-Za-z0-9._-]+$"#) else {
            return false
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    nonisolated static func validateMCPToolName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else {
            return false
        }
        return !trimmed.contains("\0") && !trimmed.contains("\n") && !trimmed.contains("\r")
    }

    nonisolated static func validateMCPToolArgumentName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            return false
        }
        guard let regex = try? NSRegularExpression(pattern: #"^[A-Za-z0-9._-]+$"#) else {
            return false
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    nonisolated static func validateHostCLICommand(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else {
            return false
        }
        return !trimmed.contains("\0") && !trimmed.contains("\n") && !trimmed.contains("\r")
    }

    nonisolated static func validateHostCLIArguments(_ values: [String]) -> Bool {
        guard values.count <= 80 else { return false }
        for value in values {
            if value.count > 256 { return false }
            if value.contains("\0") || value.contains("\n") || value.contains("\r") {
                return false
            }
        }
        return true
    }

    nonisolated static func validateEnvironmentKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else {
            return false
        }
        guard let regex = try? NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#) else {
            return false
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    nonisolated static func validateEnvironmentValue(_ value: String) -> Bool {
        guard value.count <= 4096 else { return false }
        return !value.contains("\0")
    }

    nonisolated static func validateWorkingDirectory(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1024 else {
            return false
        }
        return !trimmed.contains("\0") && !trimmed.contains("\n") && !trimmed.contains("\r")
    }

    nonisolated static func isAllowedFocusRelaySubcommand(_ value: String) -> Bool {
        let normalized = normalizeFocusRelaySubcommand(value)
        let allowed: Set<String> = [
            "list-tasks",
            "get-task",
            "list-projects",
            "list-tags",
            "task-counts",
            "project-counts",
            "debug-inbox-probe",
            "debug-inbox-probe-alt",
            "bridge-health-check",
        ]
        return allowed.contains(normalized)
    }

    nonisolated static func validateFocusRelayArguments(_ values: [String]) -> Bool {
        validateHostCLIArguments(values)
    }

    nonisolated static func mcpValue(fromJSONObject raw: Any) throws -> MCP.Value {
        switch raw {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            let doubleValue = number.doubleValue
            if floor(doubleValue) == doubleValue {
                return .int(number.intValue)
            }
            return .double(doubleValue)
        case let array as [Any]:
            return .array(try array.map(mcpValue(fromJSONObject:)))
        case let dictionary as [String: Any]:
            var mapped: [String: MCP.Value] = [:]
            mapped.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                mapped[key] = try mcpValue(fromJSONObject: value)
            }
            return .object(mapped)
        default:
            throw NSError(
                domain: "NanoClawHost.MCP",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value in MCP payload"]
            )
        }
    }

    nonisolated static func jsonObject(fromMCPValue value: MCP.Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .string(let string):
            return string
        case .data(_, let data):
            return data.base64EncodedString()
        case .array(let values):
            return values.map { jsonObject(fromMCPValue: $0) }
        case .object(let dictionary):
            return dictionary.mapValues { jsonObject(fromMCPValue: $0) }
        }
    }

    nonisolated static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let string as String:
            let lowered = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(lowered) { return true }
            if ["0", "false", "no", "off"].contains(lowered) { return false }
            return nil
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    nonisolated static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }

    nonisolated static func isSafePublicURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if host == "localhost" || host.hasSuffix(".local") || host == "host.docker.internal" {
            return false
        }

        if host == "0.0.0.0" || host == "127.0.0.1" || host == "::1" {
            return false
        }

        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
            return false
        }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return false
            }
        }

        if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") {
            return false
        }

        return true
    }
}
