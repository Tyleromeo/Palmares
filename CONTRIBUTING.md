# Working on Palmarès

Read this before editing. It exists because Palmarès is worked on from two
Macs — a desktop and a laptop — often with an AI assistant session on each,
and those sessions cannot see one another. Most of what follows is written
down because it has already gone wrong once.

## Start every session with a fetch

```sh
git fetch && git rev-list --left-right --count origin/main...HEAD
```

`0 0` means in sync. Anything else, reconcile **before** editing.

**Dropbox syncs the working files but not git state.** The folder can look
completely up to date while the repository is days behind, and the working
tree can be stale and dirty at the same time. Never judge freshness by file
timestamps — only `git fetch` tells the truth.

On 2026-07-21 the desktop was 8 commits behind while holding newer
uncommitted edits. By the next morning the two machines had genuinely
diverged, 16 commits against 9. That untangled easily only because Dropbox
had happened to carry the page edits across so both sides held the same work.
What did *not* survive were files one machine never committed. Don't count on
being lucky twice.

**Push when you finish a chunk, not at the end of the day.** A day of work
sitting unpushed on both machines simultaneously is exactly how the
divergence happened.

If both sides have moved, don't merge blind. Diff the working file against
the remote and look for what's genuinely missing — much of the apparent
divergence is usually the same work counted twice:

```sh
git show origin/main:index.html > /tmp/theirs.html
diff /tmp/theirs.html index.html
```

Preserve local commits on a dated branch before any reset.

## Verifying a change

There is no build, no bundler, and no test suite, so nothing will catch a
syntax error before it ships. After editing either product entry point, check
the script:

```sh
PAGE=index.html # or ios.html
START=$(grep -n '^<script>$' "$PAGE" | tail -1 | cut -d: -f1)
END=$(awk -v s="$START" 'NR>s && /^<\/script>/{print NR; exit}' "$PAGE")
sed -n "$((START+1)),$((END-1))p" "$PAGE" > /tmp/main.js
node --check /tmp/main.js
```

For logic changes — date handling, filters — copy the function into a scratch
Node script and run the actual scenario. That is the only form of testing
available.

For the iOS app:

```sh
cd PalmaresApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Palmares.xcodeproj -scheme Palmares \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## Deliberate decisions — please don't "fix" these

**Strava branding is intentionally minimal.** "Powered by Strava" is
*optional* under their brand guidelines — the wording is "all apps that
**choose to** display the Powered by Strava logo". It appears exactly once,
at the foot of Settings, the least-trafficked screen. It was previously
placed after every section so it rendered on all six screens, justified by a
comment claiming it was required on every screen; that was incorrect and was
removed.

What genuinely *is* required, and must stay:

- The official **Connect with Strava** button, used unmodified. Both it and
  the Powered-by logo are Strava's official assets embedded as base64.
  **Never redraw Strava's logo as inline SVG** — the guidelines explicitly
  forbid modifying their marks, and hand-rolled versions have crept in twice.
- The exact text **"View on Strava"** on every link back to Strava data.
- Strava's marks must never appear more prominently than the Palmarès
  wordmark, and nothing may imply Strava built or sponsors this app.

**`PullToRefresh.install()` sets `scrollView.bounces = true` on purpose.** A
`UIRefreshControl` is driven by elastic overscroll and can never fire without
it. `WebView.swift` used to disable bouncing to stop page content scrolling
over the in-page top bar; that bar is native now and immune. Installing the
native control also injects `window.hasNativeRefresh`, which switches off the
page's JS pull-to-refresh — so setting `bounces = false` again would leave the
app with **no** pull-to-refresh at all. `install()` owns that setting so a
later edit elsewhere can't silently break it.

**The App Group is `group.com.kamildobrowolski.palmares`**, in both
`WidgetBridge.swift` and `PalmaresWidget.swift`. They must match, or the
widget silently shows placeholder data.

**Leaflet and Mapbox are gone.** The map is MapKit JS. Don't reintroduce
Leaflet.

**Don't rename the `ed_*` localStorage keys.** They're a holdover from the
app's former name, but renaming them signs every user out and discards their
cached activities and settings.

## Architecture, briefly

The web pages are the brain; the native app supplies sensors and OS surfaces.
`index.html` is the larger-screen website. `ios.html` is a separate phone
surface loaded by the iOS wrapper, so each interface can evolve independently.
`ios.html` computes the native app's data and pushes snapshots over the
`palmaresNative` bridge; Swift persists them and draws OS-level UI. The
widget re-derives nothing, so web and widget can never disagree.

Both entry points deploy together, but changes to one file do not implicitly
change the other product. Data fixes that should apply everywhere must be
ported deliberately to both files. Bridge message shapes, `ed_*` storage
keys, authentication behavior, and backend action contracts are shared
compatibility boundaries and must not drift.

Bridge message types (`WebView.swift` routes them):

| Type | Handler | Purpose |
| --- | --- | --- |
| `auth` | `WebView.swift` | Who's connected, for the native top bar |
| `widgetData` | `WidgetBridge` | Snapshot for the home screen widget |
| `eventReminders` | `EventReminders` | Upcoming rides → local notifications |
| `refreshDone` | `PullToRefresh` | Page finished a pull-to-refresh sync |

`ios/` holds reference copies of the Swift files; the real target members
live in `PalmaresApp/`. **Keep both in sync when editing** — the two
notification/refresh files once existed only under `ios/`, never added to the
Xcode target, so the page sent `eventReminders` messages that nothing
listened for and ride reminders were silently dead.

## Outstanding

- **`fetch_url`** — not yet deployed to the Supabase function, so external
  ride calendars (SBRA) render as links rather than inline events. See
  [docs/edge-fetch-url.md](docs/edge-fetch-url.md). Confirmed still open on
  2026-07-22: the deployed function answers `{"error":"Unknown action:
  fetch_url"}`.

## Done, but recently enough to be worth stating

**WeatherKit is live.** Finished on the laptop 2026-07-22, after the desktop
last looked. All four secrets (`WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID`,
`WEATHERKIT_SERVICE_ID`, `WEATHERKIT_PRIVATE_KEY`) are set, and `get_weather`
returns `_source: "weatherkit"` with real Apple data. The site is no longer on
Open-Meteo, which now serves only as the fallback path and for ZIP geocoding.

The `sub` claim is the **App ID** `com.kamildobrowolski.palmares`, not a
separate Service ID — a Service ID was tried and was not what Apple wanted.
The capability also takes roughly 15 minutes to propagate after being enabled,
which makes a correct configuration look broken; `NOT_ENABLED` right after a
change means wait, not rewrite. Verify before changing anything here:

```sh
curl -s -X POST "$SUPABASE_URL/functions/v1/sync-strava" \
  -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" \
  -d '{"action":"get_weather","lat":40.86,"lon":-73.20}' | grep -o '_source[^,]*'
```

## The branding sweep must include `privacy.html`

The hand-drawn Strava mark has now crept in three times. The third was in
`privacy.html`, which survived the `index.html` cleanup because nobody grepped
it. Check every HTML file in the repo, not just the app page:

```sh
grep -rn "M15.387 17.944" --include=*.html .   # must return nothing
```
