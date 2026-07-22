//
//  PullToRefresh.swift
//  Palmares (app target)
//
//  Real UIRefreshControl on the WKWebView - the native rubber-band spinner
//  iOS users expect - wired to the page's syncNow(). The page also ships a
//  JS pull-to-refresh for builds without this file; installing this
//  injects window.hasNativeRefresh at documentStart, which the JS checks
//  so the two implementations can never both fire.
//
//  Integration (ios/README.md):
//    1. Add this file to the app target.
//    2. Where the WKWebView is created (WebView.swift makeUIView):
//         PullToRefresh.shared.install(on: webView)
//    3. In the bridge message router, add:
//         case "refreshDone": PullToRefresh.shared.end(); return
//
//  Flow: pull -> UIRefreshControl fires -> evaluate syncNowFromNative()
//  -> page syncs -> page posts {type:"refreshDone"} -> end() stops the
//  spinner. A 15s failsafe stops it even if the page never answers
//  (e.g. an older deployed page without syncNowFromNative).
//

import WebKit
import UIKit

final class PullToRefresh: NSObject {

    static let shared = PullToRefresh()

    private weak var webView: WKWebView?
    private let control = UIRefreshControl()
    private var failsafe: Timer?

    func install(on webView: WKWebView) {
        self.webView = webView

        // Tell the page a native control exists BEFORE its scripts run,
        // so its JS pull-to-refresh stays dormant.
        let script = WKUserScript(
            source: "window.hasNativeRefresh = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(script)

        control.tintColor = UIColor(red: 0xC9/255, green: 0xA2/255, blue: 0x27/255, alpha: 1) // Palmarès gold
        control.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        webView.scrollView.refreshControl = control
    }

    @objc private func refreshPulled() {
        webView?.evaluateJavaScript(
            "window.syncNowFromNative ? window.syncNowFromNative() : null;",
            completionHandler: nil
        )
        failsafe?.invalidate()
        failsafe = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.end()
        }
    }

    /// Called from the bridge router on the page's refreshDone message.
    func end() {
        DispatchQueue.main.async { [weak self] in
            self?.failsafe?.invalidate()
            self?.failsafe = nil
            self?.control.endRefreshing()
        }
    }
}
