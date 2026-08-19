import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var urlString = "https://github.com"
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showBookmarks = false
    @State private var showDownloadAlert = false
    @State private var pendingDownloadURL: URL?
    @State private var showToast = false
    @State private var toastMessage = ""

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
                        addCurrentPageToBookmarks()
                    } label: {
                        Image(systemName: "plus")
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
            // 轻提示：收藏当前页面等操作结果
            .overlay(alignment: .bottom) {
                if showToast {
                    Text(toastMessage)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .foregroundColor(.white)
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showToast)
            .onAppear {
                showToast = false
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
                showBookmarks = true
            } label: {
                Image(systemName: "bookmark")
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
            Logger.info("下载任务已创建")
        }
        // 下载已加入队列：关闭浏览器并切到下载页
        appState.selectedTab = 2
        dismiss()
    }

    private func addCurrentPageToBookmarks() {
        let ok = BookmarkStore.shared.addCurrentPage(urlString)
        toastMessage = ok ? "已添加到我的书签" : "当前页面无法收藏"
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showToast = false
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
            context.coordinator.currentURL = url
            webView.load(URLRequest(url: url))
        }

        context.coordinator.attach(webView: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let target = URL(string: url),
              target.absoluteString != context.coordinator.currentURL?.absoluteString else { return }
        uiView.load(URLRequest(url: target))
        context.coordinator.currentURL = target
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        weak var webView: WKWebView?
        var currentURL: URL?

        /// block 版 NotificationCenter 观察者 token，deinit 时统一移除，避免悬垂指针
        private var notificationTokens: [NSObjectProtocol] = []

        init(parent: WebView) {
            self.parent = parent
        }

        deinit {
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
        }

        /// 绑定 webView 并注册通知（幂等，重复调用不会重复注册）
        func attach(webView: WKWebView) {
            self.webView = webView
            subscribeActions()
        }

        private func subscribeActions() {
            guard notificationTokens.isEmpty else { return }
            notificationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .browserGoBack,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.goBack()
                }
            )
            notificationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .browserGoForward,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.goForward()
                }
            )
            notificationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .browserOpenBrowser,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.openInBrowser()
                }
            )
        }

        func goBack() {
            webView?.goBack()
        }

        func goForward() {
            webView?.goForward()
        }

        func openInBrowser() {
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
            currentURL = webView.url
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

        // 拦截下载：匹配扩展名或 GitHub release/download 链接
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let urlStr = url.absoluteString.lowercased()
            let ext = url.pathExtension.lowercased()
            let isDownloadExt = ext == "ipa" || ext == "zip" || ext == "tar" || ext == "apk" || urlStr.hasSuffix(".tar.gz")
            let isReleaseDownload = urlStr.contains("releases/download")
            let isNewWindow = navigationAction.targetFrame == nil

            if isDownloadExt || isReleaseDownload || isNewWindow && isReleaseDownload {
                parent.onDownloadDetected(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        // 兜底：服务器响应的 MIME/文件名指示文件下载时也拦截
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
            let mimeIsDownload = mime.contains("zip") || mime.contains("octet-stream") || mime.contains("application/x-tar")

            if !navigationResponse.canShowMIMEType || mimeIsDownload {
                if let url = navigationResponse.response.url {
                    parent.onDownloadDetected(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // 新窗口打开（target=_blank）统一在当前浏览器打开
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                let urlStr = url.absoluteString.lowercased()
                let ext = url.pathExtension.lowercased()
                let isDownload = ext == "ipa" || ext == "zip" || ext == "tar" || urlStr.hasSuffix(".tar.gz") || urlStr.contains("releases/download")
                if isDownload {
                    parent.onDownloadDetected(url)
                    return nil
                }
                webView.load(navigationAction.request)
                return nil
            }
            return nil
        }
    }
}