import Foundation

/// Centralized outbound channel routing.
/// Telegram is the only active channel today; additional detectors can be added later.
struct ChannelResolver {
    private static let prefixDetectors: [(prefix: String, channel: String)] = [
        ("telegram_", "telegram")
    ]

    static func resolveOutboundChannel(forChatJID chatJID: String) -> String {
        for detector in prefixDetectors where chatJID.hasPrefix(detector.prefix) {
            return detector.channel
        }
        return "telegram"
    }
}
