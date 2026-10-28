import SwiftUI

/// 同步按钮的图标：同步时匀速旋转，不同步时静止。
/// 用时间驱动旋转而不是 repeatForever 动画——后者在状态变回去之后偶尔停不下来，图标会一直抖。
struct SyncIcon: View {
    let syncing: Bool

    var body: some View {
        if syncing {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                Image(systemName: "arrow.clockwise").rotationEffect(.degrees(phase * 360))
            }
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
}
