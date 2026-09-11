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
                    Text("WetBulbCast starts on the screen showing 24 hour weather forecast graphs for your current location. The app reads the past 10 days of weather as well as the forecast, so you can scroll back to see what the weather actually did. The top graph shows temperature, wet-bulb temperature and dew point, plus the \"feels like\" temperature reported by Apple Weather. The bottom graph shows wind speed, gusts and chance of precipitation. Ringed dots mark the current time on both graphs, hollow so the page shows through, so \"now\" stays easy to find however far you have scrolled or zoomed. At the top of the screen the current place is listed — tap it to switch places — with a refresh button beside it that reloads your location and forecast. Below the graphs are buttons to")
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("    • Switch between Celsius and Fahrenheit (bottom left)")
                            Text("    • Switch to another place (\"Places\", middle)")
                            Text("    • Open this info screen (the \"i\" button)")
                            Text("    • Open Settings (the cog wheel, bottom right)")
                        }
                    }
                }

                Group {
                    Text("Reading exact values").font(.headline)
                    Text("Press and hold a graph to drop a \"scrubber\": a dashed line at that moment in time, with a card listing the exact values for that hour — temperature and feels like, wet bulb, dew point, wind and gusts, and precipitation. Keep holding and drag left or right to move through the forecast. Tap anywhere on the graph, or the X on the card, to put it away again.")
                }

                Group {
                    Text("Swiping").font(.headline)
                    Text("On a graph screen, swiping left or right scrolls the graph through time. The graph starts at the current time; swipe right to go back, up to 10 days into the past, and left to go forward through the forecast. Scrolling stops where the data does, so the 24 hour screen reaches about 10 days ahead while the 10 day screen, already showing all of it, only scrolls back. Both graph screens share the same position, so the place you scrolled to is still there when you switch screens.")
                    Text("Swiping up or down switches between the two graph screens, and the screen follows your finger so you can see where you are heading before you let go.")
                    Text("Every screen has a button at each side of its title for the two screens you are not on, which is the quickest way to the table and back. Switching between a graph and the table keeps your place in time: the graph starts at whatever hour is at the top of the table, and the table opens at whatever the graph is showing.")
                    Text("To reload your location and forecast, use the refresh button next to the place name at the top.")
                }

                Group {
                    Text("Table screen").font(.headline)
                    Text("The table lists every hour as a row: time, a weather symbol, UV index, temperature and feels like, wet bulb, dew point, wind, chance of precipitation and cloud cover. It covers the same ten days back and ten days ahead as the graphs, opens at the current hour, and scrolls sideways for the columns that do not fit.")
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
                            Text("    • Zoom graph: see below")
                        }
                    }
                }

                Group {
                    Text("Zoom graph").font(.headline)
                    Text("Instead of paging between a 24-hour screen and a 10-day screen, the zoom graph puts both on one screen. Swipe left or right to scroll through time, and pinch to zoom: from a single day out to ten days, stopping at any zoom level in between. The heading tells you how wide the window is and where it starts. A button at the top switches to the table — there is no up/down swipe here, since pinching does the zooming — and the scrubber works here too.")
                }

                Group {
                    Text("Apple Watch").font(.headline)
                    Text("WetBulbCast includes an Apple Watch app that fetches its own forecast, so it works without your phone nearby. Swipe between a table, a 24-hour screen and a 10-day screen. It follows the units and chart style you picked on the phone, and your places are sent across from the phone.")
                    Text("Two watch-face complications are available — a corner one and a circular one. Both show the current wet-bulb temperature, ringed by a gauge covering the day's wet-bulb range, colored from cool to dangerously humid.")
                }

                Group {
                    Text("Notes").font(.headline)
                    Text("The version and build date of the copy you are running are shown at the bottom of this screen, and on the watch below its graphs.")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. This app is free and open source. You can find the open source of the app on GitHub:")
                        Link("https://github.com/dutch-rob/weather_wetbulb", destination: URL(string: "https://github.com/dutch-rob/weather_wetbulb")!)
                        Text("2. You are quite welcome to provide any feedback in your review comments in the App Store, or go to GitHub and provide your comments there. Perhaps you even want to do a pull request for improvements of the code. If you found that something went wrong, please specify.")
                        Text("3. Tapping \"Look up\" beside a place's altitude sends that place's coordinate to the USGS Elevation Point Query Service (epqs.nationalmap.gov) and reads back the ground elevation. It happens only when you tap it, and nothing else is sent. Altitude matters because Apple Weather reports air pressure reduced to sea level: without a height for the place, the wet-bulb temperature comes out too high for a house up in the hills — about half a degree at 1000 metres. USGS coverage is the United States; elsewhere, type the altitude in yourself.")
                    }
                }

                // Which build this is, at the foot of the screen.
                Text(BuildInfo.versionAndDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Version \(BuildInfo.versionAndDate)")
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
