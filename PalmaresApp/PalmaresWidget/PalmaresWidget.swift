//
//  PalmaresWidget.swift
//  PalmaresWidget (widget extension target)
//
//  Home screen widget fed entirely by the web app: index.html computes the
//  snapshot (fitness, weather, tailwind, next club event, streaks), posts it
//  over the palmaresNative bridge, and WidgetBridge.swift in the app target
//  writes it into the shared App Group. This extension only reads and draws —
//  it re-derives nothing, so web and widget can never disagree.
//
//  Setup: File > New > Target > Widget Extension (name it PalmaresWidget,
//  uncheck Live Activity / configuration intent), replace the generated
//  swift file with this one, and give the extension the same App Group as
//  the app. Full steps in ios/README.md.
//

import WidgetKit
import SwiftUI

// MARK: - Snapshot model (mirrors the JSON from index.html's updateWidgetData)

struct WidgetSnapshot: Codable {
    struct Fitness: Codable {
        var ctl: Int?
        var atl: Int?
        var tsb: Int?
        var formLabel: String?
        var ctlWeekDelta: Int?
    }
    struct Week: Codable {
        var miles: Int?
        var activities: Int?
    }
    struct Streaks: Codable {
        var daily: Int?
        var weekly: Int?
    }
    struct Weather: Codable {
        var tempHi: Int?
        var tempLo: Int?
        var desc: String?
        var icon: String?
        var windMph: Int?
        var windDir: String?
        var source: String?
    }
    struct Tailwind: Codable {
        var name: String?
        var mph: Int?
        var rank: Int?
        var distanceMi: Double?
    }
    struct NextEvent: Codable {
        var title: String?
        var club: String?
        var date: String?   // ISO8601

        var parsedDate: Date? {
            guard let date else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: date) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: date)
        }
    }

    var fitness: Fitness?
    var week: Week?
    var streaks: Streaks?
    var weather: Weather?
    var tailwind: Tailwind?
    var nextEvent: NextEvent?
}

struct SnapshotRecord: Codable {
    var data: WidgetSnapshot
    var updatedAt: String?
}

// MARK: - Loading from the App Group

enum SnapshotStore {
    // Must match WidgetBridge.appGroupID in the app target.
    static let appGroupID = "group.com.kamildobrowolski.palmares"
    static let snapshotKey = "widgetSnapshot"

    static func load() -> SnapshotRecord? {
        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let json = defaults.data(forKey: snapshotKey)
        else { return nil }
        return try? JSONDecoder().decode(SnapshotRecord.self, from: json)
    }
}

// MARK: - Timeline

struct PalmaresEntry: TimelineEntry {
    let date: Date
    let record: SnapshotRecord?
}

