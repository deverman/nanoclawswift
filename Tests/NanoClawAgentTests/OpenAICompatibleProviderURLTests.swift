import Foundation
import Testing

@testable import NanoClawAgent

@Test
func testChatCompletionsURLPreservesV1PathSegment() throws {
    let base = try #require(URL(string: "https://api.moonshot.ai/v1"))
    let built = OpenAICompatibleProvider.chatCompletionsURL(baseURL: base)

    #expect(built.absoluteString == "https://api.moonshot.ai/v1/chat/completions")
}

@Test
func testChatCompletionsURLPreservesRelayPathPrefix() throws {
    let base = try #require(URL(string: "http://192.168.64.1:18081/relay/kimi/v1"))
    let built = OpenAICompatibleProvider.chatCompletionsURL(baseURL: base)

    #expect(built.absoluteString == "http://192.168.64.1:18081/relay/kimi/v1/chat/completions")
}
