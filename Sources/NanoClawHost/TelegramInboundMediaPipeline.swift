import Foundation
import Logging
#if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import Vision
#endif

protocol TelegramFileFetching: Sendable {
    func resolveFilePath(fileID: String) async throws -> String
    func downloadFile(filePath: String) async throws -> Data
}

protocol ImageTextExtracting: Sendable {
    func extractText(from imagePath: String) async -> String?
}

struct NoopImageTextExtractor: ImageTextExtracting {
    func extractText(from imagePath: String) async -> String? {
        _ = imagePath
        return nil
    }
}

#if canImport(Vision) && canImport(CoreGraphics) && canImport(ImageIO)
struct VisionImageTextExtractor: ImageTextExtracting {
    let minimumConfidence: Float

    init(minimumConfidence: Float = 0.4) {
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
    }

    func extractText(from imagePath: String) async -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = observations.compactMap { observation -> String? in
                    guard let best = observation.topCandidates(1).first,
                          best.confidence >= minimumConfidence else {
                        return nil
                    }
                    return best.string
                }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
#endif

actor TelegramBotFileFetcher: TelegramFileFetching {
    private struct APIEnvelope<ResultType: Decodable>: Decodable {
        let ok: Bool
        let result: ResultType?
        let description: String?
    }

    private struct GetFileResult: Decodable {
        let file_path: String
    }

    private let botToken: String
    private let session: URLSession
    private let apiBaseURL: URL

    init(
        botToken: String,
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.telegram.org")!
    ) {
        self.botToken = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.apiBaseURL = apiBaseURL
    }

    func resolveFilePath(fileID: String) async throws -> String {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("bot\(botToken)/getFile"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "file_id", value: fileID)]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let envelope = try JSONDecoder().decode(APIEnvelope<GetFileResult>.self, from: data)
        guard envelope.ok, let path = envelope.result?.file_path, !path.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return path
    }

    func downloadFile(filePath: String) async throws -> Data {
        let fileURL = apiBaseURL.appendingPathComponent("file/bot\(botToken)/\(filePath)")
        let (data, response) = try await session.data(from: fileURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

struct TelegramInboundMediaPipeline: Sendable {
    private let groupsDir: String
    private let logger: Logger
    private let fetcher: any TelegramFileFetching
    private let extractor: any ImageTextExtracting
    private let maxFileSizeBytes: Int

    init(
        groupsDir: String,
        logger: Logger,
        fetcher: any TelegramFileFetching,
        extractor: any ImageTextExtracting = NoopImageTextExtractor(),
        maxFileSizeBytes: Int = 10 * 1024 * 1024
    ) {
        self.groupsDir = groupsDir
        self.logger = logger
        self.fetcher = fetcher
        self.extractor = extractor
        self.maxFileSizeBytes = max(1_024, maxFileSizeBytes)
    }

    func enrich(event: InboundEventRequest, groupFolder: String) async -> InboundEventRequest {
        guard event.channel == "telegram",
              let attachments = event.attachments,
              !attachments.isEmpty else {
            return event
        }

        var updatedAttachments: [InboundAttachment] = []
        updatedAttachments.reserveCapacity(attachments.count)

        for (index, attachment) in attachments.enumerated() {
            if attachment.kind != "photo" {
                updatedAttachments.append(attachment)
                continue
            }

            let enriched = await hydratePhotoAttachment(
                attachment,
                event: event,
                groupFolder: groupFolder,
                index: index
            )
            updatedAttachments.append(enriched)
        }

        return InboundEventRequest(
            channel: event.channel,
            chat_jid: event.chat_jid,
            sender: event.sender,
            sender_name: event.sender_name,
            content: enrichedContent(
                original: event.content,
                attachments: updatedAttachments
            ),
            timestamp: event.timestamp,
            message_id: event.message_id,
            is_direct: event.is_direct,
            attachments: updatedAttachments
        )
    }

    private func hydratePhotoAttachment(
        _ attachment: InboundAttachment,
        event: InboundEventRequest,
        groupFolder: String,
        index: Int
    ) async -> InboundAttachment {
        guard let fileID = attachment.telegramFileID,
              !fileID.isEmpty else {
            return attachment
        }

        do {
            let remotePath = try await fetcher.resolveFilePath(fileID: fileID)
            let fileData = try await fetcher.downloadFile(filePath: remotePath)
            guard fileData.count <= maxFileSizeBytes else {
                logger.warning(
                    "Skipping inbound media larger than max size message=\(event.message_id) bytes=\(fileData.count)"
                )
                return attachment
            }
            let local = try persist(
                data: fileData,
                remotePath: remotePath,
                groupFolder: groupFolder,
                messageID: event.message_id,
                index: index
            )
            let rawOCR = await extractor.extractText(from: local.hostPath)
            let ocrText = rawOCR?.trimmingCharacters(in: .whitespacesAndNewlines)

            return InboundAttachment(
                kind: attachment.kind,
                telegramFileID: attachment.telegramFileID,
                telegramFileUniqueID: attachment.telegramFileUniqueID,
                width: attachment.width,
                height: attachment.height,
                fileSize: attachment.fileSize,
                mimeType: attachment.mimeType,
                localPath: local.containerPath,
                ocrText: (ocrText?.isEmpty == false) ? ocrText : nil
            )
        } catch {
            logger.warning("Inbound media hydrate failed message=\(event.message_id): \(error.localizedDescription)")
            return attachment
        }
    }

    private func persist(
        data: Data,
        remotePath: String,
        groupFolder: String,
        messageID: String,
        index: Int
    ) throws -> (hostPath: String, containerPath: String) {
        let mediaDir = URL(fileURLWithPath: groupsDir)
            .appendingPathComponent(groupFolder)
            .appendingPathComponent(".nanoclaw")
            .appendingPathComponent("inbound-media")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let ext = fileExtension(from: remotePath)
        let filename = "\(messageID)-\(index).\(ext)"
        let destination = mediaDir.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        let containerPath = "/workspace/group/.nanoclaw/inbound-media/\(filename)"
        return (destination.path, containerPath)
    }

    private func fileExtension(from remotePath: String) -> String {
        let ext = URL(fileURLWithPath: remotePath).pathExtension
        if ext.isEmpty { return "jpg" }
        return ext.lowercased()
    }

    private func enrichedContent(original: String, attachments: [InboundAttachment]) -> String {
        let hasPhoto = attachments.contains(where: { $0.kind == "photo" })
        guard hasPhoto else { return original }

        let normalizedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let basePrompt: String = {
            if normalizedOriginal.isEmpty || normalizedOriginal == "[Photo received]" {
                return "User sent a photo."
            }
            return normalizedOriginal
        }()

        if let ocr = attachments
            .compactMap(\.ocrText)
            .first(where: { !$0.isEmpty }) {
            return "\(basePrompt)\n\nOCR text:\n\(ocr)"
        }
        if let localPath = attachments
            .compactMap(\.localPath)
            .first(where: { !$0.isEmpty }) {
            return "\(basePrompt)\n\nImage saved to \(localPath)."
        }
        return basePrompt
    }
}