struct PalmaresProvider: TimelineProvider {
    func placeholder(in context: Context) -> PalmaresEntry {
        PalmaresEntry(date: .now, record: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (PalmaresEntry) -> Void) {
        completion(PalmaresEntry(date: .now, record: SnapshotStore.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PalmaresEntry>) -> Void) {
        // Data only changes when the app runs (WidgetBridge reloads timelines
        // on every bridge push), so a single entry suffices. The half-hour
        // refresh just keeps relative text like "in 3h" from going stale.
        let entry = PalmaresEntry(date: .now, record: SnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Palette (matches the web app)

private extension Color {
    static let pmBackground = Color(red: 0x0d/255, green: 0x11/255, blue: 0x17/255) // #0d1117
    static let pmText       = Color(red: 0xe6/255, green: 0xed/255, blue: 0xf3/255) // #e6edf3
    static let pmMuted      = Color(red: 0x7d/255, green: 0x85/255, blue: 0x90/255) // #7d8590
    static let pmGold       = Color(red: 0xC9/255, green: 0xA2/255, blue: 0x27/255) // #C9A227
    static let pmGreen      = Color(red: 0x3f/255, green: 0xb9/255, blue: 0x50/255) // #3fb950
    static let pmAmber      = Color(red: 0xd2/255, green: 0x99/255, blue: 0x22/255) // #d29922
    static let pmRed        = Color(red: 0xf8/255, green: 0x51/255, blue: 0x49/255) // #f85149
}

private func formColor(_ tsb: Int?) -> Color {
    guard let tsb else { return .pmMuted }
    if tsb > 5 { return .pmGreen }
    if tsb > -10 { return .pmText }
    if tsb > -30 { return .pmAmber }
    return .pmRed
}

// MARK: - Views

struct PalmaresWidgetEntryView: View {
    var entry: PalmaresEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if let record = entry.record {
                switch family {
                case .systemMedium: MediumView(snapshot: record.data)
                default: SmallView(snapshot: record.data)
                }
            } else {
                // Nothing in the App Group yet: the app hasn't run since the
                // widget was added. Say so instead of drawing zeros.
                VStack(spacing: 4) {
                    Text("Palmarès").font(.headline).foregroundStyle(Color.pmGold)
                    Text("Open the app to load your data")
                        .font(.caption2).foregroundStyle(Color.pmMuted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .containerBackground(Color.pmBackground, for: .widget)
    }
}

struct SmallView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Form").font(.caption2).foregroundStyle(Color.pmMuted)
                Spacer()
                if let wx = snapshot.weather, let hi = wx.tempHi {
                    Text("\(wx.icon ?? "") \(hi)°").font(.caption).foregroundStyle(Color.pmText)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.fitness?.tsb.map { ($0 >= 0 ? "+" : "") + String($0) } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(formColor(snapshot.fitness?.tsb))
                Text(snapshot.fitness?.formLabel ?? "")
                    .font(.caption).foregroundStyle(formColor(snapshot.fitness?.tsb))
            }
            Spacer(minLength: 0)
            if let week = snapshot.week, let mi = week.miles {
                Text("\(mi) mi this week")
                    .font(.caption).foregroundStyle(Color.pmText)
            }
            if let wx = snapshot.weather, let wind = wx.windMph {
                Text("\(wx.windDir ?? "") wind \(wind) mph")
                    .font(.caption2).foregroundStyle(Color.pmMuted)
            }
        }
        .padding(2)
    }
}

struct MediumView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 14) {
            // Left: form + volume (same content as the small widget)
            VStack(alignment: .leading, spacing: 6) {
                Text("Form").font(.caption2).foregroundStyle(Color.pmMuted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.fitness?.tsb.map { ($0 >= 0 ? "+" : "") + String($0) } ?? "—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(formColor(snapshot.fitness?.tsb))
                    Text(snapshot.fitness?.formLabel ?? "")
                        .font(.caption).foregroundStyle(formColor(snapshot.fitness?.tsb))
                }
                if let f = snapshot.fitness, let ctl = f.ctl, let atl = f.atl {
                    Text("CTL \(ctl) · ATL \(atl)")
                        .font(.caption2).foregroundStyle(Color.pmMuted)
                }
                Spacer(minLength: 0)
                if let week = snapshot.week, let mi = week.miles {
                    Text("\(mi) mi · \(week.activities ?? 0) rides this week")
                        .font(.caption).foregroundStyle(Color.pmText)
                }
                if let streaks = snapshot.streaks, let daily = streaks.daily, daily > 0 {
                    Text("🔥 \(daily)-day streak")
                        .font(.caption2).foregroundStyle(Color.pmGold)
                }
            }

            Divider().overlay(Color.pmMuted.opacity(0.4))

            // Right: conditions + what's next
            VStack(alignment: .leading, spacing: 6) {
                if let wx = snapshot.weather {
                    HStack(spacing: 6) {
                        Text(wx.icon ?? "").font(.title3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(wx.tempHi ?? 0)° / \(wx.tempLo ?? 0)°")
                                .font(.caption).bold().foregroundStyle(Color.pmText)
                            Text("\(wx.windDir ?? "") \(wx.windMph ?? 0) mph")
                                .font(.caption2).foregroundStyle(Color.pmMuted)
                        }
                    }
                }
                if let tw = snapshot.tailwind, let name = tw.name {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Tailwind pick").font(.caption2).foregroundStyle(Color.pmMuted)
                        Text(name).font(.caption).foregroundStyle(Color.pmGreen).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let ev = snapshot.nextEvent, let title = ev.title {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Next ride").font(.caption2).foregroundStyle(Color.pmMuted)
                        Text(title).font(.caption).foregroundStyle(Color.pmGold).lineLimit(1)
                        if let date = ev.parsedDate {
                            Text(date, format: .dateTime.weekday(.wide).hour().minute())
                                .font(.caption2).foregroundStyle(Color.pmText)
                        }
                    }
                }
            }
        }
        .padding(2)
    }
}

// MARK: - Widget declaration

struct PalmaresWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PalmaresWidget", provider: PalmaresProvider()) { entry in
            PalmaresWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Palmarès")
        .description("Form, conditions, and your next ride at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PalmaresWidgetBundle: WidgetBundle {
    var body: some Widget {
        PalmaresWidget()
    }
}

// MARK: - Preview data

extension SnapshotRecord {
    static let preview = SnapshotRecord(
        data: WidgetSnapshot(
            fitness: .init(ctl: 62, atl: 55, tsb: 7, formLabel: "Fresh", ctlWeekDelta: 3),
            week: .init(miles: 84, activities: 4),
            streaks: .init(daily: 3, weekly: 12),
            weather: .init(tempHi: 88, tempLo: 71, desc: "Clear", icon: "☀️",
                           windMph: 9, windDir: "SW", source: "Open-Meteo"),
            tailwind: .init(name: "Old Northport Rd", mph: 12, rank: 2, distanceMi: 1.4),
            nextEvent: .init(title: "LiVelo Night Ride", club: "LiVelo",
                             date: "2026-07-22T22:30:00Z")
        ),
        updatedAt: nil
    )
}
