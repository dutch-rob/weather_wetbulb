//
//  EvaporativeCooler.swift
//  MyFeelsLike
//
//  Transforms an outdoor forecast point into the indoor climate produced by a
//  continuously-running evaporative ("swamp") cooler.
//
//  Model
//  ─────
//  The cooler blows outdoor air, cooled to (near) the outdoor wet-bulb
//  temperature at ~100 % RH, into the house, displacing the prior air. That
//  supply air then warms up toward the outdoor dry-bulb temperature, the
//  amount depending on how well the house resists heat gain (insulation, sun,
//  thermal mass — lumped here into a single 0…100 "insulation" slider). The
//  moisture added by the cooler does not change: the indoor dew point stays at
//  the outdoor wet-bulb temperature, so as the air warms its relative humidity
//  falls.
//
//    T_indoor   = T_db − (insulation/100) · (T_db − T_wb)
//                 ( insulation 0  → T_indoor = T_db   : no cooling benefit
//                   insulation 100 → T_indoor = T_wb   : maximum cooling )
//    dewpoint   = T_wb (outdoor wet bulb)  → RH_indoor = e_s(T_wb) / e_s(T_indoor)
//
//  Apparent temperature indoors is computed with the Steadman "Apparent
//  Temperature" formula (dry-bulb + humidity + wind, no solar term), which is
//  exactly the right shape for an indoor, out-of-sun environment. Wind is the
//  optional fan speed (0 when no fan).
//

import Foundation

// In-house / evaporative cooler modelling is currently disabled.
// Sun-position and thermal-mass effects make it unreliable without a
// real indoor temperature signal (e.g. from a smart thermostat); we'll
// revisit this once HomeKit thermostat access is wired in.
#if false
enum EvaporativeCooler {

    /// Produce the indoor forecast point for one outdoor point.
    /// - Parameters:
    ///   - p: outdoor forecast point (already has wet bulb computed).
    ///   - insulation: 0…100 house insulation quality.
    ///   - fanWindKPH: indoor air movement from a fan, kph (0 when off).
    static func indoorPoint(from p: ForecastPoint,
                            insulation: Double,
                            fanWindKPH: Double) -> ForecastPoint {
        let tDb = p.temperatureC
        let tWb = p.wetBulbC
        let frac = max(0, min(1, insulation / 100))
        let tIndoor = tDb - frac * (tDb - tWb)

        // Indoor dew point = outdoor wet bulb. RH = vapour-pressure ratio.
        // satPress returns kPa; the ratio is dimensionless.
        let actualVP = PsychrometryCalculator.satPress(tWb)
        let satVP    = PsychrometryCalculator.satPress(tIndoor)
        let rhIndoor = satVP > 1e-9 ? max(0, min(1, actualVP / satVP)) : 1

        // Recompute indoor wet bulb from indoor T + RH (≈ outdoor wet bulb,
        // but rises slightly under sensible heating — compute it properly).
        let wetIndoorC = PsychrometryCalculator.psychC(
            pressurePa: p.stationPressurePa,
            dryBulbCelsius: tIndoor,
            relativeHumidity: rhIndoor)

        let atC = steadmanApparentC(tempC: tIndoor, rh: rhIndoor, windKPH: fanWindKPH)
        let dewIndoorC = tWb   // dew point preserved = outdoor wet bulb

        return ForecastPoint(
            id:                   p.id,    // preserve identity for row matching
            date:                 p.date,
            symbolName:           "house",
            isDaylight:           p.isDaylight,
            uvIndex:              0,                 // no UV indoors
            temperatureF:         TempUnit.cToF(tIndoor),
            temperatureC:         tIndoor,
            apparentTemperatureF: TempUnit.cToF(atC),
            apparentTemperatureC: atC,
            wetBulbF:             TempUnit.cToF(wetIndoorC),
            wetBulbC:             wetIndoorC,
            dewPointF:            TempUnit.cToF(dewIndoorC),
            dewPointC:            dewIndoorC,
            precipProbability:    0,
            precipitationMM:      0,
            windSpeedMPH:         fanWindKPH / 1.609344,
            windSpeedKPH:         fanWindKPH,
            cloudCover:           0,
            cloudCoverLow:        0,
            cloudCoverMedium:     0,
            cloudCoverHigh:       0,
            humidity:             rhIndoor,
            stationPressurePa:    p.stationPressurePa,
            myFeelsLikeC:         nil,
            myFeelsLikeF:         nil
        )
    }

    /// Steadman Apparent Temperature (°C), the non-radiation form:
    ///   AT = Ta + 0.33·e − 0.70·ws − 4.00
    /// where e is water-vapour pressure (hPa) and ws is wind speed (m/s).
    static func steadmanApparentC(tempC: Double, rh: Double, windKPH: Double) -> Double {
        let e  = rh * 6.105 * exp(17.27 * tempC / (237.7 + tempC))   // hPa
        let ws = windKPH / 3.6                                       // m/s
        return tempC + 0.33 * e - 0.70 * ws - 4.00
    }
}
#endif
