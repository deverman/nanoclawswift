import Testing
import Foundation

@testable import NanoClawHost

@Test
func testWebSafetyAllowsPublicHTTPSHost() {
    #expect(LLMRelayServer.isSafePublicURL(URL(string: "https://www.apple.com/newsroom/")))
}

@Test
func testWebSafetyRejectsLocalhostAndPrivateHosts() {
    #expect(!LLMRelayServer.isSafePublicURL(URL(string: "http://localhost:8080")))
    #expect(!LLMRelayServer.isSafePublicURL(URL(string: "http://127.0.0.1")))
    #expect(!LLMRelayServer.isSafePublicURL(URL(string: "http://10.0.0.12")))
    #expect(!LLMRelayServer.isSafePublicURL(URL(string: "http://192.168.1.55")))
    #expect(!LLMRelayServer.isSafePublicURL(URL(string: "http://172.20.1.9")))
}

@Test
func testWebSafetyRejectsInvalidSchemes() {
    #expect(!LLMRelayServer.isSafePublicURL(URL(string: "file:///etc/passwd")))
    #expect(!LLMRelayServer.isSafePublicURL(URL(string: "ftp://example.com")))
}

@Test
func testParseGoogleNewsRSSExtractsItems() {
    let xml = """
    <rss><channel>
      <item>
        <title><![CDATA[Apple announces something]]></title>
        <link>https://example.com/apple-news</link>
        <pubDate>Sun, 01 Mar 2026 07:00:00 GMT</pubDate>
        <source url="https://example.com">Example</source>
      </item>
      <item>
        <title><![CDATA[Another Apple update]]></title>
        <link>https://example.org/apple-update</link>
      </item>
    </channel></rss>
    """

    let results = LLMRelayServer.parseGoogleNewsRSS(xml: xml, limit: 2)
    #expect(results.count == 2)
    #expect(results[0]["title"] == "Apple announces something")
    #expect(results[0]["url"] == "https://example.com/apple-news")
    #expect(results[0]["published_at"] == "Sun, 01 Mar 2026 07:00:00 GMT")
    #expect(results[0]["source"] == "Example")
}

@Test
func testIsNewsLikeQueryMatchesNewsSignals() {
    #expect(LLMRelayServer.isNewsLikeQuery("latest Apple news and announcements"))
    #expect(LLMRelayServer.isNewsLikeQuery("daily swift digest for today"))
    #expect(!LLMRelayServer.isNewsLikeQuery("list files in project root"))
}
