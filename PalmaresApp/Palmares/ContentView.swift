import SwiftUI

// The five bottom tabs map to showSection('...') calls already defined in
// the site's own JS - no native navigation logic duplicated here. Everything
// else (Gear, Weather, Goals, Zones, Collaborators) stays reachable through
// the site's own in-page nav. Settings is the one exception: it gets a
// dedicated button in the native top bar below, since that bar is what
// replaced the site's now-hidden in-page top nav (see the note on
// WebView.swift and the body.native-app CSS rule for why).
private struct PalmaresTab {
    let title: String
    let icon: String
    let section: String
}

// Cockpit layout: Today answers "what matters right now", the other four
// are rooms of depth. Section names stay the site's historical internal ids.
private let tabs: [PalmaresTab] = [
    PalmaresTab(title: "Today", icon: "sun.max.fill", section: "dashboard"),
    PalmaresTab(title: "Scout", icon: "map.fill", section: "map"),
    PalmaresTab(title: "Train", icon: "chart.line.uptrend.xyaxis", section: "performance"),
    PalmaresTab(title: "Palmarès", icon: "flag.checkered", section: "segments"),
    PalmaresTab(title: "Log", icon: "list.bullet.rectangle", section: "activities")
]

// Update this if the live site ever moves to a different URL.
private let siteURL = URL(string: "https://palmares-gilt.vercel.app")!

private let palmaresGold = Color(red: 0.788, green: 0.635, blue: 0.153) // #C9A227
private let palmaresBarBackground = Color(red: 0.086, green: 0.106, blue: 0.133) // #161b22

struct ContentView: View {
    @State private var pendingJS: String? = nil
    @State private var isLoading = true
    @State private var selectedTab = 0
    // Filled in by the page via a WKScriptMessageHandler once login succeeds
    // (see WebView.swift's Coordinator) - nil until then, and reset back to
    // nil on every fresh navigation/reload (e.g. disconnecting Strava).
    @State private var athleteName: String? = nil
    @StateObject private var healthKit = HealthKitManager()

    // The page defines window.receiveHealthData; the guard makes the call a
    // silent no-op if it ever runs against a stale cached page that predates
    // the True Age feature.
    private func healthInjectionJS(_ json: String) -> String {
        "window.receiveHealthData && window.receiveHealthData(\(json));"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Native top bar - lives outside the WKWebView entirely, so it
            // can never be scrolled over by page content. The site's own
            // in-page nav (position:fixed) repeatedly ended up covered by
            // page content during scroll no matter how that was hardened in
            // CSS (z-index, transform, disabling rubber-band bounce) -
            // WKWebView can visibly decouple fixed elements from the
            // viewport, and that's not something fixable from the web side.
            // A real native bar sidesteps the whole bug class instead of
            // continuing to fight it.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Palmarès")
                        .font(.custom("Georgia-Bold", size: 20))
                        .foregroundColor(palmaresGold)
                    Text("Your Training. Your Records.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
                if let name = athleteName {
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                Button(action: { pendingJS = "showSection('settings')" }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }
                .padding(.leading, 10)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(palmaresBarBackground)

            WebView(url: siteURL, pendingJS: $pendingJS, isLoading: $isLoading, athleteName: $athleteName)
                .overlay {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(1.4)
                    }
                }

            Divider()

            HStack(spacing: 0) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button(action: {
                        selectedTab = i
                        pendingJS = "showSection('\(tabs[i].section)')"
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: tabs[i].icon)
                                .font(.system(size: 20))
                            Text(tabs[i].title)
                                .font(.system(size: 10))
                        }
                        .foregroundColor(selectedTab == i ? Color.accentColor : .gray)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.bar)
        }
        .onAppear {
            healthKit.requestAndFetch()
        }
        .onChange(of: healthKit.payloadJSON) { json in
            if let json { pendingJS = healthInjectionJS(json) }
        }
        .onChange(of: isLoading) { loading in
            // Re-inject after every completed page load (reload, disconnect,
            // back/forward) - the page's in-memory copy of the health data
            // is gone after a navigation, and HealthKit won't re-publish on
            // its own.
            if !loading, let json = healthKit.payloadJSON {
                pendingJS = healthInjectionJS(json)
            }
        }
    }
}

#Preview {
    ContentView()
}
