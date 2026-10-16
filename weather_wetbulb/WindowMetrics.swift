//
//  WindowMetrics.swift
//  weather_wetbulb
//
//  The size of the window itself, which is not something SwiftUI will tell
//  you. A background layer reports the width left after the safe area is taken
//  out, and `ignoresSafeArea()` on it does not change that — so on a foldable,
//  where the status corner is carved out of one side, halving what SwiftUI
//  reports puts the middle several points away from the actual fold.
//
//  Apple's own foldable advice is to read `window.bounds` rather than
//  `UIScreen.main.bounds`, which is what this does.

import SwiftUI
import UIKit

/// What the window can tell us that SwiftUI will not: its true size, the
/// insets the system reserves, and where the clock and wifi corner actually
/// sits. The last one has no SwiftUI equivalent at all — a safe-area inset
/// says how much room is reserved, never which corner of it is occupied.
struct WindowMetrics: Equatable {
    var size: CGSize = .zero
    var safeInsets: UIEdgeInsets = .zero
    /// The system status area (clock, wifi), in window coordinates.
    var statusFrame: CGRect = .zero

    /// Width the system keeps for the status corner on the trailing side.
    var trailingReserve: CGFloat { max(safeInsets.right, 0) }
    /// Whether the status corner hugs the top-trailing corner, which is where
    /// it sits on this device in every pose seen so far.
    var statusAtTopTrailing: Bool {
        statusFrame.width > 0 && statusFrame.maxX >= size.width - 1
    }
}

struct WindowMetricsReader: UIViewRepresentable {
    var onChange: (WindowMetrics) -> Void

    final class ReportingView: UIView {
        var onChange: ((WindowMetrics) -> Void)?
        private var last = WindowMetrics()

        private func report() {
            guard let window else { return }
            var next = WindowMetrics()
            next.size = window.bounds.size
            next.safeInsets = window.safeAreaInsets
            next.statusFrame = window.windowScene?.statusBarManager?.statusBarFrame ?? .zero
            guard next != last else { return }
            last = next
            onChange?(next)
        }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
    }

    func makeUIView(context: Context) -> ReportingView {
        let view = ReportingView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReportingView, context: Context) {
        uiView.onChange = onChange
    }
}
