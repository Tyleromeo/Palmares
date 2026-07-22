import SwiftUI
import WebKit

// Wraps a single, persistent WKWebView so switching bottom tabs runs
// showSection('...') on the *same* page instance instead of reloading the
// whole site - the site keeps its loaded activities, scan progress, and
// login session exactly like it would in a normal browser tab.
struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var pendingJS: String?
    @Binding var isLoading: Bool
    @Binding var athleteName: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, athleteName: $athleteName)
    }

    func makeUIView(context: Context) -> WKWebView {
        // Flag the page as running inside the native app *before* any of its
        // own scripts execute, so its CSS hides the in-page top bar entirely
        // (a real native bar replaces it - see ContentView.swift) - a real
        // signal instead of guessing from viewport width, which WKWebView's
        // width doesn't always match "narrow phone browser".
        let config = WKWebViewConfiguration()
        // Both names are set on purpose. The app loads the *live* site, so a
        // freshly-built app can meet an older deployed page that still checks
        // the legacy flag - setting both means native detection works no
        // matter which side is pushed first (getting this wrong brings back
        // the double-top-bar bug). The isEldoradoNativeApp alias can be
        // deleted once the renamed site has been live for a while.
        let flagScript = WKUserScript(
            source: "window.isPalmaresNativeApp = true; window.isEldoradoNativeApp = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(flagScript)
        // The page calls notifyNativeAuthState(name) once login succeeds, so
        // the native top bar can show who's connected without duplicating
        // any of the page's own DOM/CSS.
        config.userContentController.add(context.coordinator, name: "palmaresNative")
        config.userContentController.add(context.coordinator, name: "eldoradoNative") // legacy alias, see above

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // Rubber-band overscroll let the in-page top bar look like it
        // "detached" and let page content scroll above it - WKWebView (like
        // mobile Safari) can visibly decouple position:fixed elements from
        // the viewport during the elastic bounce at the top/bottom of the
        // page. Kept here as a general scroll-feel improvement even though
        // the top bar itself is now native and immune to this.
        webView.scrollView.bounces = false
        // The page's own viewport meta tag asks for user-scalable=no, but
        // WKWebView doesn't always honor that - lock pinch-zoom natively too,
        // so rotating to landscape or a stray pinch never rescales the layout.
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let js = pendingJS {
            webView.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.async { pendingJS = nil }
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var isLoading: Bool
        @Binding var athleteName: String?
        init(isLoading: Binding<Bool>, athleteName: Binding<String?>) {
            _isLoading = isLoading
            _athleteName = athleteName
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
            // A fresh navigation (including a reload after disconnecting
            // Strava) means "connected" is no longer known to be true until
            // the page says so again.
            athleteName = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            // Superset health payload (adds sleepHours, hrv7day, hrv30day on
            // top of the original four) for the coaching card. Sent after the
            // page is ready so window.receiveHealthData exists; it lands last
            // and therefore wins over HealthKitManager's smaller payload.
            HealthMetricsReader.push(into: webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "palmaresNative" || message.name == "eldoradoNative",
                  let body = message.body as? [String: Any] else { return }

            // Widget snapshots from the page: persist to the App Group and
            // refresh the home screen widget. Routed before the auth check
            // because both types share the one bridge channel.
            if body["type"] as? String == "widgetData" {
                WidgetBridge.handle(body)
                return
            }

            guard body["type"] as? String == "auth" else { return }
            athleteName = body["name"] as? String
        }
    }
}
