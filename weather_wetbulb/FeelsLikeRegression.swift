//
//  FeelsLikeRegression.swift
//  MyFeelsLike
//
//  Personalised "feels like" model. Trained on the user's own ratings, used
//  to predict the purple curve / table column from forecast points.
//
//  Algorithm overview
//  ──────────────────
//   1. Each rating contributes one feature vector (apparent-temp anchor +
//      a fixed candidate set including humidity/wind/uv/etc + collinearity-
//      reduced temperature differences + ordinal self-report fields).
//   2. Feature vectors are z-scored over the rating set (mean/std saved
//      so inference can apply the same transform).
//   3. Forward stepwise selection: model M0 = [apparent]. For each
//      additional slot, exhaustively try every remaining candidate, fit
//      OLS (Cholesky on the normal equations), score by AICc. Add the
//      winner if AICc improves by ≥ 2 over the best smaller model.
//   4. Slot budget: k = max(0, (n - 5) / 5). The first slot opens at n=10
//      ratings (so the very first regression is intercept + apparent only).
//   5. Inference: standardize a forecast point's features the same way,
//      multiply by stored coefficients, get °C "feels like" prediction.
//
//  None of this lives on the main thread anyway — refits run on user
//  actions, not in tight loops.
//

import Foundation

// Feature, FeatureSource, Scenario, ForecastFeatureSource and RegressionState
// now live in FeelsLikeInference.swift (shared with the watch app). This file
// keeps the iOS-only training engine and the Rating feature conformance.

// MARK: - Feature extraction (training side: Rating → features)

extension Rating: FeatureSource {
    func value(for f: Feature) -> Double {
        switch f {
        case .apparentTempC:        return apparentTemperatureC
        case .apparentMinusTemp:    return apparentTemperatureC - temperatureC
        case .tempMinusWetBulb:     return temperatureC - wetBulbC
        case .wetBulbMinusDewPoint: return wetBulbC - dewPointC
        case .humidity:             return humidity
        case .stationPressurePa:    return stationPressurePa
        case .windSpeedKPH:         return windSpeedKPH
        case .precipProbability:    return precipProbability
        case .precipitationMM:      return precipitationMM
        case .cloudCover:           return cloudCover
        case .cloudCoverLow:        return cloudCoverLow
        case .cloudCoverMedium:     return cloudCoverMedium
        case .cloudCoverHigh:       return cloudCoverHigh
        case .uvIndex:              return uvIndex
        case .isDaylight:           return isDaylight ? 1 : 0
        case .activity:             return Double(activity)
        case .dress:                return Double(dress)
        case .sun:                  return Double(sun)
        // Hinges
        case .hinge_cold_10:        return max(0, 10 - apparentTemperatureC)
        case .hinge_warm_18:        return max(0, apparentTemperatureC - 18)
        case .hinge_hot_26:         return max(0, apparentTemperatureC - 26)
        case .hinge_wind_15:        return max(0, windSpeedKPH - 15)
        case .hinge_uv_4:           return max(0, uvIndex - 4)
        // Interactions
        case .ix_apparent_humidity: return apparentTemperatureC * humidity
        case .ix_apparent_uv:       return apparentTemperatureC * uvIndex
        case .ix_apparent_activity: return apparentTemperatureC * Double(activity)
        }
    }
}

// MARK: - The fit engine

enum FeelsLikeRegression {

    /// Trigger threshold: at least 5 ratings AND ≥ 80-point spread (out of
    /// 1000) of user-reported feels-like scores. 80 points is roughly the
    /// score-scale equivalent of the previous 5 °C spread.
    static func canFit(ratings: [Rating]) -> Bool {
        guard ratings.count >= 5 else { return false }
        let ys = ratings.map { $0.feelsLikeScore }
        guard let lo = ys.min(), let hi = ys.max() else { return false }
        return (hi - lo) >= 80.0
    }

    /// How many extra (beyond apparent) features the budget allows.
    /// k=0 for n=5..9, k=1 for n=10..14, … capped to keep n/p ≥ 3.
    static func featureBudget(n: Int) -> Int {
        let raw = (n - 5) / 5
        let stabilityCap = max(0, (n - 2) / 3 - 1)   // -1 because anchor counts
        return max(0, min(raw, stabilityCap))
    }

    /// Refit the model from scratch.  Returns nil if the trigger condition
    /// isn't met yet.
    static func fit(ratings: [Rating]) -> RegressionState? {
        guard canFit(ratings: ratings) else { return nil }
        let n = ratings.count
        let budget = featureBudget(n: n)

        // Always start with the anchor.
        var selected: [Feature] = [.apparentTempC]
        guard var bestState = fitOLS(ratings: ratings, features: selected) else { return nil }

        // Forward stepwise: add up to `budget` more features.
        // Candidate pool is n-aware: hinges unlock at 25, interactions at 40.
        var remaining = Set(Feature.candidates(for: n))
        for _ in 0..<budget {
            var bestNext: (Feature, RegressionState)? = nil
            for f in remaining {
                let trial = selected + [f]
                guard let st = fitOLS(ratings: ratings, features: trial) else { continue }
                if bestNext == nil || st.aicc < bestNext!.1.aicc {
                    bestNext = (f, st)
                }
            }
            guard let pick = bestNext else { break }
            // Accept only if AICc improvement ≥ 2 (stop early otherwise).
            if pick.1.aicc + 2.0 < bestState.aicc {
                selected.append(pick.0)
                remaining.remove(pick.0)
                bestState = pick.1
            } else {
                break
            }
        }

        return bestState
    }

