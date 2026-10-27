import Testing
@testable import MailCore

@Suite struct MailAddressTests {
    @Test func nameAndAddress() {
        #expect(MailAddress.parse("Alice <alice@x.com>") == MailAddress(name: "Alice", address: "alice@x.com"))
        #expect(MailAddress.parse("Alice <alice@x.com>").displayName == "Alice")
    }

    @Test func quotedNameWithComma() {
        let a = MailAddress.parse("\"Doe, John\" <j@x.com>")
        #expect(a.name == "Doe, John" && a.address == "j@x.com")
    }

    @Test func bareAddressAndAngleOnly() {
        #expect(MailAddress.parse("bob@x.com") == MailAddress(name: nil, address: "bob@x.com"))
        #expect(MailAddress.parse("bob@x.com").displayName == "bob@x.com")
        #expect(MailAddress.parse("<bob@x.com>") == MailAddress(name: nil, address: "bob@x.com"))
    }

    @Test func chineseName() {
        #expect(MailAddress.parse("张三 <z@x.com>").displayName == "张三")
    }

    @Test func listSplitsOnlyOutsideQuotesAndAngles() {
        let list = MailAddress.parseList("\"Doe, John\" <j@x.com>, bob@x.com,  Carol <c@x.com> ")
        #expect(list.map(\.displayName) == ["Doe, John", "bob@x.com", "Carol"])
        #expect(MailAddress.parseList("").isEmpty)
    }
}
