import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var urlString: String
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showBookmarks = false
    @State private var showToast = false
    @State private var toastMessage = ""

    /// 外部传入的初始 URL（例如从书签跳转）；为 nil 时加载默认主页。
    let initialURL: URL?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
        // 有 initialURL 就作为初始页，否则回落到默认主页
        _urlString = State(initialValue: initialURL?.absoluteString ?? "https://github.com")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 地址栏：显示/输入 URL，回车导航；加载失败时有页内回调提示（见 Coordinator）
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        TextField("输入网址", text: $urlString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit {
                                navigate(to: urlString)
                            }
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                WebView(
                    url: $urlString,
                    isLoading: $isLoading,
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward,
                    onDownloadDetected: { url in
                        // 命中下载链接：不再弹确认框，直接开始下载并切到“下载”标签页
                        startDownload(url)
                    },
                    onLoadFailed: { message in
                        toastMessage = message
                        showToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            showToast = false
                        }
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
        // 只允许 http/https；其它 scheme（data:/file:/javascript: 等）不建下载任务
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            toastMessage = "仅支持 http/https 链接下载"
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showToast = false
            }
            return
        }
        Logger.info("开始下载: \(url.absoluteString)")
        DownloadManager.shared.startDownload(urlString: url.absoluteString) { _ in
            Logger.info("下载任务已创建")
        }
        // 轻提示（可选）：直接开始下载，不再弹任何确认框
        toastMessage = "开始下载：\(url.lastPathComponent)"
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showToast = false
        }
        // 下载已加入队列：关闭浏览器并切到“下载”标签页
        appState.selectedTab = 2
        dismiss()
    }

    /// 地址栏提交：规范化 URL 并导航（补全缺省 https:// 前缀；只接受 http/https）。
    /// 修改 urlString 会触发 WebView.updateUIView 中的 load。
    private func navigate(to raw: String) {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }

        // 缺 scheme 时默认补 https://（用户输入多了不带协议的域名/IP）
        if !candidate.lowercased().hasPrefix("http://"),
           !candidate.lowercased().hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        // 只允许 http/https；其它 scheme 一律拒绝并提示（避免 javascript:/file: 等异常导航）
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            toastMessage = "仅支持 http/https 网址"
            showToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.showToast = false
            }
            return
        }
        urlString = url.absoluteString
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
    /// 加载失败回调（向用户展示中文提示，替代仅写日志的静默失败）
    var onLoadFailed: (String) -> Void

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
                self.parent.onLoadFailed("页面加载失败：\(error.localizedDescription)")
            }
            Logger.error("网页加载失败: \(error)")
        }

        // 关键修复：provisional 阶段加载失败（证书错误 / 断网 / 被 .cancel 的下载导航）时
        // 复位 isLoading，否则工具栏 ProgressView 永远转圈（状态机不闭合）
        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.canGoBack = webView.canGoBack
                self.parent.canGoForward = webView.canGoForward
            }
            // 下载被 cancel 属于预期路径，不必记为错误
            if (error as NSError).code != NSURLErrorCancelled {
                // 用户可见提示：证书错误/断网等失败场景给明确反馈
                DispatchQueue.main.async {
                    self.parent.onLoadFailed("加载失败：\(error.localizedDescription)")
                }
                Logger.error("网页加载失败(临时): \(error)")
            }
        }

        // 拦截下载：以扩展名命中为主；releases/download 仅在扩展名为空时兜底，
        // 避免把 release 详情页跳转等普通导航误判为下载
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
            // 兜底：releases/download 且无扩展名（GitHub 有时不带扩展名重定向）
            let isReleaseDownload = ext.isEmpty && urlStr.contains("releases/download")
            let isNewWindow = navigationAction.targetFrame == nil

            if isDownloadExt || (isNewWindow && isReleaseDownload) {
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
                let isDownload = ext == "ipa" || ext == "zip" || ext == "tar" || urlStr.hasSuffix(".tar.gz")
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