    /// Fit OLS for a specific feature set. Returns nil if X'X is singular.
    static func fitOLS(ratings: [Rating], features: [Feature]) -> RegressionState? {
        let n = ratings.count
        let p = features.count
        guard n > p + 1 else { return nil }

        // Build raw X (n × p) and y.
        var raw = Array(repeating: Array(repeating: 0.0, count: p), count: n)
        var y = Array(repeating: 0.0, count: n)
        for (i, r) in ratings.enumerated() {
            for (j, f) in features.enumerated() {
                raw[i][j] = r.value(for: f)
            }
            y[i] = r.feelsLikeScore
        }

        // Standardize columns.
        var means = Array(repeating: 0.0, count: p)
        var stds  = Array(repeating: 0.0, count: p)
        for j in 0..<p {
            let col = (0..<n).map { raw[$0][j] }
            let m = col.reduce(0, +) / Double(n)
            means[j] = m
            let v = col.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n - 1)
            stds[j] = max(sqrt(v), 1e-9)
        }
        var Xstd = Array(repeating: Array(repeating: 0.0, count: p + 1), count: n)
        for i in 0..<n {
            Xstd[i][0] = 1.0  // intercept
            for j in 0..<p {
                Xstd[i][j + 1] = (raw[i][j] - means[j]) / stds[j]
            }
        }

        // Normal equations: (XᵀX) β = Xᵀy.  Symmetric positive definite.
        let m = p + 1
        var XtX = Array(repeating: Array(repeating: 0.0, count: m), count: m)
        var Xty = Array(repeating: 0.0, count: m)
        for i in 0..<n {
            for a in 0..<m {
                Xty[a] += Xstd[i][a] * y[i]
                for b in a..<m {
                    XtX[a][b] += Xstd[i][a] * Xstd[i][b]
                }
            }
        }
        for a in 0..<m {
            for b in 0..<a { XtX[a][b] = XtX[b][a] }
        }

        guard let L = cholesky(XtX) else { return nil }
        let beta = cholSolve(L: L, b: Xty)

        // Inverse of XtX via repeated solves on unit vectors — reused for
        // leverage at inference time.
        var inv = Array(repeating: Array(repeating: 0.0, count: m), count: m)
        for j in 0..<m {
            var e = Array(repeating: 0.0, count: m); e[j] = 1
            let col = cholSolve(L: L, b: e)
            for i in 0..<m { inv[i][j] = col[i] }
        }

        // Residuals → R² and AICc.
        var rss = 0.0
        for i in 0..<n {
            var yhat = 0.0
            for a in 0..<m { yhat += Xstd[i][a] * beta[a] }
            let r = y[i] - yhat
            rss += r * r
        }
        let yMean = y.reduce(0, +) / Double(n)
        let tss = y.reduce(0) { $0 + ($1 - yMean) * ($1 - yMean) }
        let r2 = tss > 1e-12 ? 1 - rss / tss : 0

        let nD = Double(n)
        let pD = Double(m)   // includes intercept
        // Guard rss=0 (perfect fit): use a tiny floor so log is finite.
        let rssSafe = max(rss, 1e-12)
        let aic = nD * log(rssSafe / nD) + 2.0 * pD
        let aicCorr = (nD - pD - 1 > 0) ? 2.0 * pD * (pD + 1) / (nD - pD - 1) : .infinity
        let aicc = aic + aicCorr

        return RegressionState(
            selectedFeatures: features,
            coefficients: beta,
            means: means,
            stds: stds,
            rSquared: r2,
            aicc: aicc,
            ratingCount: n,
            lastFitAt: Date(),
            invXtX: inv
        )
    }

    // MARK: - Cholesky on a symmetric positive-definite system

    /// Cholesky factor: returns lower-triangular L such that L L' = A.
    /// nil if A is not numerically positive-definite.
    static func cholesky(_ A: [[Double]]) -> [[Double]]? {
        let m = A.count
        var L = Array(repeating: Array(repeating: 0.0, count: m), count: m)
        for i in 0..<m {
            for j in 0...i {
                var sum = A[i][j]
                for k in 0..<j { sum -= L[i][k] * L[j][k] }
                if i == j {
                    if sum <= 1e-12 { return nil }
                    L[i][j] = sqrt(sum)
                } else {
                    L[i][j] = sum / L[j][j]
                }
            }
        }
        return L
    }

    /// Given Cholesky factor L (L L' = A), solve A x = b for x.
    static func cholSolve(L: [[Double]], b: [Double]) -> [Double] {
        let m = L.count
        // Forward solve L y = b
        var ysol = Array(repeating: 0.0, count: m)
        for i in 0..<m {
            var s = b[i]
            for k in 0..<i { s -= L[i][k] * ysol[k] }
            ysol[i] = s / L[i][i]
        }
        // Back solve Lᵀ x = y
        var x = Array(repeating: 0.0, count: m)
        for ii in 0..<m {
            let i = m - 1 - ii
            var s = ysol[i]
            for k in (i + 1)..<m { s -= L[k][i] * x[k] }
            x[i] = s / L[i][i]
        }
        return x
    }

    /// Convenience: one-shot Cholesky solve.  Kept for callers (and the
    /// regression unit tests) that don't need the factor itself.
    static func solveSPD(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        guard let L = cholesky(A) else { return nil }
        return cholSolve(L: L, b: b)
    }
}

// MARK: - Persistence

enum RegressionStateStore {
    private static let key = "RegressionState_v1"

    static func load() -> RegressionState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RegressionState.self, from: data)
    }

    static func save(_ state: RegressionState?) {
        if let state, let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
