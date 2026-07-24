//
//  GraphOptions.swift
//  weather_wetbulb
//
//  User-toggleable graph options (Settings): which series to show, and the
//  color saturation (vivid vs muted). Series colors are looked up by base hue
//  so each chart style keeps its own role→color mapping (filled: temp green;
//  classic: temp blue) while the palette only changes saturation.
//

import SwiftUI

/// @AppStorage keys for which series to draw. All default to true.
enum GraphKey {
    static let temp     = "graphTemp"
    static let wetBulb  = "graphWetBulb"
    static let dewPoint = "graphDewPoint"
    static let feels    = "graphFeels"
    static let precip   = "graphPrecip"
    static let wind     = "graphWind"
    static let gust     = "graphGust"
    static let sky      = "graphSky"
}

/// Saturation of the weather series colors.
enum GraphPalette: String, CaseIterable, Identifiable {
    case vivid
    case muted

    var id: String { rawValue }
    var label: String { self == .vivid ? "Vivid" : "Muted" }

    var green:  Color { self == .muted ? Color(red: 0.44, green: 0.62, blue: 0.44) : .green }
    var blue:   Color { self == .muted ? Color(red: 0.40, green: 0.56, blue: 0.72) : .blue }
    var red:    Color { self == .muted ? Color(red: 0.78, green: 0.44, blue: 0.44) : .red }
    var purple: Color { self == .muted ? Color(red: 0.60, green: 0.48, blue: 0.72) : .purple }
}
