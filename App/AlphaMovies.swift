import SwiftUI
import WebKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

@main
struct AlphaMovies: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) var delegate
    @StateObject private var browser = MovieBrowser()
    @StateObject private var downloads = MovieDownloads.shared
    @State private var showDownloads = false

    var body: some Scene {
        WindowGroup {
            MovieWebView(browser: browser)
                .background(Color.black)
                .safeAreaInset(edge: .top) {
                    Button { showDownloads = true } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(8)
                }
                .sheet(isPresented: $showDownloads) { DownloadsView(downloads: downloads, webView: browser.webView) }
                .onReceive(downloads.$notice) { if !$0.isEmpty { showDownloads = true } }
                .onReceive(delegate.$destination.compactMap { $0 }) { url in
                    showDownloads = false
                    browser.webView.load(URLRequest(url: url))
                }
        }
    }
}

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate, ObservableObject {
    @Published private(set) var destination: URL?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().isAutoInitEnabled = false
            Messaging.messaging().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in
                if allowed { DispatchQueue.main.async { application.registerForRemoteNotifications() } }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Messaging.messaging().apnsToken = token
        Messaging.messaging().isAutoInitEnabled = true
        Messaging.messaging().token { token, _ in
            if let token { self.register(token) }
        }
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken token: String?) {
        guard messaging.apnsToken != nil, let token else { return }
        register(token)
    }

    private func register(_ token: String) {
        guard let url = URL(string: "wp-json/mkpush/v2/register-token", relativeTo: MovieBrowser.home)?.absoluteURL else { return }
        let fields = ["token": token, "source": "alphamovies-ios", "permission": "granted",
                      "package": Bundle.main.bundleIdentifier ?? ""]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                NSLog("Alpha Movies: push registration failed.")
            }
        }.resume()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler finish: @escaping (UNNotificationPresentationOptions) -> Void) {
        finish([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler finish: @escaping () -> Void) {
        let payload = response.notification.request.content.userInfo
        let url = ["url", "open_url", "click_url", "deeplink", "link"].lazy
            .compactMap { payload[$0] as? String }
            .compactMap { URL(string: $0) }
            .first { MovieBrowser.isMovieSite($0) }
        DispatchQueue.main.async {
            self.destination = url
            finish()
        }
    }
}

final class MovieBrowser: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    static let home = URL(string: "https://alphamovies.com.ng/")!
    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        webView.load(URLRequest(url: Self.home))
    }

    static func isMovieSite(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && ["alphamovies.com.ng", "www.alphamovies.com.ng"].contains(url.host?.lowercased() ?? "")
    }

    @objc private func reload() { webView.reload() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil && !action.shouldPerformDownload { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if ["whatsapp", "mailto", "tel", "sms"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else if action.shouldPerformDownload && Self.isMovieSite(webView.url ?? Self.home) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let header = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = header?.lowercased().hasPrefix("attachment") == true
        let isVideo = response.response.mimeType?.lowercased().hasPrefix("video/") == true
        decisionHandler(Self.isMovieSite(webView.url ?? Self.home) && isAttachment && isVideo ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MovieDownloads.shared.attach(download, webView: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MovieDownloads.shared.attach(download, webView: webView)
    }
}

struct MovieWebView: UIViewRepresentable {
    let browser: MovieBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
