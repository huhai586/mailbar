import SwiftUI

/// 同步按钮的图标：同步时匀速旋转，不同步时静止。
/// 用时间驱动旋转而不是 repeatForever 动画——后者在状态变回去之后偶尔停不下来，图标会一直抖。
struct SyncIcon: View {
    let syncing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 系统设置里开了「减弱动态效果」时不旋转，同步中改用强调色（调用处）和状态栏文字表示
        if syncing, !reduceMotion {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                Image(systemName: "arrow.clockwise").rotationEffect(.degrees(phase * 360))
            }
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
}
