# Palmarès

*Your training. Your records.*

A personal training-intelligence dashboard for cyclists, built on the Strava API.
It pulls your full activity history and turns it into power analysis, KOM and
Top 10 tracking, gear and streak stats, weather-aware ride planning, and route
building.

## Structure

The two product surfaces have separate static entry points:

- **`index.html`** is the desktop/larger-screen website.
- **`ios.html`** is the phone experience loaded by the native iOS wrapper.

Each currently contains its own markup, styles, and application JavaScript.
There is no build step, no bundler, and no `package.json`. Shared service
contracts, storage keys, and native bridge messages must remain compatible,
but layout and interaction changes should be made in the intended surface
rather than copied automatically to both.

`privacy.html` is the privacy policy that the Strava API terms require a
registered application to publish.

`PalmaresApp/` is the Xcode project for the iOS app — a WKWebView wrapper
around `ios.html`, plus a home screen widget. `ios/` holds reference copies
of its Swift files, and `docs/` covers server-side setup.

**Before editing, read [CONTRIBUTING.md](CONTRIBUTING.md).** This project is
worked on from two machines and has no build or test suite; that file covers
the sync workflow, how to verify a change, and the deliberate decisions that
shouldn't be undone.

## The five sections

| Section | What it does |
| --- | --- |
| **Today** | The daily view — training readiness, today's opportunity, upcoming club events |
| **Train** | Power curve, zone distribution, year-over-year totals, goals, aero analysis |
| **Palmarès** | Complete KOM and Top 10 history, built from a full scan of every activity |
| **Scout** | Where to ride — tailwind segments, segment-hunter map, route builder, road reports, forecast |
| **Log** | Activity history, heatmap, ride-crew collaborators, gear mileage, streaks |

## Running it

It is a static file, but it must be **served over http** rather than opened via
`file://` — the Strava OAuth redirect will not complete from a `file://`
origin. Any static server works:

```sh
python3 -m http.server 8000
# then open http://localhost:8000
```

Without authentication you will only reach the "Connect with Strava" screen.

## Data and storage

All data stays in the browser. Tokens, settings, and cached API responses live
in `localStorage` under `ed_*` keys (`ed_access_token`, `ed_settings`,
`ed_collapsed`, …). There is no backend and no server-side storage.

> The `ed_` prefix is a holdover from the app's former name. **Do not rename
> these keys** — changing them signs the user out and discards every cached
> activity and setting.

## External services

- **Strava API** — activities, segments, clubs, gear, athlete profile
- **Apple WeatherKit**, **weather.gov**, **Open-Meteo** — forecast and wind
- **Mapbox**, **Leaflet** + **leaflet.heat** — map tiles and heatmaps
- **OSRM** (`router.project-osrm.org`) — route snapping
- **Open-Elevation** — elevation profiles
- **SBRA** — local road and group-ride reports

Chart.js 4.4.0 and Leaflet 1.9.4 are loaded from CDN.

## iOS wrapper

The dedicated `ios.html` surface is wrapped in a native iOS WebView. It talks
to Swift over `window.webkit.messageHandlers.palmaresNative`, and sets a
`native-app` body class when `window.isPalmaresNativeApp` is present.

Both checks fall back to the older `eldoradoNative` / `isEldoradoNativeApp`
names so that a freshly deployed page still works against an installed app
build that predates the rename. Keep the fallbacks until every such build is
retired.

## Editing

Because there is no web build step, check the script in whichever surface you
edited:

```sh
PAGE=index.html # or ios.html
START=$(grep -n '^<script>$' "$PAGE" | tail -1 | cut -d: -f1)
END=$(awk -v s="$START" 'NR>s && /^<\/script>/{print NR; exit}' "$PAGE")
sed -n "$((START+1)),$((END-1))p" "$PAGE" > /tmp/main.js
node --check /tmp/main.js
```
