import Foundation
import Testing
@testable import KnotchyCore

struct LinkIntakeTests {
    private func extract(_ text: String) -> String? {
        LinkIntake.extractURL(from: text)?.absoluteString
    }

    @Test func findsAURLInsideProse() {
        #expect(extract("Your parcel is waiting at https://example.com/track?id=42 today") == "https://example.com/track?id=42")
    }

    @Test func acceptsABareURL() {
        #expect(extract("http://example.com") == "http://example.com")
    }

    @Test func stripsTrailingPunctuation() {
        #expect(extract("Go to https://example.com/page.") == "https://example.com/page")
        #expect(extract("**https://example.com/page**") == "https://example.com/page")
        #expect(extract("https://example.com/search?q=*") == "https://example.com/search?q=*")
        #expect(extract("Really? https://example.com/page!?") == "https://example.com/page")
        #expect(extract("'https://example.com/a'") == "https://example.com/a")
        #expect(extract("\"https://example.com/a\",") == "https://example.com/a")
        #expect(extract("see https://example.com/a;") == "https://example.com/a")
    }

    @Test func keepsBalancedBracketsAndStripsUnbalancedOnes() {
        #expect(extract("https://en.wikipedia.org/wiki/Foo_(bar)") == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(extract("(see https://en.wikipedia.org/wiki/Foo_(bar)).") == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(extract("(see https://example.com/a)") == "https://example.com/a")
        #expect(extract("(https://example.com/a)and more") == "https://example.com/a")
        #expect(extract("(https://en.wikipedia.org/wiki/Foo_(bar))") == "https://en.wikipedia.org/wiki/Foo_(bar)")
        #expect(extract("[link](https://example.com/a)") == "https://example.com/a")
        #expect(extract("https://example.com/a]") == "https://example.com/a")
        #expect(extract("{https://example.com/a}") == "https://example.com/a")
    }

