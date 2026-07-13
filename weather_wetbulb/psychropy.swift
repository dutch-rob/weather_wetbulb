import Foundation

/// Translated from `psychropy.py`.
/// Computes wet-bulb temperature in Fahrenheit from:
/// - pressure in pascals
/// - dry-bulb temperature in Fahrenheit
/// - relative humidity as a fraction (`0.55`) or percent (`55`)
enum PsychrometryCalculator {
    /// Saturation vapor pressure in kPa.
    /// Source: ASHRAE Fundamentals (2005), SI Edition, equations 5 and 6.
    static func satPress(_ dryBulbCelsius: Double) -> Double {
        let c1 = -5674.5359
        let c2 = 6.3925247
        let c3 = -0.009677843
        let c4 = 0.00000062215701
        let c5 = 2.0747825e-09
        let c6 = -9.484024e-13
        let c7 = 4.1635019
        let c8 = -5800.2206
        let c9 = 1.3914993
        let c10 = -0.048640239
        let c11 = 0.000041764768
        let c12 = -0.000000014452093
        let c13 = 6.5459673

        let temperatureKelvin = dryBulbCelsius + 273.15

        if temperatureKelvin <= 273.15 {
            return exp(
                c1 / temperatureKelvin +
                c2 +
                c3 * temperatureKelvin +
                c4 * pow(temperatureKelvin, 2) +
                c5 * pow(temperatureKelvin, 3) +
                c6 * pow(temperatureKelvin, 4) +
                c7 * log(temperatureKelvin)
            ) / 1000.0
        }

        return exp(
            c8 / temperatureKelvin +
            c9 +
            c10 * temperatureKelvin +
            c11 * pow(temperatureKelvin, 2) +
            c12 * pow(temperatureKelvin, 3) +
            c13 * log(temperatureKelvin)
        ) / 1000.0
    }

    /// Humidity ratio in kg H2O / kg air from dry-bulb and wet-bulb temperatures in degC.
    static func humidityRatio(
        dryBulb dryBulbCelsius: Double,
        wetBulb wetBulbCelsius: Double,
        pressure pressureKPa: Double
    ) -> Double {
        let saturationPressure = satPress(wetBulbCelsius)
        let saturationHumidityRatio = 0.62198 * saturationPressure / (pressureKPa - saturationPressure)

        if dryBulbCelsius >= 0 {
            return (
                ((2501 - 2.326 * wetBulbCelsius) * saturationHumidityRatio) -
                (1.006 * (dryBulbCelsius - wetBulbCelsius))
            ) / (2501 + 1.86 * dryBulbCelsius - 4.186 * wetBulbCelsius)
        }

        return (
            ((2830 - 0.24 * wetBulbCelsius) * saturationHumidityRatio) -
            (1.006 * (dryBulbCelsius - wetBulbCelsius))
        ) / (2830 + 1.86 * dryBulbCelsius - 2.1 * wetBulbCelsius)
    }

    /// Humidity ratio in kg H2O / kg air from dry-bulb temperature in degC and RH.
    static func humidityRatio(
        dryBulb dryBulbCelsius: Double,
        relativeHumidity rawRelativeHumidity: Double,
        pressure pressureKPa: Double
    ) -> Double {
        let relativeHumidity = normalizedRelativeHumidity(rawRelativeHumidity)
        let saturationPressure = satPress(dryBulbCelsius)
        return 0.62198 * relativeHumidity * saturationPressure /
            (pressureKPa - relativeHumidity * saturationPressure)
    }

    /// Wet-bulb temperature in degC using Newton-Raphson iteration.
    static func wetBulb(
        dryBulb dryBulbCelsius: Double,
        relativeHumidity rawRelativeHumidity: Double,
        pressure pressureKPa: Double
    ) -> Double {
        let relativeHumidity = normalizedRelativeHumidity(rawRelativeHumidity)
        let targetHumidityRatio = humidityRatio(
            dryBulb: dryBulbCelsius,
            relativeHumidity: relativeHumidity,
            pressure: pressureKPa
        )

        var wetBulbEstimate = dryBulbCelsius
        var currentHumidityRatio = humidityRatio(
            dryBulb: dryBulbCelsius,
            wetBulb: wetBulbEstimate,
            pressure: pressureKPa
        )

        let referenceMagnitude = max(abs(targetHumidityRatio), 1e-12)
        var iterationCount = 0

        while abs(currentHumidityRatio - targetHumidityRatio) / referenceMagnitude > 0.00001,
              iterationCount < 1000 {
            let offsetHumidityRatio = humidityRatio(
                dryBulb: dryBulbCelsius,
                wetBulb: wetBulbEstimate - 0.001,
                pressure: pressureKPa
            )
            let derivative = (currentHumidityRatio - offsetHumidityRatio) / 0.001

            guard abs(derivative) > 1e-12 else {
                break
            }

            wetBulbEstimate -= (currentHumidityRatio - targetHumidityRatio) / derivative
            currentHumidityRatio = humidityRatio(
                dryBulb: dryBulbCelsius,
                wetBulb: wetBulbEstimate,
                pressure: pressureKPa
            )
            iterationCount += 1
        }

        return wetBulbEstimate
    }

    /// Wet-bulb temperature in degF.
    static func psychF(
        pressurePa: Double,
        dryBulbFahrenheit: Double,
        relativeHumidity: Double
    ) -> Double {
        let pressureKPa = pressurePa / 1000.0
        let dryBulbCelsius = (dryBulbFahrenheit - 32.0) / 1.8
        let wetBulbCelsius = wetBulb(
            dryBulb: dryBulbCelsius,
            relativeHumidity: relativeHumidity,
            pressure: pressureKPa
        )
        return 1.8 * wetBulbCelsius + 32.0
    }

    /// Wet-bulb temperature in degC.
    static func psychC(
        pressurePa: Double,
        dryBulbCelsius: Double,
        relativeHumidity: Double
    ) -> Double {
        let pressureKPa = pressurePa / 1000.0
        let wetBulbCelsius = wetBulb(
            dryBulb: dryBulbCelsius,
            relativeHumidity: relativeHumidity,
            pressure: pressureKPa
        )
        return wetBulbCelsius
    }

    private static func normalizedRelativeHumidity(_ value: Double) -> Double {
        value > 1.0 ? value / 100.0 : value
    }
}

