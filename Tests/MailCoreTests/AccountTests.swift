import Foundation
import Testing
@testable import MailCore

@Suite struct AccountRegistryTests {
    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "sift-acct-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func addsAccountsWithDistinctColorsAndFilesAndIgnoresDuplicates() {
        var registry = AccountRegistry()
        let a = registry.add(email: "A@Example.com", tokenKey: "k1", directory: "/data")
        let b = registry.add(email: "b@example.com", tokenKey: "k2", directory: "/data")
        #expect(a?.id == "a@example.com" && a?.dbPath == "/data/a@example.com.sqlite")
        #expect(a?.colorIndex != b?.colorIndex)
        #expect(registry.add(email: "a@example.com", tokenKey: "k3", directory: "/data") == nil)
        #expect(registry.accounts.count == 2)
        registry.remove(id: "A@example.com")
        #expect(registry.accounts.map(\.email) == ["b@example.com"])
        // 删掉之后空出来的颜色会被下一个账号用上
        #expect(registry.add(email: "c@example.com", tokenKey: "k4", directory: "/data")?.colorIndex == a?.colorIndex)
    }

    @Test func fileNamesAreSafe() {
        var registry = AccountRegistry()
        let account = registry.add(email: "we/ird:name@x.com", tokenKey: "k", directory: "/d")
        #expect(account?.dbPath == "/d/we_ird_name@x.com.sqlite")
    }

    @Test func roundTripsThroughDisk() throws {
        let path = tempDir() + "/accounts.json"
        var registry = AccountRegistry()
        registry.add(email: "a@x.com", tokenKey: "k", directory: "/d")
        try registry.write(to: path)
        let loaded = try #require(AccountRegistry.read(from: path))
        #expect(loaded.accounts.map(\.email) == ["a@x.com"] && loaded.accounts.first?.tokenKey == "k")
        #expect(AccountRegistry.read(from: path + ".missing") == nil)
    }

    @Test func upgradesTheSingleAccountInstallKeepingItsDatabase() throws {
        let dir = tempDir()
        let dbPath = dir + "/mail.sqlite"
        let store = try MailStore(path: dbPath)
        try store.setState(["email": "Me@x.com"])
        let registryPath = dir + "/accounts.json"

        let registry = AccountRegistry.load(path: registryPath, legacyDBPath: dbPath)
        let account = try #require(registry.accounts.first)
        #expect(account.email == "me@x.com" && account.dbPath == dbPath && account.tokenKey == OAuthClient.defaultTokenKey)
        #expect(FileManager.default.fileExists(atPath: registryPath))
        // 第二次直接读清单
        #expect(AccountRegistry.load(path: registryPath, legacyDBPath: dir + "/other.sqlite").accounts.count == 1)
    }

    @Test func freshInstallHasNoAccounts() {
        let dir = tempDir()
        #expect(AccountRegistry.load(path: dir + "/accounts.json", legacyDBPath: dir + "/mail.sqlite").accounts.isEmpty)
    }

    @Test func tokenKeysPerEmail() {
        #expect(OAuthClient.tokenKey(forEmail: "A@x.com") == "gmail-oauth-token:a@x.com")
    }

    @Test func tokenScopeDecidesCalendarAccess() {
        let old = StoredToken(accessToken: "a", refreshToken: "r", expiry: Date(), scope: "https://www.googleapis.com/auth/gmail.modify")
        let new = StoredToken(accessToken: "a", refreshToken: "r", expiry: Date(), scope: "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.readonly")
        #expect(old.canModify && !old.canReadCalendar)
        #expect(new.canModify && new.canReadCalendar)
    }
}
