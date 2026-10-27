import Foundation
import Testing
@testable import MailCore

func b64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func part(_ mime: String, _ text: String? = nil, data: Data? = nil, charset: String? = nil,
          filename: String? = nil, attachmentId: String? = nil, parts: [GmailPart]? = nil) -> GmailPart {
    let raw = data ?? text.map { Data($0.utf8) }
    let headers = charset.map { [GmailHeader(name: "Content-Type", value: "\(mime); charset=\"\($0)\"")] }
    return GmailPart(partId: nil, mimeType: mime, filename: filename, headers: headers,
                     body: GmailBody(attachmentId: attachmentId, size: raw?.count, data: raw.map(b64url)), parts: parts)
}

@Suite struct HeaderDecoderTests {
    @Test func plainPassthrough() {
        #expect(HeaderDecoder.decode("Hello World") == "Hello World")
        #expect(HeaderDecoder.decode(nil) == "")
    }

    @Test func base64UTF8() {
        let word = "=?UTF-8?B?" + Data("你好，世界".utf8).base64EncodedString() + "?="
        #expect(HeaderDecoder.decode(word) == "你好，世界")
    }

    @Test func quotedPrintable() {
        #expect(HeaderDecoder.decode("=?UTF-8?Q?Caf=C3=A9_menu?=") == "Café menu")
    }

    @Test func adjacentWordsAreJoinedWithoutGap() {
        let a = "=?UTF-8?B?" + Data("你好".utf8).base64EncodedString() + "?="
        let b = "=?UTF-8?B?" + Data("世界".utf8).base64EncodedString() + "?="
        #expect(HeaderDecoder.decode("\(a) \(b)") == "你好世界")
    }

    @Test func mixedWithPlainText() {
        let word = "=?UTF-8?B?" + Data("发票".utf8).base64EncodedString() + "?="
        #expect(HeaderDecoder.decode("Re: \(word) <a@b.com>") == "Re: 发票 <a@b.com>")
    }

    @Test func gb2312Header() {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = "中文标题".data(using: String.Encoding(rawValue: gb))!
        #expect(HeaderDecoder.decode("=?gb2312?B?\(data.base64EncodedString())?=") == "中文标题")
    }
}

@Suite struct MimeParserTests {
    @Test func plainTextOnly() {
        let body = MimeParser.parse(part("text/plain", "hello"))
        #expect(body == ParsedBody(text: "hello", html: nil, hasAttachments: false))
    }

    @Test func alternativeKeepsBoth() {
        let root = part("multipart/alternative", parts: [part("text/plain", "plain"), part("text/html", "<p>html</p>")])
        let body = MimeParser.parse(root)
        #expect(body.text == "plain")
        #expect(body.html == "<p>html</p>")
    }

    @Test func htmlOnlyIsConvertedToText() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;&amp; welcome</p><div>第二行&#33;</div><script>x()</script></body></html>"
        let body = MimeParser.parse(part("text/html", html))
        #expect(body.text == "Hello & welcome\n第二行!")
    }

    @Test func attachmentDetected() {
        let root = part("multipart/mixed", parts: [
            part("text/plain", "see attached"),
            part("application/pdf", filename: "a.pdf", attachmentId: "att1"),
        ])
        let body = MimeParser.parse(root)
        #expect(body.hasAttachments)
        #expect(body.text == "see attached")
    }

    @Test func inlineImageWithoutFilenameCountsAsAttachment() {
        let root = part("multipart/related", parts: [part("text/html", "<img src=cid:x>"), part("image/png", attachmentId: "att2")])
        #expect(MimeParser.parse(root).hasAttachments)
    }

    @Test func gbkBody() {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = "服务器告警：磁盘已满".data(using: String.Encoding(rawValue: gb))!
        let body = MimeParser.parse(part("text/plain", data: data, charset: "gb2312"))
        #expect(body.text == "服务器告警：磁盘已满")
    }

    @Test func missingPayload() {
        #expect(MimeParser.parse(nil) == ParsedBody(text: "", html: nil, hasAttachments: false))
    }

    @Test func parsedMessageFromGmailMessage() {
        let subject = "=?UTF-8?B?" + Data("紧急：发票".utf8).base64EncodedString() + "?="
        var root = part("text/plain", "正文")
        root = GmailPart(partId: nil, mimeType: root.mimeType, filename: nil,
                         headers: [GmailHeader(name: "subject", value: subject), GmailHeader(name: "From", value: "A <a@b.com>")],
                         body: root.body, parts: nil)
        let msg = GmailMessage(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], snippet: "s", historyId: "10",
                               internalDate: "1700000000000", sizeEstimate: 99, payload: root)
        let parsed = ParsedMessage(msg)
        #expect(parsed.subject == "紧急：发票")
        #expect(parsed.from == "A <a@b.com>")
        #expect(parsed.isUnread)
        #expect(parsed.internalDate == 1_700_000_000_000)
        #expect(parsed.bodyText == "正文")
    }
}
