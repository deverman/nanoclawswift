import Foundation
import Logging
import Dispatch
import Darwin

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(data.count)"
            ],
            body: data
        )
    }
}

final class UnixHTTPServer {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let socketPath: String
    private let logger: Logger
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "nanoclaw.host.uds.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "nanoclaw.host.uds.client", qos: .userInitiated, attributes: .concurrent)

    private var serverFD: Int32 = -1
    private var running = false
    private let stateLock = NSLock()

    init(socketPath: String, logger: Logger, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.logger = logger
        self.handler = handler
    }

    func start() throws {
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "NanoClawHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create unix socket"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxPathLength else {
            close(fd)
            throw NSError(domain: "NanoClawHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
        }

        _ = socketPath.withCString { pointer in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPointer in
                pathPointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { rebound in
                    strncpy(rebound, pointer, maxPathLength - 1)
                }
            }
        }

        let length = socklen_t(MemoryLayout.size(ofValue: addr))
        let bindResult: Int32 = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, length)
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw NSError(
                domain: "NanoClawHost",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind unix socket at \(socketPath): \(String(cString: strerror(errno)))"]
            )
        }

        guard listen(fd, 128) == 0 else {
            close(fd)
            throw NSError(
                domain: "NanoClawHost",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on unix socket: \(String(cString: strerror(errno)))"]
            )
        }

        stateLock.lock()
        serverFD = fd
        running = true
        stateLock.unlock()

        logger.info("NanoClawHost UDS listener ready at \(socketPath)")

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        stateLock.lock()
        let fd = serverFD
        running = false
        serverFD = -1
        stateLock.unlock()

        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(currentServerFD(), nil, nil)
            if clientFD < 0 {
                if !isRunning { break }
                continue
            }

            clientQueue.async { [weak self] in
                self?.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        var buffer = Data()
        var request: HTTPRequest?
        var chunk = [UInt8](repeating: 0, count: 8192)

        while request == nil {
            let readCount = recv(fd, &chunk, chunk.count, 0)
            if readCount < 0 {
                return
            }
            if readCount == 0 {
                return
            }
            buffer.append(chunk, count: Int(readCount))

            do {
                request = try tryParseRequest(data: buffer)
            } catch {
                let response = HTTPResponse.json(["error": "Malformed request"], statusCode: 400)
                writeResponse(response, to: fd)
                return
            }
        }

        guard let request else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var response = HTTPResponse(statusCode: 500, body: Data("{\"error\":\"internal\"}".utf8))

        Task {
            response = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()

        writeResponse(response, to: fd)
    }

    private func writeResponse(_ response: HTTPResponse, to fd: Int32) {
        let head = buildHTTPHead(statusCode: response.statusCode, headers: response.headers)
        var payload = Data(head.utf8)
        payload.append(response.body)

        payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let count = send(fd, base.advanced(by: sent), payload.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }

    private func buildHTTPHead(statusCode: Int, headers: [String: String]) -> String {
        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Status"
        }

        var mergedHeaders = headers
        mergedHeaders["Connection"] = "close"

        var lines: [String] = ["HTTP/1.1 \(statusCode) \(reason)"]
        for (key, value) in mergedHeaders {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func tryParseRequest(data: Data) throws -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw NSError(domain: "NanoClawHost", code: 10, userInfo: nil)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw NSError(domain: "NanoClawHost", code: 11, userInfo: nil)
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            throw NSError(domain: "NanoClawHost", code: 12, userInfo: nil)
        }

        let method = String(requestParts[0]).uppercased()
        let path = String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let requiredLength = bodyStart + contentLength
        guard data.count >= requiredLength else {
            return nil
        }
        let body: Data
        if contentLength > 0 {
            body = Data(data[bodyStart..<requiredLength])
        } else {
            body = Data()
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func currentServerFD() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return serverFD
    }
}
