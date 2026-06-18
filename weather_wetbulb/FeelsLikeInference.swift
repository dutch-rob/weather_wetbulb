//
//  FeelsLikeInference.swift
//  MyFeelsLike
//
//  Inference half of the personalised "feels like" model: the feature
//  definitions, the feature-source protocol, the inference scenario, the
//  forecast-point feature source, and the persistable RegressionState with
//  predict / leverage / opacity. Pure value types with no SwiftData or UI
//  dependency, so this compiles on the watch app and widget too.
//
//  Training (fit / OLS / Rating conformance / UserDefaults persistence) lives
//  in FeelsLikeRegression.swift and stays iOS-only.
//

import Foundation

// MARK: - Feature definitions

/// Every regressor the model knows about.  Order matters only for stable
/// serialization; selection is by name.
enum Feature: String, CaseIterable, Codable {
    /// The anchor — always included.
    case apparentTempC

    // Collinearity-reduced temperature relatives.
    case apparentMinusTemp        // apparent − temperature   (wind/RH correction)
    case tempMinusWetBulb         // wet-bulb depression
    case wetBulbMinusDewPoint     // humidity gap

    // Other weather variables.
    case humidity
    case stationPressurePa
    case windSpeedKPH
    case precipProbability
    case precipitationMM
    case cloudCover
    case cloudCoverLow
    case cloudCoverMedium
    case cloudCoverHigh
    case uvIndex
    case isDaylight               // 0 / 1

    // Self-report (ordinal).
    case activity                 // 0…3
    case dress                    // -2…+2
    case sun                      // -1…+1

    // Piecewise-linear hinge terms (candidates from n ≥ 25).
    // Each is max(0, x − h) or max(0, h − x), giving a slope change at h.
    case hinge_cold_10     // max(0, 10 − apparentTempC)  — cold amplification below 10 °C
    case hinge_warm_18     // max(0, apparentTempC − 18)  — warm onset above 18 °C
    case hinge_hot_26      // max(0, apparentTempC − 26)  — heat amplification above 26 °C
    case hinge_wind_15     // max(0, windSpeedKPH − 15)   — noticeable wind threshold
    case hinge_uv_4        // max(0, uvIndex − 4)         — moderate UV threshold

    // Interaction terms (candidates from n ≥ 40).
    case ix_apparent_humidity   // apparentTempC × humidity
    case ix_apparent_uv         // apparentTempC × uvIndex
    case ix_apparent_activity   // apparentTempC × activity

    /// Minimum number of ratings before this feature becomes a stepwise candidate.
    var minimumN: Int {
        switch self {
        case .hinge_cold_10, .hinge_warm_18, .hinge_hot_26,
             .hinge_wind_15, .hinge_uv_4:
            return 25
        case .ix_apparent_humidity, .ix_apparent_uv, .ix_apparent_activity:
            return 40
        default:
            return 0
        }
    }

    /// All features eligible as stepwise candidates for a given sample size.
    /// Excludes the anchor (apparentTempC) and any feature whose minimumN > n.
    static func candidates(for n: Int) -> [Feature] {
        allCases.filter { $0 != .apparentTempC && n >= $0.minimumN }
    }
}

// MARK: - Feature extraction

protocol FeatureSource {
    func value(for f: Feature) -> Double
}

/// A "scenario" is the user's expected current state used at inference time
/// for self-report features that the forecast can't know.
struct Scenario {
    var activity: Int = 1
    var dress: Int = 0
    var sun: Int = 0
}

/// Forecast point + scenario combination acts as a feature source.
struct ForecastFeatureSource: FeatureSource {
    let p: ForecastPoint
    let scenario: Scenario

