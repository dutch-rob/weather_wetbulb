//
//  WatchTableView.swift
//  WetBulbCastW Watch App
//
//  Hourly table, scrollable both ways (vertical for hours, horizontal for the
//  extra columns). Same idea as the phone table.
//

import SwiftUI

struct WatchTableView: View {
    @ObservedObject var model: WatchWeatherModel
    @ObservedObject private var sync = WatchSyncReceiver.shared
    private var useF: Bool { sync.payload?.useFahrenheit ?? false }

    private static let timeFmt: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE HH"
        return df
    }()

    // Column widths
    private let wTime: CGFloat = 48
    private let wSym:  CGFloat = 20
    private let wTemp: CGFloat = 54
    private let wWet:  CGFloat = 34
    private let wDew:  CGFloat = 34
    private let wWind: CGFloat = 34
    private let wPcp:  CGFloat = 40
    private let wCld:  CGFloat = 34
    private var totalW: CGFloat { wTime + wSym + wTemp + wWet + wDew + wWind + wPcp + wCld + 12 }

    var body: some View {
        if model.series10d.isEmpty {
            VStack { Spacer(); ProgressView(); Spacer() }
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        ForEach(model.series10d) { p in row(p) }
                    } header: {
                        header
                    }
                }
                .frame(minWidth: totalW)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("Time", wTime, .leading)
            cell("",     wSym,  .center)
            cell(useF ? "T/fl°F" : "T/fl°C", wTemp, .trailing)
            cell("Wet",  wWet,  .trailing)
            cell("Dew",  wDew,  .trailing)
            cell("Wnd",  wWind, .trailing)
            cell("Pcp",  wPcp,  .trailing)
            cell("Cld",  wCld,  .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(Color(white: 0.18))
    }

    @ViewBuilder private func row(_ p: ForecastPoint) -> some View {
        HStack(spacing: 0) {
            cell(Self.timeFmt.string(from: p.date), wTime, .leading)
            Image(systemName: p.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 12))
                .frame(width: wSym, alignment: .center)
            cell(tempText(p), wTemp, .trailing)
            cell(fmt0(useF ? p.wetBulbF  : p.wetBulbC),  wWet,  .trailing)
            cell(fmt0(useF ? p.dewPointF : p.dewPointC), wDew,  .trailing)
            cell(fmt0(useF ? p.windSpeedMPH : p.windSpeedKPH), wWind, .trailing)
            cell(String(format: "%.0f%%", p.precipProbability * 100), wPcp, .trailing)
            cell(String(format: "%.0f", p.cloudCover * 100), wCld, .trailing)
        }
        .font(.system(size: 13))
        .padding(.vertical, 2).padding(.horizontal, 6)
    }

    @ViewBuilder private func cell(_ text: String, _ width: CGFloat, _ align: Alignment) -> some View {
        Text(text).frame(width: width, alignment: align).lineLimit(1)
    }

    private func fmt0(_ n: Double) -> String { String(format: "%.0f", n) }

    private func tempText(_ p: ForecastPoint) -> String {
        let t = useF ? p.temperatureF : p.temperatureC
        let a = useF ? p.apparentTemperatureF : p.apparentTemperatureC
        return String(format: "%.0f(%.0f)", t, a)
    }
}
