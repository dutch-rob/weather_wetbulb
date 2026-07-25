import SwiftUI

// AUTO-GENERATED — edit README.md and run generate_infoview.py to update.

struct InfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Why WetBulbCast?").font(.headline)
                    Text("Wet-bulb temperature is measured using a thermometer that has its bulb wrapped in cloth that is kept wet so that the evaporating water cools the thermometer to a lower temperature than the regular air temperature. Your evaporative (swamp) cooler works similarly, so that it cannot cool the air it blows into your house to below the wet-bulb temperature. The wet-bulb temperature depends mainly on the regular temperature and on the humidity of the air: less humidity means more cooling by a swamp cooler. When the wet-bulb temperature is enough below your comfort level, you can use a swamp cooler to cool your house to your comfort level. When the wet-bulb temperature is higher than your comfort level, your swamp cooler cannot cool your house to your comfort level and you may want to make other plans: cooling with AC or go somewhere else.")
                }

                Group {
                    Text("Start screen: 24 hour forecast").font(.headline)
                    Text("WetBulbCast starts on the screen showing 24 hour weather forecast graphs for your current location. The top graph shows temperature, wet-bulb temperature and dew point, plus the \"feels like\" temperature reported by Apple Weather. The bottom graph shows wind speed, gusts and chance of precipitation. Above the graphs, the current place is listed — tap it to switch places. Below the graphs are buttons to")
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("    • Switch between Celsius and Fahrenheit")
                            Text("    • Switch to another place")
                            Text("    • Open Settings (the cog wheel), which also holds the About screen with this info")
                        }
                    }
                }

                Group {
                    Text("Reading exact values").font(.headline)
                    Text("Press and hold a graph to drop a \"scrubber\": a dashed line at that moment in time, with a card listing the exact values for that hour — temperature and feels like, wet bulb, dew point, wind and gusts, and precipitation. Keep holding and drag left or right to move through the forecast; tap the X on the card to dismiss it.")
                }

                Group {
                    Text("Swiping").font(.headline)
                    Text("Swiping left/right gets you to graphs with 10 day forecast or a table with a larger selection of forecast data.")
                    Text("Swiping down tries to refresh your location and forecast data.")
                }

                Group {
                    Text("Places screen").font(.headline)
                    Text("The places screen lets you choose another place for which to show forecasts. It also gives a possibility to edit your list of places:")
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("    • Add a place by selecting a location on the map and giving it a name")
                            Text("    • Remove a place from the list")
                            Text("    • Change the order of the list")
                        }
                    }
                    Text("Your list of places syncs automatically across your iOS devices that are signed in to the same iCloud account.")
                }

                Group {
                    Text("Settings").font(.headline)
                    Text("The cog wheel at the bottom right opens Settings, where you can adjust:")
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("    • Units: Celsius or Fahrenheit, and a 24-hour or 12-hour clock")
                            Text("    • Show on graphs: which series to draw — temperature, wet bulb, dew point, feels like, precipitation, wind and gusts. Emptying a panel hides it")
                            Text("    • Chart style: \"Filled\" draws each series as a shaded band with a marker at the current conditions, \"Classic\" draws thin lines; colors can be vivid or muted")
                            Text("    • Table screen: turn the table off if you only want the two graph screens")
                            Text("    • Fold timeline: see below")
                        }
                    }
                }

                Group {
                    Text("Fold timeline (experimental)").font(.headline)
                    Text("Instead of paging between a 24-hour screen and a 10-day screen, the fold timeline puts both on one screen: swipe left or right and the graphs zoom smoothly between a single day and the whole forecast. The scrubber works here too. The table screen is hidden while the fold timeline is on.")
                }

                Group {
                    Text("Apple Watch").font(.headline)
                    Text("WetBulbCast includes an Apple Watch app that fetches its own forecast, so it works without your phone nearby. Swipe between a table, a 24-hour screen and a 10-day screen. It follows the units and chart style you picked on the phone, and your places are sent across from the phone.")
                    Text("Two watch-face complications are available — a corner one and a circular one. Both show the current wet-bulb temperature, ringed by a gauge covering the day's wet-bulb range, colored from cool to dangerously humid.")
                }

                Group {
                    Text("Notes").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. This app is free and open source. You can find the open source of the app on GitHub:")
                        Link("https://github.com/dutch-rob/weather_wetbulb", destination: URL(string: "https://github.com/dutch-rob/weather_wetbulb")!)
                        Text("2. You are quite welcome to provide any feedback in your review comments in the App Store, or go to GitHub and provide your comments there. Perhaps you even want to do a pull request for improvements of the code. If you found that something went wrong, please specify.")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .textSelection(.enabled)
    }
}

#Preview {
    NavigationStack {
        InfoView()
    }
}