    @Test func handlesMarkdownLinks() {
        #expect(extract("[https://example.com/a](https://example.com/a)") == "https://example.com/a")
        #expect(extract("[https://example.com/a](https://example.org/b)") == "https://example.com/a")
        #expect(extract("[httpbin](https://httpbin.org)") == "https://httpbin.org")
        #expect(extract("See [XMLHttpRequest](https://developer.mozilla.org/docs/XMLHttpRequest).")
            == "https://developer.mozilla.org/docs/XMLHttpRequest")
        #expect(extract("**[Example](https://example.com)**") == "https://example.com")
        #expect(extract("*[Example](https://example.com/a)*") == "https://example.com/a")
        #expect(extract("Get it: **[httpbin](https://httpbin.org)**.") == "https://httpbin.org")
        #expect(extract("[x](https://example.com)and more") == "https://example.com")
        #expect(extract("[w](https://en.wikipedia.org/wiki/Foo_(bar))**") == "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    @Test func smartQuotesAndCJKPunctuationEndALink() {
        #expect(extract("\u{201C}https://example.com\u{201D}") == "https://example.com")
        #expect(extract("\u{201C}https://example.com/page\u{201D}") == "https://example.com/page")
        #expect(extract("\u{00AB}https://example.com/page\u{00BB}") == "https://example.com/page")
        #expect(extract("请访问https://example.com。谢谢") == "https://example.com")
        #expect(extract("请访问https://example.com．谢谢") == "https://example.com")
        #expect(extract("https://example.com｡テスト") == "https://example.com")
        #expect(extract("见（https://example.com/a）") == "https://example.com/a")
        #expect(extract("「https://example.com/a」") == "https://example.com/a")
    }

    @Test func unwrapsAngleBrackets() {
        #expect(extract("Open <https://example.com/a> now") == "https://example.com/a")
    }

    @Test func usesTheFirstWebURL() {
        #expect(extract("ftp://files.example.com then https://b.example.com and https://c.example.com") == "https://b.example.com")
    }

    @Test func textWithoutAWebLinkHasNoLink() {
        #expect(extract("javascript:alert(1)") == nil)
        #expect(extract("file:///etc/passwd") == nil)
        #expect(extract("mailto:someone@example.com") == nil)
        #expect(extract("ftp://files.example.com") == nil)
        #expect(extract("httpx://example.com") == nil)
    }

    @Test func rejectsEmptyAndHostlessInput() {
        #expect(extract("") == nil)
        #expect(extract("   \n") == nil)
        #expect(extract("no links here, just httpbin and https://") == nil)
    }

    @Test func acceptsUppercaseSchemes() {
        #expect(extract("HTTPS://EXAMPLE.COM/") == "HTTPS://EXAMPLE.COM/")
    }

    @Test func acceptsLinksUpToTheLengthLimit() {
        let base = "https://example.com/"
        let longest = base + String(repeating: "a", count: LinkIntake.maxURLBytes - base.utf8.count)
        #expect(extract(longest) == longest)
        #expect(extract("Go to " + longest + ".") == longest)   // Measured after trimming.
        #expect(extract(longest + "a") == nil)
        // Measured as encoded: each `{` becomes `%7B`.
        #expect(extract(base + String(repeating: "{", count: 6000)) == nil)
    }

    @Test func skipsAnOverlongTokenWholeIncludingLinksNestedInIt() {
        let overlong = "https://example.com/" + String(repeating: "a", count: LinkIntake.maxURLBytes)
        #expect(extract(overlong + "https://nested.example.com/") == nil)
        #expect(extract(overlong + " https://next.example.com/") == "https://next.example.com/")
    }

    @Test(arguments: [
        String(repeating: "http", count: 256 * 1024),
        String(repeating: "http ", count: 100_000),
        String(repeating: "http" + String(repeating: ")", count: 16_000) + " ", count: 16),
        String(repeating: "http](", count: 200_000),
    ])
    func hostileTextIsScannedInLinearTime(_ hostile: String) {
        // Quadratic versions took 10 s to minutes on these; linear takes well under a second.
        let start = ContinuousClock.now
        #expect(extract(hostile) == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func onlyLinksStartingNearTheStartOfHugeTextCount() {
        let filler = String(repeating: "x", count: LinkIntake.maxScannedCharacters)
        #expect(extract(filler + " https://example.com/") == nil)
        #expect(extract("https://example.com/ " + filler) == "https://example.com/")
    }

    @Test func aLinkThatStartsBeforeTheScanLimitIsReadWhole() {
        let link = "https://example.com/very/long/path?token=abcdef"
        let filler = String(repeating: "x", count: LinkIntake.maxScannedCharacters - 30)
        #expect(extract(filler + " " + link) == link)
    }

    @Test func findsTheLinkBehindSelectedHyperlinkText() {
        func extract(html: String) -> String? { LinkIntake.extractURL(fromHTML: html)?.absoluteString }
        #expect(extract(html: #"<a href="https://www.theverge.com/transportation/909060/amflows-latest-e-bikes">Amflow's latest e-bikes</a>"#)
            == "https://www.theverge.com/transportation/909060/amflows-latest-e-bikes")
        #expect(extract(html: #"<a href='https://www.google.com/url?q=https://example.com/&amp;sa=D'>Verify</a>"#)
            == "https://www.google.com/url?q=https://example.com/&sa=D")
        #expect(extract(html: "<A HREF=https://example.com/a>x</A>") == "https://example.com/a")
        #expect(extract(html: #"<a href="mailto:a@example.com">mail</a> <a href="https://example.org/">web</a>"#) == "https://example.org/")
        #expect(extract(html: "<p>see https://example.com/page.</p>") == "https://example.com/page")
        #expect(extract(html: "<p>no links</p>") == nil)
    }

    @Test func validatesURLObjects() throws {
        let web = try #require(URL(string: "https://example.com/x"))
        #expect(LinkIntake.validate(web) == web)
        #expect(LinkIntake.validate(try #require(URL(string: "HTTP://example.com/"))) != nil)
        #expect(LinkIntake.validate(URL(filePath: "/etc/passwd")) == nil)
        #expect(LinkIntake.validate(try #require(URL(string: "ftp://files.example.com/"))) == nil)
        #expect(LinkIntake.validate(try #require(URL(string: "mailto:a@example.com"))) == nil)
        #expect(LinkIntake.validate(try #require(URL(string: "https:///no-host"))) == nil)
        #expect(LinkIntake.validate(try #require(URL(string: "http://:80/"))) == nil)
        let long = "https://example.com/" + String(repeating: "a", count: LinkIntake.maxURLBytes)
        #expect(LinkIntake.validate(try #require(URL(string: long))) == nil)
    }
}
