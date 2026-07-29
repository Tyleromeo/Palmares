import SwiftUI
import WebKit
import UIKit   // UIAlertController / UIApplication for the WKUIDelegate dialogs

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
        // Without a uiDelegate, WKWebView silently swallows window.alert,
        // window.confirm and window.prompt - confirm() returns false and
        // prompt() returns nil immediately, with no dialog shown. Every
        // confirm-gated action in the page was therefore dead in the app:
        // Force full resync in particular looked like a button that did
        // nothing, because it did nothing. The page now uses its own in-page
        // dialogs, so this is a safety net for any native dialog that remains.
        webView.uiDelegate = context.coordinator
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
        // Native pull-to-refresh wired to the page's syncNow(). This also
        // re-enables vertical bounce (a refresh control is driven by the
        // overscroll, so it cannot fire without it) and injects
        // window.hasNativeRefresh, which switches off the page's own JS
        // pull-to-refresh so the two never both run.
        PullToRefresh.shared.install(on: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let js = pendingJS {
            webView.evaluateJavaScript(js, completionHandler: nil)
            DispatchQueue.main.async { pendingJS = nil }
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
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

        // MARK: - WKUIDelegate: JS dialogs
        // WKWebView shows none of these unless the host implements them.

        private func topViewController() -> UIViewController? {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var top = scene?.keyWindow?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard let vc = topViewController() else { completionHandler(); return }
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            vc.present(a, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let vc = topViewController() else { completionHandler(false); return }
            let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            vc.present(a, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            guard let vc = topViewController() else { completionHandler(nil); return }
            let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            a.addTextField { $0.text = defaultText }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(a.textFields?.first?.text)
            })
            vc.present(a, animated: true)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "palmaresNative" || message.name == "eldoradoNative",
                  let body = message.body as? [String: Any] else { return }

            // Non-auth bridge messages, routed before the auth check because
            // every type shares the one palmaresNative channel:
            //   widgetData     - snapshot for the home screen widget
            //   eventReminders - upcoming rides to schedule notifications for
            //   refreshDone    - page finished the pull-to-refresh sync
            //   requestHealth  - setup asked to connect Apple Health
            switch body["type"] as? String {
            case "widgetData":
                WidgetBridge.handle(body)
                return
            case "eventReminders":
                EventReminders.handle(body)
                return
            case "refreshDone":
                PullToRefresh.shared.end()
                return
            case "requestHealth":
                // Triggered by the Connect Apple Health button in setup. Uses
                // the message's own web view so the reply lands in the page
                // that asked. HealthMetricsReader replies via
                // window.receiveHealthData, which refreshes the open sheet.
                if let wv = message.webView { HealthMetricsReader.push(into: wv) }
                return
            default:
                break
            }

            guard body["type"] as? String == "auth" else { return }
            athleteName = body["name"] as? String
        }
    }
}
