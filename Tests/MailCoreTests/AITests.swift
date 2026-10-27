import Foundation
import Testing
@testable import MailCore

private func response(_ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private final class Captured: @unchecked Sendable { var request: URLRequest? }

@Suite struct AIClientTests {
    @Test func openAIRequestShapeAndParsing() async throws {
        let captured = Captured()
        let provider = AIProvider(name: "o", kind: .openai, baseURL: "http://localhost:11434/v1/", model: "gemma4:e2b")
        let client = AIClient(provider: provider, apiKey: "sk-1") { request in
            captured.request = request
            return (Data(#"{"choices":[{"message":{"content":"hi"}}]}"#.utf8), response())
        }
        #expect(try await client.complete(system: "S", user: "U") == "hi")
        let request = try #require(captured.request)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "gemma4:e2b")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
    }

    @Test func openAIWithoutKeyOmitsAuthorization() async throws {
        let captured = Captured()
        let client = AIClient(provider: AIProvider(name: "o", kind: .openai, baseURL: "http://localhost:1234/v1", model: "m"), apiKey: "") { request in
            captured.request = request
            return (Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8), response())
        }
        _ = try await client.complete(system: "S", user: "U")
        #expect(captured.request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func anthropicRequestShapeAndParsing() async throws {
        let captured = Captured()
        let provider = AIProvider(name: "a", kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-haiku-5-5")
        let client = AIClient(provider: provider, apiKey: "k") { request in
            captured.request = request
            return (Data(#"{"content":[{"type":"text","text":"he"},{"type":"text","text":"llo"}]}"#.utf8), response())
        }
        #expect(try await client.complete(system: "S", user: "U") == "hello")
        let request = try #require(captured.request)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["system"] as? String == "S")
    }

    @Test func httpErrorsCarryStatusAndBody() async {
        let client = AIClient(provider: AIProvider(name: "o", kind: .openai, baseURL: "https://x/v1", model: "m"), apiKey: "") { _ in
            (Data("bad key".utf8), response(401))
        }
        await #expect(throws: MailError.self) { try await client.complete(system: "", user: "") }
    }

    @Test func emptyAddressOrModelIsRejectedBeforeSending() async {
        let noURL = AIClient(provider: AIProvider(name: "o", kind: .openai, baseURL: " ", model: "m"), apiKey: "") { _ in
            Issue.record("不应该发请求"); return (Data(), response())
        }
        await #expect(throws: MailError.self) { try await noURL.complete(system: "", user: "") }
    }
}

@Suite struct AIJudgeParsingTests {
    @Test func parsesPlainFencedAndChattyReplies() {
        #expect(AINotifyJudge.parse(#"{"notify": true, "reason": "有人@你"}"#) == AIVerdict(notify: true, reason: "有人@你"))
        #expect(AINotifyJudge.parse("```json\n{\"notify\": false, \"reason\": \"例行\"}\n```") == AIVerdict(notify: false, reason: "例行"))
        #expect(AINotifyJudge.parse("好的：{\"notify\":\"true\"} 以上") == AIVerdict(notify: true, reason: ""))
    }

    @Test func rejectsGarbage() {
        #expect(AINotifyJudge.parse("应该通知") == nil)
        #expect(AINotifyJudge.parse(#"{"reason": "x"}"#) == nil)
        #expect(AINotifyJudge.parse(#"{"notify": 3}"#) == nil)
    }

    @Test func promptCarriesUserPromptContractAndTruncatedBody() async throws {
        final class Seen: @unchecked Sendable { var system = ""; var user = "" }
        struct Spy: AIChat {
            let seen: Seen
            func complete(system: String, user: String) async throws -> String {
                seen.system = system; seen.user = user
                return #"{"notify": false}"#
            }
        }
        let seen = Seen()
        let judge = AINotifyJudge(chat: Spy(seen: seen), prompt: "MY RULES", maxBodyCharacters: 10)
        let verdict = try await judge.judge(subject: "S", from: "f", source: "github", kind: "human", body: String(repeating: "x", count: 100))
        #expect(!verdict.notify)
        #expect(seen.system.hasPrefix("MY RULES"))
        #expect(seen.system.contains("JSON"))
        #expect(seen.user.contains("主题：S"))
        #expect(!seen.user.contains(String(repeating: "x", count: 11)))
    }
}

@Suite struct AIConfigStoreTests {
    @Test func roundTripAndDefaults() throws {
        let path = NSTemporaryDirectory() + "ai-\(UUID().uuidString)/ai.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        #expect(AIConfigStore.read(path: path) == AIConfig())
        var config = AIConfig()
        let provider = AIProvider.presets[0]
        config.providers = [provider]
        config.activeProviderID = provider.id
        config.notifyEnabled = true
        config.notifyPrompt = "自定义"
        try AIConfigStore.write(config, to: path)
        #expect(AIConfigStore.read(path: path) == config)
        #expect(AIConfigStore.read(path: path).active == provider)
    }

    @Test func olderFilesWithoutNewFieldsKeepTheirProviders() throws {
        let path = NSTemporaryDirectory() + "ai-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = #"{"providers":[{"id":"1","name":"DeepSeek","kind":"openai","baseURL":"https://x/v1","model":"m"}],"activeProviderID":"1","notifyEnabled":true}"#
        try Data(old.utf8).write(to: URL(fileURLWithPath: path))
        let config = AIConfigStore.read(path: path)
        #expect(config.providers.count == 1 && config.notifyEnabled && !config.autoSummarize)
        #expect(config.notifyPrompt == AINotifyJudge.defaultPrompt)
    }

    @Test func corruptFileFallsBackToDefaults() throws {
        let path = NSTemporaryDirectory() + "ai-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("{oops".utf8).write(to: URL(fileURLWithPath: path))
        #expect(!AIConfigStore.read(path: path).notifyEnabled)
    }
}

@Suite struct AISampleTests {
    @Test func recentSamplesReadFromTheRealSchema() throws {
        let store = try MailStore(path: nil)
        #expect(try store.recentAISamples(limit: 5).isEmpty)
        try store.upsert([makeMessage("a", subject: "Hi", from: "bob@x.com", date: 1000, labels: ["INBOX"], thread: "T")])
        let sample = try #require(try store.recentAISamples(limit: 5).first)
        #expect(sample.subject == "Hi" && sample.from == "bob@x.com" && sample.id == "a")
    }
}
