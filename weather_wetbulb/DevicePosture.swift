//
//  DevicePosture.swift
//  weather_wetbulb
//
//  How the device is being held: how far it is folded, and how flat it lies.
//
//  Neither question has an API of its own. iOS 27.1's UIHinge says how far open
//  the device is but never which way up it is, and CoreMotion says which way is
//  down but knows nothing about hinges. A device propped open on a table is the
//  two readings together: partly folded, and its lower half close to flat.
//
//  Gravity is deliberately left referenced to the hardware frame — the half
//  carrying the main camera — by not setting `deviceMotionBody`. That is the
//  half that rests on the table, which is the one being asked about. Setting a
//  body would re-reference the vector to whichever display the app occupies,
//  which is the opposite of what this needs.

import SwiftUI
import Combine
import CoreMotion
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class DevicePosture: ObservableObject {

    /// Hinge angle exactly as reported, before any interpretation.
    @Published private(set) var hingeAngleRaw: Double?
    /// Hinge status, as a short string for the debug readout.
    @Published private(set) var hingeStatus: String = "—"
    /// The hinge is somewhere between shut and flat open.
    @Published private(set) var isPartlyOpen: Bool = false
    /// How far the reference half is from lying face-up and flat, in degrees:
    /// 0 is flat on a table, 90 is upright, 180 is face-down.
    @Published private(set) var tiltFromFlat: Double?

    /// Within this many degrees of flat counts as resting on a surface.
    static let flatWithin: Double = 25
    /// This far back from fully open counts as deliberately folded. 35 degrees
    /// puts the line at 145 degrees of fold (2.53 rad): far enough that a
    /// device still being held open flat is not mistaken for one propped on a
    /// table, near enough that a genuine prop is caught.
    static let foldWithin: Double = 35

    private let motion = CMMotionManager()

    /// Fold angle in degrees, 180 being flat open.
    ///
    /// `UIHinge.angle` is in **radians** — the header documents no unit, but
    /// the simulator reports 0 closed, 2.225 at its "almost fully open" stop
    /// (127 degrees) and 3.142 fully open. The conversion is kept defensive
    /// anyway: anything small enough to be π is treated as radians, so a device
    /// that reported degrees would still read correctly.
    var foldDegrees: Double? {
        guard let raw = hingeAngleRaw else { return nil }
        return raw <= 3.3 ? raw * 180 / .pi : raw
    }

    /// The device looks propped open on a surface, the lower half lying flat
    /// and the upper half angled up to be read.
    var isTabletop: Bool {
        // A shut device reads 0 degrees, which is "far from flat open" by any
        // angle test — so the angle alone called a closed phone a tabletop. The
        // hinge has to actually be part way open.
        guard isPartlyOpen, let fold = foldDegrees else { return false }
        // No motion data at all means the simulator, which synthesises none.
        // Taking that as "lying flat" is what makes this pose reachable in
        // testing; on a device the gravity term is what stops a phone held
        // half-open in the air from being mistaken for one on a table.
        let lyingFlat = tiltFromFlat.map { $0 < Self.flatWithin } ?? true
        return lyingFlat && fold < 180 - Self.foldWithin
    }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.2      // posture, not animation
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            // Face-up and flat puts gravity straight through the back of the
            // device, so the angle away from that is the angle away from flat.
            let cosine = max(-1, min(1, -g.z))
            MainActor.assumeIsolated { self.tiltFromFlat = acos(cosine) * 180 / .pi }
        }
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    func apply(angle: Double?, status: String, partlyOpen: Bool) {
        hingeAngleRaw = angle
        hingeStatus = status
        isPartlyOpen = partlyOpen
    }
}

/// Hosts the UIKit hinge interaction, which has no SwiftUI equivalent.
struct HingeReader: UIViewRepresentable {
    var onUpdate: (Double?, String, Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { _, update in
                guard let hinge = update.hinge else {
                    onUpdate(nil, "no hinge", false)
                    return
                }
                let name: String
                switch hinge.status {
                case .closed:        name = "closed"
                case .partiallyOpen: name = "partly open"
                case .fullyOpen:     name = "fully open"
                default:             name = "unknown"
                }
                onUpdate(Double(hinge.angle), name, hinge.status == .partiallyOpen)
            }
            view.addInteraction(interaction)
        } else {
            onUpdate(nil, "needs iOS 27.1", false)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
