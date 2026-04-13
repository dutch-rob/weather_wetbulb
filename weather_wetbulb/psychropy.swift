import Foundation
import SwiftUI

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
    static func psych(
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

    private static func normalizedRelativeHumidity(_ value: Double) -> Double {
        value > 1.0 ? value / 100.0 : value
    }
}

struct PsychropyView: View {
    @State private var pressurePaText = "101420"
    @State private var dryBulbFahrenheitText = "64"
    @State private var relativeHumidityText = "0.55"
    @State private var resultText = "Wet-bulb temperature will appear here."
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Inputs") {
                    TextField("Pressure (Pa)", text: $pressurePaText)
                    TextField("Dry Bulb Temperature (degF)", text: $dryBulbFahrenheitText)
                    TextField("Relative Humidity (fraction or %)", text: $relativeHumidityText)
                }

                Section("Result") {
                    Text(resultText)

                    if let errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }

                Button("Calculate Wet Bulb", action: calculate)
            }
            .navigationTitle("Psychropy")
        }
    }

    private func calculate() {
        guard let pressurePa = Double(pressurePaText),
              let dryBulbFahrenheit = Double(dryBulbFahrenheitText),
              let relativeHumidity = Double(relativeHumidityText) else {
            errorText = "Enter numeric values for pressure, dry-bulb temperature, and relative humidity."
            return
        }

        let wetBulbFahrenheit = PsychrometryCalculator.psych(
            pressurePa: pressurePa,
            dryBulbFahrenheit: dryBulbFahrenheit,
            relativeHumidity: relativeHumidity
        )

        resultText = String(format: "Wet-bulb temperature: %.3f degF", wetBulbFahrenheit)
        errorText = nil
    }
}

struct PsychropyView_Previews: PreviewProvider {
    static var previews: some View {
        PsychropyView()
    }
}

