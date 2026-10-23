import AppKit
import SwiftUI

/// Two panes with a draggable divider; `fraction` is the share of the first pane.
struct SplitPane<First: View, Second: View>: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    @Binding var fraction: CGFloat
    var minFirst: CGFloat = 140
    var minSecond: CGFloat = 140
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let size = clamp(total * fraction, total: total)
            if axis == .horizontal {
                HStack(spacing: 0) {
                    first().frame(width: size)
                    divider(total: total, current: size)
                    second().frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    first().frame(height: size)
                    divider(total: total, current: size)
                    second().frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func clamp(_ v: CGFloat, total: CGFloat) -> CGFloat {
        guard total > minFirst + minSecond else { return max(total / 2, 0) }
        return min(max(v, minFirst), total - minSecond)
    }

    private func divider(total: CGFloat, current: CGFloat) -> some View {
        let horizontal = axis == .horizontal
        return Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay(
                Color.clear
                    .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if dragStart == nil { dragStart = current }
                                let delta = horizontal ? v.translation.width : v.translation.height
                                let next = clamp((dragStart ?? current) + delta, total: total)
                                if total > 0 { fraction = next / total }
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            )
    }
}
