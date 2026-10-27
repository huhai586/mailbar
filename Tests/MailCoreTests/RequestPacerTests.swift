import Foundation
import Testing
@testable import MailCore

@Suite struct RequestPacerTests {
    @Test func rateLimitHalvesRateWithFloorAndSuccessRecovers() async {
        let pacer = RequestPacer(rate: 8, blockSeconds: 0, onThrottle: { _ in })
        await pacer.reportRateLimited()
        #expect(await pacer.rate == 4)
        await pacer.reportRateLimited()
        #expect(await pacer.rate == 2)
        await pacer.reportRateLimited()
        await pacer.reportRateLimited()
        #expect(await pacer.rate == RequestPacer.minRate)

        for _ in 0..<50 { await pacer.reportSuccess() }
        #expect(await pacer.rate == RequestPacer.minRate + 1)
    }

    @Test func simultaneousFailuresOnlyCountOnce() async {
        let pacer = RequestPacer(rate: 8, blockSeconds: 5, onThrottle: { _ in })
        await pacer.reportRateLimited()
        await pacer.reportRateLimited()   // 同一次限流里的第二个失败
        await pacer.reportRateLimited()
        #expect(await pacer.rate == 4)
    }

    @Test func turnsAreSpacedByRate() async {
        let pacer = RequestPacer(rate: 20, onThrottle: { _ in })   // 间隔 50ms
        let start = Date()
        for _ in 0..<5 { await pacer.waitTurn() }
        #expect(Date().timeIntervalSince(start) >= 0.18)
    }

    @Test func waitsOutTheBlockWindow() async {
        let pacer = RequestPacer(rate: 100, blockSeconds: 0.3, onThrottle: { _ in })
        await pacer.reportRateLimited()
        let start = Date()
        await pacer.waitTurn()
        #expect(Date().timeIntervalSince(start) >= 0.25)
    }
}
