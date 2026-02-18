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
}
