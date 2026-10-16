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

    /// How far down a side strip the clock and wifi reach. Measured off the
    /// folded screen rather than asked for, because nothing publishes it: the
    /// system says how wide the strip is and never what is in it. The wifi
    /// badge ends about 152 pt down a 678 pt panel; this leaves a margin.
    static let sideStripStatusDepth: CGFloat = 170

    /// Where the clock and wifi actually sit, in window coordinates.
    ///
    /// `statusBarFrame` is the right answer when the system gives one — opened
    /// out, it reports the corner it occupies and nothing more. Folded shut it
    /// reports a band the full width of the window and two points tall, which
    /// describes nothing: on that screen the clock is not along the top at all,
    /// it is down the strip the safe area reserves at one side. So a frame
    /// that spans the whole width is treated as no answer, and the reserved
    /// strip is taken as the corner instead.
    var statusCorner: CGRect {
        if statusFrame.height >= 20, statusFrame.width < size.width - 1 {
            return statusFrame
        }
        if safeInsets.right > 0 {
            return CGRect(x: size.width - safeInsets.right, y: 0,
                          width: safeInsets.right, height: Self.sideStripStatusDepth)
        }
        if safeInsets.left > 0 {
            return CGRect(x: 0, y: 0, width: safeInsets.left,
                          height: Self.sideStripStatusDepth)
        }
        return .zero
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
