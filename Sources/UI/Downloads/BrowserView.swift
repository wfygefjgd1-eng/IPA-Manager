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
                        Image(systemName: "bookmark.badge.plus")
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
            .overlay(alignment: .bottom) {
                if showToast {
                    Text(toastMessage)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 60)
                }
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
            toastMessage = "已加入下载"
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showToast = false
            }
        }
    }

    private func addCurrentPageToBookmarks() {
        guard !urlString.isEmpty, let _ = URL(string: urlString) else {
            toastMessage = "当前页面无法收藏"
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showToast = false
            }
            return
        }
        BookmarkStore.shared.addCurrentPage(urlString)
        toastMessage = "已收藏当前页面"
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
            webView.load(URLRequest(url: url))
        }

        subscribeActions(for: webView, context: context)
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
        var currentURL: URL?

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
            let isDownloadExt = ext == "ipa" || ext == "zip" || ext == "tar" || ext == "tar.gz" || ext == "apk"
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
                let isDownload = ext == "ipa" || ext == "zip" || ext == "tar" || ext == "tar.gz" || urlStr.contains("releases/download")
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