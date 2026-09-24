//
//  ThermalLagsTests.swift
//  weather_wetbulbTests
//
//  The house's slow parts, and the thermostat that decides how hard the AC
//  works. Both are state the model carries rather than reads, which is exactly
//  the kind of thing that breaks silently: a forecast that forgets its lags
//  still produces numbers, just wrong ones.
//

import Testing
import Foundation
@testable import weather_wetbulb

struct ThermalLagsTests {

    private static func observation(indoorTempC: Double = 24,
                                    indoorDewPointC: Double = 10,
                                    outdoorTempC: Double = 30,
                                    outdoorHumidity: Double = 20,
                                    hvac: HVACState = .off,
                                    setpointC: Double? = nil,
                                    lags: ThermalLags? = nil) -> IndoorObservation {
        let values = OutdoorValues(temperatureC: outdoorTempC, humidity: outdoorHumidity,
                                   windSpeedMS: 2, windGustMS: 3, windDirectionDeg: 180,
                                   rainfallMM: 0, stationPressureHPa: 890)
        return IndoorObservation(
            date: Date(timeIntervalSince1970: 1_700_000_000), dt: 1200,
            indoorTempC: indoorTempC, indoorDewPointC: indoorDewPointC,
            nextIndoorTempC: indoorTempC, nextIndoorDewPointC: indoorDewPointC,
            weatherKit: values, station: values, solar: 0,
            solarVertical: 0, solarAzimuthDeg: nil, daylight: 0,
            setpointC: setpointC, lags: lags, withinLagBurnIn: false, hvac: hvac)
    }

    // MARK: - The lags themselves

    @Test func aLagClosesMostOfTheGapAfterItsTimeConstant() {
        var lags = ThermalLags(indoorMassC: 20, envelopeC: 20, slowDewPointC: 5)
        // One envelope time constant of outdoor air held at 30 °C.
        lags = lags.advanced(indoorTempC: 20, outdoorTempC: 30, indoorDewPointC: 5,
                             dt: ThermalLags.envelopeHours * 3600)
        // 1 − 1/e of the way from 20 toward 30.
        #expect(abs(lags.envelopeC - (20 + 10 * (1 - exp(-1)))) < 1e-9)
        // The indoor mass has a far longer memory, so it has barely moved.
        #expect(lags.indoorMassC == 20)
    }

    @Test func theEnvelopeFollowsOutdoorAirNotTheRoom() {
        let start = ThermalLags(indoorMassC: 22, envelopeC: 22, slowDewPointC: 8)
        let after = start.advanced(indoorTempC: 22, outdoorTempC: 40, indoorDewPointC: 8, dt: 4 * 3600)
        #expect(after.envelopeC > 22)          // dragged toward the hot outside
        #expect(after.indoorMassC == 22)       // the room did not move, so the mass did not either
    }

