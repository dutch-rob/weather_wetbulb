//
//  WindDirectionEncodingTests.swift
//  weather_wetbulbTests
//
//  The tent basis must reproduce the agreed 16-direction weighting table
//  exactly, and must let the fit recover a directional pattern that a single
//  sinusoid cannot express.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct WindDirectionEncodingTests {

    // MARK: - The weighting table

    /// The 16 compass points the station reports, in degrees.
    static let compass: [(name: String, degrees: Double)] = [
        ("N", 0), ("NNE", 22.5), ("NE", 45), ("ENE", 67.5),
        ("E", 90), ("ESE", 112.5), ("SE", 135), ("SSE", 157.5),
        ("S", 180), ("SSW", 202.5), ("SW", 225), ("WSW", 247.5),
        ("W", 270), ("WNW", 292.5), ("NW", 315), ("NNW", 337.5),
    ]

    @Test func cardinalDirectionsLandWhollyOnOneKnot() {
        // Knot order is N NE E SE S SW W NW.
        for (index, point) in [("N", 0.0), ("NE", 45.0), ("E", 90.0), ("SE", 135.0),
                               ("S", 180.0), ("SW", 225.0), ("W", 270.0), ("NW", 315.0)].enumerated() {
            let w = WindDirectionEncoding.tentWeights(point.1)
            #expect(abs(w[index] - 1) < 1e-9, "\(point.0) should sit entirely on its own knot")
            #expect(abs(w.reduce(0, +) - 1) < 1e-9)
        }
    }

    @Test func intermediateDirectionsSplitEvenlyBetweenNeighbours() {
        // NNE is half N, half NE — the 0.5 / 0.5 rows of the table.
        let nne = WindDirectionEncoding.tentWeights(22.5)
        #expect(abs(nne[0] - 0.5) < 1e-9)
        #expect(abs(nne[1] - 0.5) < 1e-9)

        let wnw = WindDirectionEncoding.tentWeights(292.5)
        #expect(abs(wnw[6] - 0.5) < 1e-9)      // W
        #expect(abs(wnw[7] - 0.5) < 1e-9)      // NW
    }

    @Test func theSeamWrapsFromNorthWestBackToNorth() {
        // NNW is the row that proves the basis is cyclic: half NW, half N.
        let nnw = WindDirectionEncoding.tentWeights(337.5)
        #expect(abs(nnw[7] - 0.5) < 1e-9)      // NW
        #expect(abs(nnw[0] - 0.5) < 1e-9)      // N
        #expect(abs(nnw.reduce(0, +) - 1) < 1e-9)
    }

    @Test func everyCompassPointPutsItsWholeWeightOnAtMostTwoKnots() {
        for point in Self.compass {
            let w = WindDirectionEncoding.tentWeights(point.degrees)
            #expect(abs(w.reduce(0, +) - 1) < 1e-9, "\(point.name) weights must sum to 1")
            #expect(w.filter { $0 > 1e-9 }.count <= 2, "\(point.name) should touch two knots at most")
        }
    }

    @Test func bearingsOutsideZeroToThreeSixtyAreNormalised() {
        let plain = WindDirectionEncoding.tentWeights(45)
        #expect(WindDirectionEncoding.tentWeights(405) == plain)     // 45 + 360
        #expect(WindDirectionEncoding.tentWeights(-315) == plain)    // 45 - 360
    }

    @Test func anUnknownBearingSpreadsWeightEvenly() {
        // Not zeros: zeroing would silently delete the wind term for that row.
        // An even spread makes the row contribute the average of the eight
        // directional coefficients, which is the honest "don't know" answer.
        let w = WindDirectionEncoding.tentWeights(nil)
        #expect(abs(w.reduce(0, +) - 1) < 1e-9)
        for weight in w { #expect(abs(weight - 0.125) < 1e-9) }
    }

    @Test func continuousBearingsInterpolateProportionally() {
        // WeatherKit gives arbitrary bearings, not just the station's 16 steps.
        // A third of the way from N to NE must weight 2/3 N and 1/3 NE.
        let w = WindDirectionEncoding.tentWeights(15)
        #expect(abs(w[0] - 2.0 / 3) < 1e-9)
        #expect(abs(w[1] - 1.0 / 3) < 1e-9)
    }

    // MARK: - Fitting a shape the harmonic cannot express

    /// A house that leaks from TWO opposite-ish faces — north and south — and is
    /// tight from east and west. A single sinusoid cannot represent this: it has
    /// one maximum and forces the minimum 180 degrees away, but here the maxima
    /// are 180 degrees apart from each other.
    static func twoFacedHouse(count: Int) -> [IndoorObservation] {
        var out: [IndoorObservation] = []
        var indoorT = 22.0
        var indoorD = 8.0
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let step = 1200.0
        let hours = step / 3600

        for i in 0..<count {
            let phase = Double(i) * step / 86400 * 2 * .pi
            let outT = 18 + 9 * sin(phase)
            let outRH = 45 + 15 * cos(phase)
            let wind = 2.0 + 1.0 * sin(phase * 1.7)
            let direction = Double(i % 16) * 22.5
            let gust = wind + 0.8 + 0.6 * cos(phase * 2.3)
            let outD = IndoorPsychrometrics.dewPointC(
                temperatureC: outT, relativeHumidity: outRH) ?? 8

            // Leakage peaks at N (0) and S (180), dips at E (90) and W (270):
            // a second-harmonic pattern, invisible to a single sine/cosine pair.
            let leak = 0.06 + 0.05 * cos(2 * direction * .pi / 180)
            let rateT = 0.3 * (outT - indoorT) + leak * wind * (outT - indoorT)
            let rateD = 0.5 * (outD - indoorD)
            let nextT = indoorT + rateT * hours
            let nextD = indoorD + rateD * hours

            let values = OutdoorValues(temperatureC: outT, humidity: outRH,
                                       windSpeedMS: wind, windGustMS: gust,
                                       windDirectionDeg: direction, rainfallMM: 0,
                                       stationPressureHPa: 890)
            out.append(IndoorObservation(
                date: start.addingTimeInterval(Double(i) * step),
                dt: step,
                indoorTempC: indoorT, indoorDewPointC: indoorD,
                nextIndoorTempC: nextT, nextIndoorDewPointC: nextD,
                weatherKit: values, station: values,
                solar: max(0, sin(phase)), hvac: .off))
            indoorT = nextT
            indoorD = nextD
        }
        return out
    }

    @Test func tentBasisBeatsTheHarmonicOnATwoSidedHouse() {
        let all = Self.twoFacedHouse(count: 500)
        let (train, test) = IndoorModelEstimator.split(all)
        let plan = OutdoorSourcePlan(all: .weatherKit)

        guard let harmonic = IndoorModel.fit(train: train, test: test, plan: plan,
                                             encoding: .harmonic),
              let tent = IndoorModel.fit(train: train, test: test, plan: plan,
                                         encoding: .tentBasis)
        else { #expect(Bool(false)); return }

        // The tent basis can represent two leaky faces; the harmonic cannot, so
        // it must leave more error behind on held-out data.
        #expect(tent.score.temperatureRMSE < harmonic.score.temperatureRMSE)
    }

    @Test func selectionPicksTheEncodingThatFitsBest() {
        let all = Self.twoFacedHouse(count: 500)
        let (train, test) = IndoorModelEstimator.split(all)
        let selection = IndoorModelEstimator.selectModel(train: train, test: test)
        #expect(selection != nil)
        guard let selection else { return }
        #expect(selection.model.encoding == .tentBasis)
        // Both encodings should have been tried and scored.
        #expect(selection.scoreByEncoding.count == WindDirectionEncoding.allCases.count)
    }

    @Test func aTieGoesToTheSimplerEncoding() {
        // With no wind direction in the data the tent basis collapses to the
        // harmonic's undirected wind term — identical fits differing only by
        // ridge rounding. The cheaper encoding must win, or the model would
        // carry eight coefficients for nothing.
        var stripped: [IndoorObservation] = []
        for o in Self.twoFacedHouse(count: 400) {
            var v = o.station
            v.windDirectionDeg = nil
            stripped.append(IndoorObservation(
                date: o.date, dt: o.dt,
                indoorTempC: o.indoorTempC, indoorDewPointC: o.indoorDewPointC,
                nextIndoorTempC: o.nextIndoorTempC, nextIndoorDewPointC: o.nextIndoorDewPointC,
                weatherKit: v, station: v, solar: o.solar, hvac: o.hvac))
        }
        let (train, test) = IndoorModelEstimator.split(stripped)
        let selection = IndoorModelEstimator.selectModel(train: train, test: test)
        #expect(selection?.model.encoding == .harmonic)
    }

    @Test func everyCoefficientHasALabelUnderBothEncodings() {
        // The report screen pairs labels with coefficients using zip, which
        // silently truncates. A short label list would hide real coefficients
        // rather than fail, so the counts must match exactly.
        let all = Self.twoFacedHouse(count: 300)
        let (train, test) = IndoorModelEstimator.split(all)
        for encoding in WindDirectionEncoding.allCases {
            guard let m = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .weatherKit),
                                          encoding: encoding) else {
                #expect(Bool(false), "fit failed for \(encoding)")
                continue
            }
            #expect(m.temperatureLabels.count == m.temperature.count,
                    "temperature labels mismatch for \(encoding)")
            #expect(m.dewPointLabels.count == m.dewPoint.count,
                    "dew point labels mismatch for \(encoding)")
            // The equipment indices the report reads must land on the last
            // three entries, in cooler / AC / heating order.
            #expect(IndoorModel.equipmentIndex(.heating, in: m.temperature.count)
                    == m.temperature.count - 1)
            #expect(m.temperatureLabels.last == "heating")
        }
    }

    @Test func ventAndCoolerDriveTowardDifferentTargets() {
        // The wetted cooler pulls temperature toward the outdoor WET-BULB and
        // adds moisture; venting is dry, so it pulls toward outdoor AIR
        // temperature and dew point. They must not share a column.
        let base = Self.twoFacedHouse(count: 4)[0]
        func features(_ state: HVACState) -> [Double] {
            let o = IndoorObservation(
                date: base.date, dt: base.dt,
                indoorTempC: base.indoorTempC, indoorDewPointC: base.indoorDewPointC,
                nextIndoorTempC: base.nextIndoorTempC, nextIndoorDewPointC: base.nextIndoorDewPointC,
                weatherKit: base.weatherKit, station: base.station,
                solar: base.solar, hvac: state)
            return IndoorModel.temperatureFeatures(o, OutdoorSourcePlan(all: .station), .harmonic)!
        }
        let cooler = features(.evaporativeCooler)
        let vent = features(.vent)
        let count = cooler.count
        let coolerIndex = IndoorModel.equipmentIndex(.evaporativeCooler, in: count)!
        let ventIndex = IndoorModel.equipmentIndex(.vent, in: count)!

        // Each fills only its own slot.
        #expect(cooler[coolerIndex] != 0)
        #expect(cooler[ventIndex] == 0)
        #expect(vent[ventIndex] != 0)
        #expect(vent[coolerIndex] == 0)
        // And they are genuinely different quantities, not the same number in
        // two places: wet-bulb gap versus dry-bulb gap.
        #expect(abs(cooler[coolerIndex] - vent[ventIndex]) > 0.01)
    }

    @Test func unknownRowsNeverReachTheFit() {
        var rows = Self.twoFacedHouse(count: 300)
        // Poison a band inside the TRAINING half. Poisoning the tail instead
        // would leave the held-out slice entirely unknown, and fit() would
        // correctly return nil for want of anything to score against.
        for i in rows.indices where (100..<150).contains(i) {
            let o = rows[i]
            rows[i] = IndoorObservation(
                date: o.date, dt: o.dt,
                indoorTempC: o.indoorTempC, indoorDewPointC: o.indoorDewPointC,
                nextIndoorTempC: o.indoorTempC + 50, nextIndoorDewPointC: o.indoorDewPointC,
                weatherKit: o.weatherKit, station: o.station,
                solar: o.solar, hvac: .unknown)
        }
        let (train, test) = IndoorModelEstimator.split(rows)
        guard let m = IndoorModel.fit(train: train, test: test,
                                      plan: OutdoorSourcePlan(all: .station),
                                      encoding: .harmonic) else {
            #expect(Bool(false)); return
        }
        // 300 rows split 225/75; 50 poisoned rows sit inside the training
        // half, so exactly 175 should have been fitted.
        #expect(m.observationCount == 175)
        // And conduction survives intact rather than being dragged by +50 jumps.
        #expect(m.temperature[1] > 0.2)
    }

    @Test func steppingWorksUnderTheTentBasis() {
        let all = Self.twoFacedHouse(count: 400)
        let (train, test) = IndoorModelEstimator.split(all)
        guard let model = IndoorModel.fit(train: train, test: test,
                                          plan: OutdoorSourcePlan(all: .weatherKit),
                                          encoding: .tentBasis),
              let probe = test.first else { #expect(Bool(false)); return }
        let next = model.step(from: probe, dt: probe.dt)
        #expect(next != nil)
        #expect(abs(next!.temperatureC - probe.nextIndoorTempC) < 0.1)
    }
}
