//
//  EventReminders.swift
//  Palmares (app target)
//
//  Schedules local notifications for upcoming group rides. The page sends
//  the ride list over the bridge (type: "eventReminders") every time the
//  events card loads - Strava club events and external calendar rides
//  alike - and this replaces all previously scheduled ride reminders with
//  the fresh list, so cancelled/changed rides never fire stale alerts.
//
//  Each ride gets:
//    - a reminder 1 hour before the start
//    - for morning rides (before noon), a heads-up at 8pm the evening before
//
//  Integration (ios/README.md has the full steps): add this file to the app
//  target and route the message in WebView.swift's
//  userContentController(_:didReceive:):
//
//      if let body = message.body as? [String: Any] {
//          switch body["type"] as? String {
//          case "widgetData":      WidgetBridge.handle(body); return
//          case "eventReminders":  EventReminders.handle(body); return
//          default: break
//          }
//      }
//
//  No Info.plist changes needed - notification permission is requested at
//  first use, and re-asking is a no-op once answered.
//

import Foundation
import UserNotifications

enum EventReminders {

    /// All identifiers carry this prefix so ours can be cleared without
    /// touching any other notifications the app might schedule later.
    private static let idPrefix = "pm-ride-"

    static func handle(_ body: [String: Any]) {
        guard let events = body["events"] as? [[String: Any]] else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }

            // Replace, never accumulate: the page resends the full upcoming
            // list, so pending reminders from the previous send are stale.
            center.getPendingNotificationRequests { pending in
                let ours = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
                center.removePendingNotificationRequests(withIdentifiers: ours)
                schedule(events: events, center: center)
            }
        }
    }

    private static func schedule(events: [[String: Any]], center: UNUserNotificationCenter) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for (index, event) in events.prefix(10).enumerated() {
            guard
                let dateString = event["date"] as? String,
                let start = iso.date(from: dateString) ?? isoPlain.date(from: dateString)
            else { continue }

            let title = event["title"] as? String ?? "Group ride"
            let club = event["club"] as? String

            let timeText = start.formatted(date: .omitted, time: .shortened)
            let dayText = Calendar.current.isDateInToday(start) ? "today"
                : Calendar.current.isDateInTomorrow(start) ? "tomorrow"
                : start.formatted(.dateTime.weekday(.wide))

            // 1 hour before the start
            add(center: center,
                id: "\(idPrefix)\(index)-hour",
                title: "\(title) in 1 hour",
                body: [club, "Rolls out at \(timeText)."].compactMap { $0 }.joined(separator: " — "),
                fireAt: start.addingTimeInterval(-3600))

            // Evening-before heads-up for morning rides
            let hour = Calendar.current.component(.hour, from: start)
            if hour < 12,
               let eveBefore = Calendar.current.date(byAdding: .day, value: -1, to: start),
               let evening = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: eveBefore) {
                add(center: center,
                    id: "\(idPrefix)\(index)-eve",
                    title: "\(title) \(dayText == "today" ? "tomorrow" : dayText) morning",
                    body: [club, "Starts at \(timeText) — lay out the kit tonight."].compactMap { $0 }.joined(separator: " — "),
                    fireAt: evening)
            }
        }
    }

    private static func add(center: UNUserNotificationCenter, id: String,
                            title: String, body: String, fireAt: Date) {
        guard fireAt > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
