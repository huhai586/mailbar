import Foundation

/// 所有 Gmail 请求共用的限速器：平时按固定速率发请求；一旦触发 Google 限流，
/// 全局暂停一段时间并把速率减半，之后随成功请求慢慢恢复（AIMD）。
actor RequestPacer {
    static let maxRate = 10.0   // 请求/秒
    static let minRate = 1.0

    private(set) var rate: Double
    private let blockSeconds: TimeInterval
    private let onThrottle: @Sendable (String) -> Void
    private var nextSlot = Date.distantPast
    private var blockedUntil = Date.distantPast
    private var successStreak = 0

    init(rate: Double = RequestPacer.maxRate, blockSeconds: TimeInterval = 30,
         onThrottle: @escaping @Sendable (String) -> Void = { message in
             FileHandle.standardError.write(Data((message + "\n").utf8))
         }) {
        self.rate = rate
        self.blockSeconds = blockSeconds
        self.onThrottle = onThrottle
    }

    /// 排队等待发送名额。名额在挂起前就占好，所以并发调用也会被均匀错开。
    func waitTurn() async {
        let now = Date()
        let start = max(now, nextSlot, blockedUntil)
        nextSlot = start.addingTimeInterval(1 / rate)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    func reportSuccess() {
        successStreak += 1
        if successStreak >= 50 {
            successStreak = 0
            rate = min(Self.maxRate, rate + 1)
        }
    }

    /// 同一次限流会让多个在途请求同时失败，只对第一个生效。
    func reportRateLimited() {
        let now = Date()
        guard now >= blockedUntil else { return }
        successStreak = 0
        rate = max(Self.minRate, rate / 2)
        blockedUntil = now.addingTimeInterval(blockSeconds)
        onThrottle("Google 限流：暂停 \(Int(blockSeconds)) 秒，请求速率降至 \(String(format: "%.1f", rate))/秒")
    }
}