    @Test func lagsMatchingTheRoomContributeNothing() {
        // A row with no history behind it must not invent a mass gradient: the
        // model falls back to lags sitting exactly where the room is, which
        // makes every lag column zero rather than large and arbitrary.
        let o = Self.observation(lags: nil)
        guard let row = IndoorModel.passiveTemperatureRow(o, OutdoorSourcePlan(all: .station), .none)
        else { #expect(Bool(false)); return }
        #expect(row[2] == 0)                   // slow indoor mass
        #expect(row[row.count - 1] == 0)       // envelope
    }

    @Test func aWarmerMassPushesTheRoomUp() {
        let o = Self.observation(lags: ThermalLags(indoorMassC: 27, envelopeC: 24, slowDewPointC: 10))
        guard let row = IndoorModel.passiveTemperatureRow(o, OutdoorSourcePlan(all: .station), .none)
        else { #expect(Bool(false)); return }
        #expect(abs(row[2] - 3) < 1e-9)        // mass 27 against a room at 24
    }

    // MARK: - The thermostat

    @Test func theCompressorRunsFlatOutAboveTheSetpointAndStopsBelowIt() {
        let thermostat = ACThermostat(capacityCPerHour: 1)
        #expect(thermostat.duty(indoorTempC: 27, setpointC: 24, passiveRate: 0.5) == 1)
        #expect(thermostat.duty(indoorTempC: 22, setpointC: 24, passiveRate: 0.5) == 0)
    }

    @Test func atTheSetpointItRunsAsHardAsTheHeatComingIn() {
        // Holding steady: the duty is the passive warming rate over the
        // capacity, which is what makes a hot afternoon dry the house harder
        // than a mild evening does.
        let thermostat = ACThermostat(capacityCPerHour: 2)
        let mild = thermostat.duty(indoorTempC: 24, setpointC: 24, passiveRate: 0.4)
        let hot = thermostat.duty(indoorTempC: 24, setpointC: 24, passiveRate: 1.6)
        #expect(abs(mild - 0.2) < 1e-9)
        #expect(abs(hot - 0.8) < 1e-9)
        #expect(hot > mild)
    }

    @Test func withoutARecordedSetpointItIsAssumedToRun() {
        let thermostat = ACThermostat(capacityCPerHour: 1)
        #expect(thermostat.duty(indoorTempC: 24, setpointC: nil, passiveRate: 0) == 1)
    }

    @Test func dryingFollowsTheDutyRatherThanMerelyBeingOn() {
        let plan = OutdoorSourcePlan(all: .station)
        let coil = CoilTemperature(baseC: 8, perOutdoorDegree: 0.15)
        let thermostat = ACThermostat(capacityCPerHour: 2)
        func dryingColumn(indoorTempC: Double) -> Double {
            let o = Self.observation(indoorTempC: indoorTempC, indoorDewPointC: 14,
                                     hvac: .airConditioning, setpointC: 24)
            let row = IndoorModel.equipmentDewPointRow(o, plan, coil, CoolerEffectiveness(),
                                                       thermostat, passiveRate: 0.4)
            return row?[0] ?? .nan
        }
        // Pulling down from well above the setpoint: full duty, hardest drying.
        let pullDown = dryingColumn(indoorTempC: 27)
        // Cycling at the setpoint: the same coil, but running part of the time.
        let cycling = dryingColumn(indoorTempC: 24)
        #expect(pullDown > cycling)
        #expect(cycling > 0)
    }

    // MARK: - Wind from one source

    @Test func gustinessComesFromOneInstrumentEvenWhenThePlanMixesSources() {
        // The station sits low behind a wall and reads slower than WeatherKit.
        // Mixing them once made "gustiness" mostly a measure of how far the two
        // disagree — zero half the time because WeatherKit's wind was higher.
        var station = OutdoorValues(temperatureC: 30, humidity: 20,
                                    windSpeedMS: 2, windGustMS: 5, windDirectionDeg: 180,
                                    rainfallMM: 0, stationPressureHPa: 890)
        station.windGustMS = 5
        var weatherKit = station
        weatherKit.windSpeedMS = 6            // higher sustained wind
        weatherKit.windGustMS = 9
        let o = IndoorObservation(
            date: Date(), dt: 1200, indoorTempC: 24, indoorDewPointC: 10,
            nextIndoorTempC: 24, nextIndoorDewPointC: 10,
            weatherKit: weatherKit, station: station, solar: 0, hvac: .off)

        var mixed = OutdoorSourcePlan(all: .station)
        mixed[.windSpeed] = .weatherKit       // the case that caused the trouble
        let fromMixed = InfiltrationTerms(o, mixed)
        // Wind and gust both come from WeatherKit, so gustiness is 9 − 6.
        #expect(abs(fromMixed.wind - 6) < 1e-9)
        #expect(abs(fromMixed.gustExcess - 3) < 1e-9)

        let fromStation = InfiltrationTerms(o, OutdoorSourcePlan(all: .station))
        #expect(abs(fromStation.wind - 2) < 1e-9)
        #expect(abs(fromStation.gustExcess - 3) < 1e-9)
    }
}
