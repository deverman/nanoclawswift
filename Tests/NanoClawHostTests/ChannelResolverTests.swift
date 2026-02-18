import Testing

@testable import NanoClawHost

@Test
func testChannelResolverReturnsTelegramForTelegramPrefix() {
    let channel = ChannelResolver.resolveOutboundChannel(forChatJID: "telegram_123@direct")
    #expect(channel == "telegram")
}

@Test
func testChannelResolverDefaultsToTelegramForUnknownPrefix() {
    let channel = ChannelResolver.resolveOutboundChannel(forChatJID: "whatsapp_123@g.us")
    #expect(channel == "telegram")
}

@Test
func testChannelResolverDefaultsToTelegramForEmptyChatJID() {
    let channel = ChannelResolver.resolveOutboundChannel(forChatJID: "")
    #expect(channel == "telegram")
}
