# Palmarès iOS integration files

The Xcode project lives outside this repo; these files are written here so
they sync to the machine that has it. Each is self-contained and commented
with its own integration steps — this file is the map.

## What's here

| File | Target | Purpose |
| --- | --- | --- |
| `WidgetBridge.swift` | app | Receives the page's `widgetData` bridge message, writes it to the App Group, reloads widget timelines |
| `PalmaresWidget/PalmaresWidget.swift` | widget extension | The home screen widget (small + medium), drawn entirely from the page's snapshot |
| `HealthMetricsReader.swift` | app | HealthKit reader covering the original four metrics plus sleep and HRV trend for the coaching card |
| `EventReminders.swift` | app | Schedules local notifications for upcoming group rides (1h before + evening-before for morning rides) from the page's `eventReminders` message |
| `PullToRefresh.swift` | app | Native UIRefreshControl on the WKWebView wired to the page's `syncNow()`; disables the page's fallback JS pull-to-refresh via an injected flag |

## How the widget gets its data

```
index.html                      app target                   widget extension
updateWidgetData(patch)  ──►  WidgetBridge.handle()  ──►  PalmaresProvider
  (debounced snapshot          writes JSON to App           reads App Group,
   over palmaresNative)        Group + reloads              draws SwiftUI
```

The page is the single source of truth — the widget re-derives nothing, so
web and widget can never disagree. The snapshot updates whenever the app is
opened and the dashboard renders. The JS side is already live in
`index.html` (`updateWidgetData`, fed by `renderDashboard`,
`renderTodayCards`, and `loadClubEvents`) and is a silent no-op in a normal
browser.

## Widget setup (once, in Xcode)

1. **File → New → Target → Widget Extension.** Name it `PalmaresWidget`.
   Uncheck "Include Live Activity" and "Include Configuration App Intent".
2. Replace the generated `PalmaresWidget.swift` with the one from
   `PalmaresWidget/` here. Delete the rest of the generated boilerplate
   (bundle file included — this one declares its own `@main`).
3. Add `WidgetBridge.swift` to the **app** target.
4. **Signing & Capabilities → + App Groups** on **both** targets, same id.
   The code uses `group.com.kamildobrowolski.palmares` — namespaced under
   the app's bundle id, since App Group ids are globally unique across
   Apple and a bundle-prefixed one registers cleanly with automatic
   signing. If you change it, change it in both `WidgetBridge.swift` and
   `PalmaresWidget.swift` (`SnapshotStore.appGroupID`).
5. In `WebView.swift`'s `userContentController(_:didReceive:)`, route the
   new message types before the existing auth handling:

   ```swift
   if let body = message.body as? [String: Any] {
       switch body["type"] as? String {
       case "widgetData":     WidgetBridge.handle(body); return
       case "eventReminders": EventReminders.handle(body); return
       case "refreshDone":    PullToRefresh.shared.end(); return
       default: break
       }
   }
   ```

   `EventReminders.swift` needs no other setup — notification permission is
   requested on first use. `PullToRefresh.swift` additionally needs one line
   where the WKWebView is created: `PullToRefresh.shared.install(on: webView)`.
   Without it the page's own JS pull-to-refresh takes over, so older builds
   still work.

6. Run the app once (that first run writes the snapshot), then add the
   widget from the home screen gallery.

## Health metrics setup

`HealthMetricsReader.swift` supersedes what `HealthKitManager.swift` sends
today: same four fields (`vo2max`, `restingHR`, `hrvSDNN`, `age`), plus
`sleepHours`, `hrv7day`, and `hrv30day`. The page's coaching card turns the
new fields into morning-of recovery guidance (suppressed HRV → back off;
above-baseline HRV + positive form → green light; short sleep → keep it
aerobic). Old app builds that don't send them change nothing.

1. Add `HealthMetricsReader.swift` to the app target.
2. Where `HealthKitManager` currently pushes after page load
   (`webView(_:didFinish:)`), call instead — or additionally:

   ```swift
   HealthMetricsReader.push(into: webView)
   ```

3. Sleep analysis is a **new read type**: the first run after this change
   re-prompts Health authorization. `NSHealthShareUsageDescription` must
   already be in Info.plist from the existing integration; no change needed
   unless you want to mention sleep in the text.
4. Once it's confirmed working you can retire the overlapping reads in
   `HealthKitManager.swift`, or keep both — `receiveHealthData` stores
   whichever payload arrived last, and the reader sends a superset.

## WeatherKit

Server-side config, not an Xcode task — see `docs/weatherkit-setup.md`.
