import SwiftUI

// AUTO-GENERATED — edit README.md and run generate_infoview.py to update.

struct InfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Why Wetbulb?").font(.headline)
                    Text("Wet-bulb temperature is measured using a thermometer that has its bulb wrapped in cloth that is kept wet so that the evaporating water cools the thermometer to a lower temperature that the regular air temperature. Your evaporative (swamp) cooler works similarly so that it cannot cool the air it blows into your house to below the wet bulb temperature. The wetbulb temperature depends mainly on the regular temperature and on the humidity of the air: less humidity means more cooling by a swamp cooler. When the wetbulb temperature is enough below your comfort level, you can use a swamp cooler to cool you house to your comfort level. When the wetbulb temperature is higher than your comfort level, your swamp cooler can not cool you house to your comfort level and you may want to make other plans: cooling with AC or go somewhere else.")
                }

                Group {
                    Text("Start screen: 24 hour forecast").font(.headline)
                    Text("The Wetbulb app starts on the screen showing 24 hour weather forecast graphs for you current location. The top graph show temperature, wet bulb temperature and dew point. The bottom graph show wind speed and chance of precipitation. Above the graphs, the current place is listed. Below the graphs are buttons to - Switch between Celsius and Fahrenheit - Switch to another place - Pull up aa screen with this info")
                }

                Group {
                    Text("Swiping").font(.headline)
                    Text("Swiping left/right gets you to graphs with 10 day forecast or a table with a larger selection of forecast data.")
                    Text("Swiping down tries to refresh your location and forecast data.")
                }

                Group {
                    Text("Places screen").font(.headline)
                    Text("The places screen lets you choose another place for which to show forecasts. It also gives a possibility to edit your list of places: - Add a place by selection a location on the map and giving it a name. - Remove a place from the list - Change the order of the list")
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
