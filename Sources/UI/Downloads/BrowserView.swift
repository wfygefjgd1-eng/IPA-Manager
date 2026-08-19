import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = "https://github.com"
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showBookmarks = false
    @State private var showDownloadAlert = false
    @State private var pendingDownloadURL: URL?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                WebView(
                    url: $urlString,
                    isLoading: $isLoading,
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward,
                    onDownloadDetected: { url in
                        pendingDownloadURL = url
                        showDownloadAlert = true
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                Divider()

                toolbar
            }
            .navigationTitle("浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showBookmarks = true
                    } label: {
                        Image(systemName: "bookmark")
                    }
                }
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarkView { url in
                    urlString = url.absoluteString
                    showBookmarks = false
                }
            }
            .alert("开始下载", isPresented: $showDownloadAlert) {
                Button("取消", role: .cancel) {}
                Button("下载") {
                    if let url = pendingDownloadURL {
                        startDownload(url)
                    }
                }
            } message: {
                Text(pendingDownloadURL?.absoluteString ?? "")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button {
                NotificationCenter.default.post(name: .browserGoBack, object: nil)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)

            Button {
                NotificationCenter.default.post(name: .browserGoForward, object: nil)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)

            Spacer()

            if isLoading {
                ProgressView()
            }

            Spacer()

            Button {
                NotificationCenter.default.post(name: .browserOpenBrowser, object: nil)
            } label: {
                Image(systemName: "safari")
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func startDownload(_ url: URL) {
        Logger.info("开始下载: \(url.absoluteString)")
        DownloadManager.shared.startDownload(urlString: url.absoluteString) { _ in
            // 下载完成后交由 AppState 处理
            Logger.info("下载任务已创建")
        }
    }
}

extension Notification.Name {
    static let browserGoBack = Notification.Name("browserGoBack")
    static let browserGoForward = Notification.Name("browserGoForward")
    static let browserOpenBrowser = Notification.Name("browserOpenBrowser")
}

private struct WebView: UIViewRepresentable {
    @Binding var url: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var onDownloadDetected: (URL) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        if let url = URL(string: url) {
            webView.load(URLRequest(url: url))
        }

        subscribeActions(for: webView, context: context)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func subscribeActions(for webView: WKWebView, context: Context) {
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goBack),
            name: .browserGoBack,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goForward),
            name: .browserGoForward,
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.openInBrowser),
            name: .browserOpenBrowser,
            object: nil
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        weak var webView: WKWebView?

        init(parent: WebView) {
            self.parent = parent
        }

        @objc func goBack() {
            webView?.goBack()
        }

        @objc func goForward() {
            webView?.goForward()
        }

        @objc func openInBrowser() {
            guard let url = webView?.url else { return }
            UIApplication.shared.open(url)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            self.webView = webView
            DispatchQueue.main.async {
                self.parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
                self.parent.url = webView.url?.absoluteString ?? ""
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
            Logger.error("网页加载失败: \(error)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let ext = url.pathExtension.lowercased()
            if ext == "ipa" || ext == "zip" || ext == "tar.gz" {
                parent.onDownloadDetected(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}