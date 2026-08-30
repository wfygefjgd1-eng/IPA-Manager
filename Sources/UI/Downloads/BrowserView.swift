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
    /// 当前 toast 的自动隐藏任务：新 toast 先取消旧的，避免前一条的计时器
    /// 提前把新 toast 藏掉（裸 asyncAfter 互不取消的互踩问题）
    @State private var toastWorkItem: DispatchWorkItem?

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
                // Safari 风格地址栏：大号圆角胶囊 + 锁标识 + 加载指示，浅色底融入导航栏
            HStack(spacing: 8) {
                // 安全状态：https 显示锁，http 显示警示，加载中显示进度
                Group {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if urlString.lowercased().hasPrefix("https://") {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "lock.open")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.orange)
                    }
                }
                .frame(width: 16)

                TextField("搜索或输入网址", text: $urlString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        navigate(to: urlString)
                    }
                    .font(.footnote)
                    .foregroundColor(.primary)

                // 无内容时显示站点图标占位；有内容时显示清除按钮（Safari 同款）
                if urlString.isEmpty {
                    Image(systemName: "safari")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        urlString = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                Capsule()
                    .fill(Color(.systemGray5).opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            WebView(
                initialURL: initialURL,
                isLoading: $isLoading,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                onDownloadDetected: { url in
                    // 命中下载链接：不再弹确认框，直接开始下载并切到“下载”标签页
                    startDownload(url)
                },
                onURLChanged: { pageURL in
                    // 页面加载完成回写地址栏（WebView 不再监听 urlString 绑定：
                    // 旧实现地址栏逐键输入都会改变绑定并触发 updateUIView 的真实
                    // 导航——每个字符一次网络请求，还会覆盖用户正在输入的文本）
                    urlString = pageURL
                },
                onLoadFailed: { message in
                    showToastMessage(message, duration: 3)
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
                // 显式导航走通知（与后退/前进/刷新同一通道），不再依赖绑定变化
                NotificationCenter.default.post(name: .browserNavigate, object: url)
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
        } // NavigationView
    }

    /// 统一的 toast 展示：新 toast 取消上一个的隐藏计时器（避免互踩——
    /// 裸 asyncAfter 互不取消时，前一条的 3s 计时器会提前把新 toast 藏掉）。
    private func showToastMessage(_ message: String, duration: TimeInterval) {
        toastMessage = message
        showToast = true
        toastWorkItem?.cancel()
        let work = DispatchWorkItem {
            self.showToast = false
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            // 后退/前进：Safari 风格小圆点按钮，禁用时更淡
            Button {
                NotificationCenter.default.post(name: .browserGoBack, object: nil)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .disabled(!canGoBack)
            .opacity(canGoBack ? 1 : 0.35)
            .buttonStyle(.plain)

            Button {
                NotificationCenter.default.post(name: .browserGoForward, object: nil)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .disabled(!canGoForward)
            .opacity(canGoForward ? 1 : 0.35)
            .buttonStyle(.plain)

            Spacer()

            // 重新加载/停止：与 Safari 加载指示一致（加载中显示停止，否则显示刷新）
            Button {
                if isLoading {
                    NotificationCenter.default.post(name: .browserStopLoading, object: nil)
                } else {
                    NotificationCenter.default.post(name: .browserReload, object: nil)
                }
            } label: {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NotificationCenter.default.post(name: .browserOpenBrowser, object: nil)
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    private func startDownload(_ url: URL) {
        // 只允许 http/https；其它 scheme（data:/file:/javascript: 等）不建下载任务
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            showToastMessage("仅支持 http/https 链接下载", duration: 2)
            return
        }
        Logger.info("开始下载: \(url.absoluteString)")

        // 防盗链：下载请求携带当前页面 URL 作 Referer（点击下载时 urlString 即来源页地址）
        let referer = urlString

        // 登录态（Cookie）共享：WKWebView 用 WKWebsiteDataStore 的 cookie 存储，
        // 而 URLSession 默认配置用 HTTPCookieStorage.shared，两者互相隔离——
        // 浏览器里登录 GitHub/网盘后点下载，URLSession 不带登录 cookie 会 302 到登录页，
        // 下载到的就是 HTML 错误页。这里先把浏览器会话的全部 cookie 同步进共享存储。
        // getAllCookies 回调线程不定，同步完成后再回主线程发起下载
        // （DownloadManager 的模型/持久化约定在主队列读写）。
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let shared = HTTPCookieStorage.shared
            for cookie in cookies {
                shared.setCookie(cookie)
            }
            DispatchQueue.main.async {
                DownloadManager.shared.startDownload(
                    urlString: url.absoluteString,
                    referer: referer
                ) { _ in
                    Logger.info("下载任务已创建")
                }
                // 不再设置"开始下载：xxx"toast：紧随其后的 dismiss 会销毁本视图，
                // toast 根本来不及显示（切到下载 Tab + 任务出现即是反馈）
                // 下载已加入队列：关闭浏览器并切到“下载”标签页
                self.appState.selectedTab = 2
                self.dismiss()
            }
        }
    }

    /// 地址栏提交：规范化 URL 并导航（补全缺省 https:// 前缀；只接受 http/https）。
    /// 导航走 .browserNavigate 通知（与后退/前进/刷新同一通道）——地址栏文本变化
    /// 本身绝不触发 WebView 导航（逐键导航是历史缺陷：每敲一个字符发一次真实
    /// 网络请求，还会把中间态 URL 加载成 404 并覆盖正在输入的文本）。
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
            showToastMessage("仅支持 http/https 网址", duration: 2)
            return
        }
        urlString = url.absoluteString
        NotificationCenter.default.post(name: .browserNavigate, object: url)
    }

    private func addCurrentPageToBookmarks() {
        let ok = BookmarkStore.shared.addCurrentPage(urlString)
        showToastMessage(ok ? "已添加到我的书签" : "当前页面无法收藏", duration: 2)
    }
}

extension Notification.Name {
    static let browserNavigate = Notification.Name("browserNavigate")
}

extension Notification.Name {
    static let browserGoBack = Notification.Name("browserGoBack")
    static let browserGoForward = Notification.Name("browserGoForward")
    static let browserOpenBrowser = Notification.Name("browserOpenBrowser")
    static let browserReload = Notification.Name("browserReload")
    static let browserStopLoading = Notification.Name("browserStopLoading")
}

private struct WebView: UIViewRepresentable {
    /// 初始 URL（仅 makeUIView 时加载一次）。导航统一走 .browserNavigate 通知，
    /// 不再持有 urlString 绑定——绑定会让地址栏每次键入都触发 updateUIView
    /// 里的真实导航（历史缺陷）。
    let initialURL: URL?
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var onDownloadDetected: (URL) -> Void
    /// 页面加载完成后回写地址栏文本（页面 URL 与地址栏同步）
    var onURLChanged: (String) -> Void
    /// 加载失败回调（向用户展示中文提示，替代仅写日志的静默失败）
    var onLoadFailed: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // 初始页：外部传入的 URL，无传入时回落默认主页（与 urlString 的初始值一致）
        if let url = initialURL ?? URL(string: "https://github.com") {
            context.coordinator.currentURL = url
            webView.load(URLRequest(url: url))
        }

        context.coordinator.attach(webView: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 导航不在这里触发：地址栏编辑文本与导航请求已分离（.browserNavigate
        // 通知），body 重算时不再对比 URL 发起 load
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
                    forName: .browserReload,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.reload()
                }
            )
            notificationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .browserStopLoading,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.stopLoading()
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
            notificationTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .browserNavigate,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    // 地址栏提交/书签选择的显式导航入口
                    guard let url = notification.object as? URL else { return }
                    self?.navigateTo(url)
                }
            )
        }

        /// 显式导航：更新 currentURL 并加载（仅由 .browserNavigate 通知触发）
        func navigateTo(_ url: URL) {
            currentURL = url
            webView?.load(URLRequest(url: url))
        }

        func goBack() {
            webView?.goBack()
        }

        func goForward() {
            webView?.goForward()
        }

        func reload() {
            webView?.reload()
        }

        func stopLoading() {
            webView?.stopLoading()
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
                // 页面最终地址回写地址栏（地址栏编辑不再触发导航，覆盖输入的
                // 风险仅剩"输入时页面恰好加载完成"的极小窗口）
                self.parent.onURLChanged(webView.url?.absoluteString ?? "")
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
            // 下载被 cancel（NSURLErrorCancelled）属于预期路径，不必记为错误。
            // WebKitErrorDomain Code=102（帧框加载已中断）也是下载导航被拦截后
            // WKWebView 的预期报错（下载任务已创建成功），同样不弹用户提示。
            let nsError = error as NSError
            let isExpected = nsError.code == NSURLErrorCancelled
                || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
            if !isExpected {
                // 用户可见提示：证书错误/断网等失败场景给明确反馈
                DispatchQueue.main.async {
                    self.parent.onLoadFailed("加载失败：\(error.localizedDescription)")
                }
                Logger.error("网页加载失败(临时): \(error)")
            }
        }

        // 拦截下载：只以 ipa/zip 扩展名命中（本应用要处理的格式）；releases/download
        // 仅在扩展名为空时兜底，避免把 release 详情页跳转等普通导航误判为下载。
        // .tar/.apk/.tar.gz 等不再在这里拦截——它们走 WebKit 导航/响应层下载，完成态
        // 由 DownloadManager.classifyDownload 判定（完整下载按 completed 收尾）。
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
            let isDownloadExt = ext == "ipa" || ext == "zip"
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
                // 与 decidePolicyFor 保持一致：只拦截 ipa/zip + releases/download 无扩展名兜底
                let isDownload = ext == "ipa" || ext == "zip"
                    || (ext.isEmpty && urlStr.contains("releases/download"))
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