    func value(for f: Feature) -> Double {
        switch f {
        case .apparentTempC:        return p.apparentTemperatureC
        case .apparentMinusTemp:    return p.apparentTemperatureC - p.temperatureC
        case .tempMinusWetBulb:     return p.temperatureC - p.wetBulbC
        case .wetBulbMinusDewPoint: return p.wetBulbC - p.dewPointC
        case .humidity:             return p.humidity
        case .stationPressurePa:    return p.stationPressurePa
        case .windSpeedKPH:         return p.windSpeedKPH
        case .precipProbability:    return p.precipProbability
        case .precipitationMM:      return p.precipitationMM
        case .cloudCover:           return p.cloudCover
        case .cloudCoverLow:        return p.cloudCoverLow
        case .cloudCoverMedium:     return p.cloudCoverMedium
        case .cloudCoverHigh:       return p.cloudCoverHigh
        case .uvIndex:              return p.uvIndex
        case .isDaylight:           return p.isDaylight ? 1 : 0
        case .activity:             return Double(scenario.activity)
        case .dress:                return Double(scenario.dress)
        case .sun:                  return Double(scenario.sun)
        // Hinges
        case .hinge_cold_10:        return max(0, 10 - p.apparentTemperatureC)
        case .hinge_warm_18:        return max(0, p.apparentTemperatureC - 18)
        case .hinge_hot_26:         return max(0, p.apparentTemperatureC - 26)
        case .hinge_wind_15:        return max(0, p.windSpeedKPH - 15)
        case .hinge_uv_4:           return max(0, p.uvIndex - 4)
        // Interactions
        case .ix_apparent_humidity: return p.apparentTemperatureC * p.humidity
        case .ix_apparent_uv:       return p.apparentTemperatureC * p.uvIndex
        case .ix_apparent_activity: return p.apparentTemperatureC * Double(scenario.activity)
        }
    }
}

// MARK: - Persistable regression state

struct RegressionState: Codable {
    var selectedFeatures: [Feature]   // includes apparentTempC at index 0
    var coefficients: [Double]        // β0 (intercept) + one per selectedFeatures
    var means: [Double]               // means[i] for selectedFeatures[i]
    var stds: [Double]                // stds[i] for selectedFeatures[i] (≥ epsilon)
    var rSquared: Double
    var aicc: Double
    var ratingCount: Int
    var lastFitAt: Date

    /// Inverse of the standardised normal-equations matrix (X'X)⁻¹ —
    /// the m × m matrix where m = selectedFeatures.count + 1 (intercept).
    /// Used to compute leverage / extrapolation diagnostics.
    /// Optional only so we can decode pre-leverage saved states;
    /// new fits always populate it.
    var invXtX: [[Double]]? = nil

    /// Predicted feels-like score (0…1000) for a feature source. May return
    /// values slightly outside [0, 1000]; callers clamp where needed.
    func predict(_ src: FeatureSource) -> Double {
        var y = coefficients[0]
        for (i, f) in selectedFeatures.enumerated() {
            let xStd = (src.value(for: f) - means[i]) / stds[i]
            y += coefficients[i + 1] * xStd
        }
        return y
    }

    /// Standardised augmented row [1, x₁_std, …, xₚ_std] for a query point.
    private func augmentedStdRow(_ src: FeatureSource) -> [Double] {
        let m = selectedFeatures.count + 1
        var x = [Double](repeating: 0, count: m)
        x[0] = 1.0
        for (j, f) in selectedFeatures.enumerated() {
            x[j + 1] = (src.value(for: f) - means[j]) / stds[j]
        }
        return x
    }

    /// Leverage (hat-matrix diagonal) for a query point.  Returns the
    /// scalar h = x' (X'X)⁻¹ x, where x is the standardised + intercept
    /// row for the query.
    ///
    ///   • At the centroid of training data h = 1/n (the floor).
    ///   • Average leverage over training points is m/n.
    ///   • Large h means the query lies far from training in a way that
    ///     respects the feature correlation structure (Mahalanobis-like).
    ///
    /// Returns nil if invXtX wasn't stored (legacy state); callers should
    /// then assume the model is in-range.
    func leverage(_ src: FeatureSource) -> Double? {
        guard let inv = invXtX else { return nil }
        let x = augmentedStdRow(src)
        let m = x.count
        var h = 0.0
        for i in 0..<m {
            var s = 0.0
            for j in 0..<m { s += inv[i][j] * x[j] }
            h += x[i] * s
        }
        return h
    }

    /// Opacity of the model prediction for `src`, based on leverage:
    ///   • h ≤ 2m/n → 1.0 (fully visible model)
    ///   • h ≥ 3m/n → 0.0 (invisible — model would be extrapolating)
    ///   • In between → linear fade.
    /// Used by the UI to fade the personalised colour overlay where the
    /// forecast is outside the training distribution.
    func predictionOpacity(_ src: FeatureSource) -> Double {
        guard let h = leverage(src) else { return 1.0 }
        let mD = Double(selectedFeatures.count + 1)
        let nD = Double(ratingCount)
        guard nD > 0 else { return 1.0 }
        let lower = 2.0 * mD / nD
        let upper = 3.0 * mD / nD
        if h <= lower { return 1.0 }
        if h >= upper { return 0.0 }
        return 1.0 - (h - lower) / (upper - lower)
    }
}
