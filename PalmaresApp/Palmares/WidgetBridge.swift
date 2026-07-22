//
//  WidgetBridge.swift
//  Palmares (app target — NOT the widget extension)
//
//  Receives the `widgetData` message that index.html posts over the
//  palmaresNative bridge, persists the snapshot into the shared App Group,
//  and asks WidgetKit to redraw the home screen widget.
//
//  Integration (see ios/README.md for the full steps):
//    1. Add this file to the main app target.
//    2. In WebView.swift's userContentController(_:didReceive:), add:
//
//         if let body = message.body as? [String: Any],
//            body["type"] as? String == "widgetData" {
//             WidgetBridge.handle(body)
//             return
//         }
//
//    3. Both the app target and the widget extension need the App Group
//       capability with the SAME group id as `appGroupID` below.
//

import Foundation
import WidgetKit

enum WidgetBridge {

    /// Must match the App Group enabled on BOTH targets, and the suiteName
    /// used in PalmaresWidget.swift. Change in both places if you rename it.
    /// Namespaced under the app's own bundle id rather than the generic
    /// group.com.palmares.shared: App Group ids are globally unique across
    /// Apple, so one matching the bundle prefix registers cleanly with
    /// automatic signing. Must match PalmaresWidget.swift's SnapshotStore.
    static let appGroupID = "group.com.kamildobrowolski.palmares"

    /// UserDefaults key holding the raw JSON snapshot from the page.
    static let snapshotKey = "widgetSnapshot"

    /// Handle a decoded `widgetData` bridge message.
    /// Expected shape: { type: "widgetData", updatedAt: ISO8601, data: {...} }
    static func handle(_ body: [String: Any]) {
        guard let data = body["data"] as? [String: Any] else { return }

        // Store the snapshot plus the moment it arrived, so the widget can
        // show staleness honestly instead of pretending old data is current.
        var record: [String: Any] = ["data": data]
        record["updatedAt"] = body["updatedAt"] as? String
            ?? ISO8601DateFormatter().string(from: Date())

        guard
            let defaults = UserDefaults(suiteName: appGroupID),
            let json = try? JSONSerialization.data(withJSONObject: record)
        else { return }

        defaults.set(json, forKey: snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
