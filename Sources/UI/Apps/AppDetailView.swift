import SwiftUI

struct AppDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let app: AppInfo

    @State private var showShareSheet = false
    @State private var showSignOptions = false
    @State private var showInstallCertificatePicker = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isSigning = false
    @State private var signProgress: Double = 0
    /// 本次会话中签名完成后的输出路径，用于在详情页实时反映“已签名”状态
    @State private var signedOutputPath: String?
    /// 签名完成弹窗：true 表示签名已成功并已发起安装
    @State private var showSignedAlert = false
    /// 签名完成后是否已自动安装（决定弹窗文案与“返回”行为）
    @State private var signedDidInstall = false
    /// 删除二次确认
    @State private var showDeleteConfirm = false
    /// 进度节流：仅当变化 ≥1% 或距离上次更新 ≥0.1s 才写入 @State
    @State private var lastProgressUpdate = Date.distantPast
    /// 签名中禁止关闭详情页
    @State private var closeLocked = false
    /// 当前签名阶段文字（"正在解压…/正在签名主程序…/正在重新打包…"），
    /// 由 SigningEngine 回调透传，与进度条同步刷新。
    @State private var signPhase = ""
    /// 签名开始时间：用于计算"已用/预计剩余"时间显示。
    @State private var signStartTime: Date?
    /// 刷新时间显示的定时器（已用/剩余秒数需要独立于进度回调持续更新；
    /// 进度数值由 smoother 推进，但时间也要随真实时钟走）。
    @State private var signTimer: Timer?
    /// 当前已用秒数（显示用，随 signTimer 刷新）
    @State private var elapsedSeconds: Int = 0
    /// 预计剩余秒数（阶段感知估算，见 estimatedRemainingSeconds）
    @State private var etaSeconds: Int = 0
    /// 真实 85% 锚点时刻：zsign 只在 85% 回调"重新打包开始"，此后无中间进度；
    /// 展示进度由 smoother 蠕动（假值），ETA 必须基于此锚点而非假进度线性外推。
    @State private var repackStartTime: Date?
    /// 源文件是否缺失：仅在 onAppear/签名产物变化时检查一次。
    /// 旧实现把 FileManager.fileExists 直接写进 body 表达式，签名进度高频回调
    /// 期间 body 每次重算都 stat 磁盘。
    @State private var sourceFileMissing = false
    /// 手动签名模式（设置开关，默认关）：开启后 Bundle ID 行变为可点击进入编辑，
    /// 修改在本机记录，签名时经 zsign 重写包内 CFBundleIdentifier 生效
    @AppStorage("setting_manual_signing_mode") private var manualSigningMode = false
    /// Bundle ID 手动编辑弹窗（手动签名模式下出现）
    @State private var showBundleIDEditor = false

    /// 展示层使用的“实时”AppInfo：
    /// - 签名刚完成 → 以签名输出为准（合并原快照的元数据，isSigned = true，path 指向签名产物）；
    /// - 否则优先 importedApps 中 id 相同的最新副本，其次 installedApps 中 path 相同的条目；
    /// - 兜底使用传入快照。
    private var liveApp: AppInfo {
        if let signedPath = signedOutputPath,
           let installed = appState.installedApps.first(where: { $0.path == signedPath }) {
            var merged = app
            merged.isSigned = true
            merged.path = installed.path
            merged.signedPath = installed.path
            merged.size = installed.size
            return merged
        }
        if let imported = appState.importedApps.first(where: { $0.id == app.id }) {
            return imported
        }
        if let installed = appState.installedApps.first(where: { $0.path == app.path }) {
            return installed
        }
        return app
    }

    var body: some View {
        VStack(spacing: 0) {
            // 自定义导航栏：替代 NavigationView（sheet 内嵌 NavigationView 在 iOS16+ 已不推荐），
            // 保留“关闭”按钮与签名锁定逻辑，样式与原 navigationBar 一致
            HStack {
                Text("应用详情")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .disabled(closeLocked)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(.systemBackground).opacity(0.0001))

            Divider()

            headerSection
                .padding()

            Divider()

            infoList

            if isSigning {
                signingProgressView
            }

            actionButtons
                .padding()
        }
        .sheet(isPresented: $showSignOptions) {
            SignOptionsView(app: app) { cert, profile, installAfter in
                startSigning(certificate: cert, profile: profile, installAfter: installAfter)
            }
        }
        // 手动签名模式：Bundle ID 编辑弹窗（修改落库，签名时经 zsign 重写生效）
        .sheet(isPresented: $showBundleIDEditor) {
            BundleIDEditorView(app: liveApp)
        }
        .sheet(isPresented: $showInstallCertificatePicker) {
            InstallCertificatePicker { cert in
                do {
                    try appState.installApp(liveApp, certificate: cert)
                    alertMessage = "安装请求已发出"
                } catch {
                    alertMessage = error.localizedDescription
                }
                showAlert = true
            }
        }
        .sheet(isPresented: $showShareSheet) {
            // 用 fileURLWithPath 构造 URL，避免路径含空格/中文时分享失效
            ShareSheet(items: [URL(fileURLWithPath: liveApp.path)])
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        /// 签名完成弹窗：内容“签名完成，已发起安装”，旁边“确定”和“返回”两个按钮。
        // “返回”：关闭当前详情界面、切回首页 Tab，并挂起 App 直接回到 iOS 桌面（主屏幕）。
        // 若设置“签名完成自动返回桌面”开启（默认开），自动执行“返回”：已发起安装时
        // 锚定 itms-services open 成功后约 1.5 秒（见 startSigning 里的 onInstallOpened），
        // 未发起安装时从弹窗出现起约 1.5 秒；用户在此期间手动点了“确定”或“返回”则取消自动返回。
        .alert("签名完成", isPresented: $showSignedAlert) {
            Button("确定", role: .cancel) {
                cancelAutoReturnIfNeeded()
            }
            Button("返回") {
                cancelAutoReturnIfNeeded()
                performReturnHome()
            }
        } message: {
            Text(signedDidInstall ? "签名完成，已发起安装" : "签名完成，未自动安装")
        }
        .confirmationDialog(
            "删除后文件不可恢复，确定删除吗？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                appState.removeSignedApp(liveApp)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        // 签名进行中禁止下滑手势关闭详情页
        .interactiveDismissDisabled(isSigning)
        // 毛玻璃背景：infoList 已透明化，详情页同样铺渐变 + 半透明材质
        .background(GlassBackground().ignoresSafeArea())
        // 源文件存在性：出现时与签名产物变化时各检查一次（不在 body 内 stat 磁盘）
        .onAppear {
            refreshSourceFileExists()
        }
        .onChange(of: signedOutputPath) { _ in
            refreshSourceFileExists()
        }
        // 视图消失时停止签名时间显示定时器（切页/关闭后不得残留空转）
        .onDisappear {
            stopSignTimer()
            cancelAutoReturnIfNeeded()
        }
    }

    private func refreshSourceFileExists() {
        sourceFileMissing = !FileManager.default.fileExists(atPath: liveApp.path)
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            AppIconView(iconPath: liveApp.iconPath, size: 80)
                .frame(width: 80, height: 80)

            Text(liveApp.name.isEmpty ? "未命名" : liveApp.name)
                .font(.title2)
                .fontWeight(.semibold)

            if liveApp.isSigned {
                Label("已签名", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
            } else {
                Label("未签名", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
    }

    private var infoList: some View {
        List {
            bundleIDRow
            infoRow("版本", liveApp.version.isEmpty ? "未知" : liveApp.version)
            infoRow("构建号", liveApp.build.isEmpty ? "未知" : liveApp.build)
            infoRow("文件大小", liveApp.sizeDescription)
            infoRow("最低系统", liveApp.minimumOSVersion ?? "未知")
        }
        .listStyle(.insetGrouped)
        // 毛玻璃背景：隐藏 List 默认不透明底色，透出详情页的 GlassBackground
        .scrollContentBackground(.hidden)
    }

    /// Bundle ID 行：手动签名模式下可点击进入编辑（铅笔图标示意），
    /// 其余情况保持纯展示行。
    @ViewBuilder
    private var bundleIDRow: some View {
        if manualSigningMode {
            Button {
                showBundleIDEditor = true
            } label: {
                HStack {
                    Text("Bundle ID")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(liveApp.bundleID.isEmpty ? "未知" : liveApp.bundleID)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        } else {
            infoRow("Bundle ID", liveApp.bundleID.isEmpty ? "未知" : liveApp.bundleID)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var signingProgressView: some View {
        VStack(spacing: 6) {
            ProgressView(value: signProgress)
            HStack {
                // 阶段文字（"正在解压…/正在签名主程序…/正在重新打包…"）
                Text(signPhase.isEmpty ? "签名中…" : signPhase)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "%.0f%%", signProgress * 100))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            // 时间显示：已用 Xs · 预计剩余 Ys（进度 >0 才预估；完成即显示总用时）
            if signProgress >= 1.0 {
                Text("总用时 \(elapsedSeconds) 秒")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            } else {
                Text("已用 \(elapsedSeconds) 秒 · 预计剩余 \(etaSeconds) 秒")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // 该应用正在自动签名队列中（导入/下载完成的一条龙）：显示状态并禁用所有操作，
            // 避免用户手动点击与后台自动签名并发（zsign 并发不安全）。
            if appState.autoSigningAppIDs.contains(liveApp.id) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在自动签名并安装，请稍候…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.1))
                )
            } else {
                // 签名主操作：直接使用默认选中的有效证书 + 描述文件 + “签名后自动安装”开关一键签名并安装；
                // 默认证书/描述文件缺失或无效时才退回可选面板（SignOptionsView）。
                Button {
                    startSigningWithDefaults()
                } label: {
                    Label(liveApp.isSigned ? "重新签名并安装" : "开始签名并安装", systemImage: "pencil.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSigning
                          || appState.certificates.isEmpty
                          || appState.profiles.isEmpty
                          || sourceFileMissing)

                if liveApp.isSigned {
                    Button {
                        showInstallCertificatePicker = true
                    } label: {
                        Label("安装", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSigning)
                }

                Button {
                    showShareSheet = true
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // 源文件缺失时分享面板拿到的是不存在的 URL：各 activity 静默失败
                // 或产出空内容，与签名按钮禁用所暗示的"文件不可用"状态保持一致
                .disabled(isSigning || sourceFileMissing)

                Button(role: .destructive) {
                    // 删除是永久性磁盘操作，加二次确认，与全部清除一致的交互风格
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .disabled(isSigning)
            }
        }
    }

    /// 手动签名模式的 Bundle ID 覆盖：仅开关开启且记录非空时传递（空串 =
    /// 不覆盖，自动一条龙与常规签名路径不受影响）。这个名字是否生效由
    /// AppState.resolveSigningBundleIDOverride 决议：兼容原样传；不兼容与自动
    /// 模式同款传空（不重写包名），保证手动安装行为与自动一致。
    private var signingBundleIDOverride: String {
        manualSigningMode ? liveApp.bundleID.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// 一键签名并安装：默认选中的有效证书 + 描述文件（且仍在证书/描述文件列表中）+ AppStorage
    /// installAfterSigning（默认 true，未设置过时按 true 处理）直接签名并安装；
    /// 默认证书/描述文件缺失或无效时退回 SignOptionsView 让用户手动选择。
    /// 手动签名模式补充：默认描述文件与新改的 Bundle ID 不兼容时（精确绑定的
    /// 默认描述文件 + 库里另存通配描述文件的常见组合），自动改选任一条兼容的
    /// 有效描述文件并提示；库里没有兼容替代时也不拦——由 startSigning 内的
    /// resolveSigningBundleIDOverride 与自动模式同款兜底（不重写包名出包），
    /// 保证手动路径的签名/安装终态与自动路径一致。
    private func startSigningWithDefaults() {
        guard let cert = appState.selectedCertificate, cert.status == .valid,
              appState.certificates.contains(where: { $0.id == cert.id }) else {
            showSignOptions = true
            return
        }
        var chosenProfile = appState.selectedProfile
        let override = signingBundleIDOverride
        if !override.isEmpty, chosenProfile?.bundleIDOverrideError(override) != nil {
            if let candidate = appState.profiles.first(where: {
                $0.status == .valid && $0.bundleIDOverrideError(override) == nil
            }) {
                chosenProfile = candidate
                Logger.info("一键签名自动改选兼容描述文件: \(candidate.name)（默认描述文件与 Bundle ID \(override) 不兼容）")
                AppState.shared.showToast("默认描述文件与改后的 Bundle ID 不兼容，已自动改选「\(candidate.name)」")
            }
        }
        guard let profile = chosenProfile, profile.status == .valid,
              appState.profiles.contains(where: { $0.id == profile.id }) else {
            showSignOptions = true   // fallback 让用户选
            return
        }
        let installAfter = (UserDefaults.standard.object(forKey: "installAfterSigning") as? Bool) ?? true
        startSigning(certificate: cert, profile: profile, installAfter: installAfter)
    }

    private func startSigning(certificate: CertificateInfo, profile: ProvisioningInfo, installAfter: Bool) {
        isSigning = true
        closeLocked = true
        signProgress = 0
        signPhase = "准备中…"
        elapsedSeconds = 0
        etaSeconds = 0
        lastProgressUpdate = Date.distantPast
        // 重打包里程碑锚点：真实 85%（zsign 回调）到达时刻，用于阶段感知 ETA
        repackStartTime = nil
        // 启动时间显示：每 0.5s 刷新"已用/预计剩余"（进度由 smoother 推进，
        // 时间必须随真实时钟走，不能只依赖进度回调）
        signStartTime = Date()
        startSignTimer()
        // Bundle ID 覆盖决议（手动签名模式）：兼容即按用户改的名字（改名正规
        // 通道）；不兼容 → **与自动模式完全同款**传空覆盖（不重写包名出包），
        // 保证自动模式装得上的手动模式也一定装得上，不再弹「不兼容」拦签名。
        // 名称被放行未生效时 toast 说明，避免"改了名却没变"的困惑。
        let resolution = appState.resolveSigningBundleIDOverride(app: app, profile: profile)
        if resolution.usedFallback {
            AppState.shared.showToast("改的包名「\(resolution.incompatibleOverride)」与描述文件不兼容，本次按包内原包名签名（与自动模式一致）")
        }
        appState.signApp(app, certificate: certificate, profile: profile,
                         bundleIDOverride: resolution.override,
                         progress: { progress, phase in
            // 进度节流：变化 ≥1% 或间隔 ≥0.1s 才更新 @State，避免详情页频繁重算
            let now = Date()
            if abs(progress - signProgress) >= 0.01 || now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
                signProgress = progress
                lastProgressUpdate = now
            }
            if !phase.isEmpty {
                signPhase = phase
            }
            // 记录真实 85% 锚点：zsign 只在 85% 回调"重新打包开始"，此后无中间进度。
            // 展示进度由 smoother 蠕动（假值），ETA 不能基于它线性外推，必须用此锚点。
            if progress >= 0.85 && repackStartTime == nil {
                repackStartTime = now
            }
            // 阶段感知 ETA：委托给 ETACalculator
            if progress > 0 {
                if let start = signStartTime {
                    let elapsed = now.timeIntervalSince(start)
                    elapsedSeconds = Int(elapsed)
                    etaSeconds = estimatedRemainingSeconds(progress: progress, elapsed: elapsed, now: now)
                }
            }
        }, completion: { [self] result in
            stopSignTimer()
            switch result {
            case .success(let signedPath):
                isSigning = false
                closeLocked = false
                // 记录签名产物路径，供 liveApp 实时反映“已签名”状态（installedApps 会在回调前由 refreshInstalledApps 刷新）
                signedOutputPath = signedPath
                signedDidInstall = installAfter
                // 归正显示：进度 100% + 阶段"签名完成"（smoother 已归正，但兜底再设一次）
                signProgress = 1.0
                signPhase = "签名完成"
                if let start = signStartTime {
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
                etaSeconds = 0
                if installAfter {
                    do {
                        // “自动回桌面”锚定在 itms-services open 成功之后（onInstallOpened
                        // 主线程回调）：Installer 在后台要先完成服务器 ready 等待（≤5s）+
                        // 0.8s 探测 + manifest 预检才真正 open，若沿用“发起安装即起 1.5s”
                        // 的固定计时，App 会被先到的回桌面动作挂起，后台态 open 被系统忽略，
                        // 表现为“签名完成自动安装”静默失败（与自动一条龙路径
                        // autoSignAndInstallSucceeded 的修法一致）。
                        try appState.installSignedPath(signedPath, certificate: certificate) { [self] in
                            // “未开启自动返回开关不回桌面”“用户手动点确定/返回取消”
                            // 的判断都在 scheduleAutoReturnIfNeeded 内保留
                            scheduleAutoReturnIfNeeded()
                        }
                        // 弹窗仍立即弹出：installSignedPath 只同步做前置校验，open 及其
                        // 回调发生在后台（可能数秒后），不阻塞弹窗出现
                        showSignedAlert = true
                    } catch {
                        alertMessage = "签名完成，安装失败: \(error.localizedDescription)"
                        showAlert = true
                    }
                } else {
                    // 未自动安装也给出明确反馈（否则静默成功用户不确定是否完成）
                    showSignedAlert = true
                    // 未发起安装时也遵守开关：返回桌面让用户看到已完成的结果
                    scheduleAutoReturnIfNeeded()
                }
            case .failure(let error):
                isSigning = false
                closeLocked = false
                alertMessage = signingFailureMessage(for: error)
                showAlert = true
            }
        })
    }

    /// 启动时间显示定时器：每 0.5s 更新"已用秒数"，并在进度>0 时重算"预计剩余"。
    /// 与 smoother 的进度推进解耦——进度回调只负责推进百分比，这里负责真实时钟。
    private func startSignTimer() {
        stopSignTimer()
        signTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            guard let start = signStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            elapsedSeconds = Int(elapsed)
            // 进度未达 100% 时按阶段感知估算剩余；到达后归零（由 completion 兜底）
            if signProgress > 0 && signProgress < 1.0 {
                etaSeconds = estimatedRemainingSeconds(progress: signProgress, elapsed: elapsed, now: Date())
            } else if signProgress >= 1.0 {
                etaSeconds = 0
            }
        }
    }

    private func stopSignTimer() {
        signTimer?.invalidate()
        signTimer = nil
    }

    /// 阶段感知的预计剩余秒数估算。已抽取到 ETACalculator，保留方法做委托兼容
    private func estimatedRemainingSeconds(progress: Double, elapsed: TimeInterval, now: Date) -> Int {
        ETACalculator.estimatedRemainingSeconds(
            progress: progress,
            elapsed: elapsed,
            now: now,
            repackStartTime: repackStartTime,
            signStartTime: signStartTime
        )
    }

    // MARK: - 签名完成自动返回桌面（设置开关，默认开）

    /// 自动执行“返回”的延迟任务：已发起安装时在 itms-services open 成功回调里调度
    /// （App 此刻仍在前台，open 已被系统受理，延迟的只是回桌面动作），未发起安装时
    /// 在弹窗出现后调度；用户手动点了“确定/返回”即取消。
    /// 防止自动返回与用户手动操作重复触发（返回动作里会重新触发 dismiss，重复执行无害
    /// 但会闪跳，因此用标志位保证只执行一次）。
    @State private var autoReturnWorkItem: DispatchWorkItem?

    private func scheduleAutoReturnIfNeeded() {
        guard appState.autoReturnHomeAfterSigningEnabled() else { return }
        cancelAutoReturnIfNeeded()
        // SwiftUI View 是 struct：不能用 [weak self]（仅适用于 class）。DispatchWorkItem
        // 被 cancel 后不会执行（cancelAutoReturnIfNeeded 已保证），值捕获 self 安全，
        // 且闭包内只读写 @State（nonmutating set），不会产生循环引用。
        let work = DispatchWorkItem { [self] in
            // 弹窗仍在展示且用户未手动操作时自动“返回”
            if showSignedAlert {
                self.performReturnHome()
            }
        }
        autoReturnWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 用户手动点了“确定/返回”（含弹窗消失），取消待执行的自动返回。
    private func cancelAutoReturnIfNeeded() {
        autoReturnWorkItem?.cancel()
        autoReturnWorkItem = nil
    }

    /// 统一“返回”动作：关闭详情页、切回首页 Tab、挂起 App 回桌面（iOS 弹安装确认）。
    private func performReturnHome() {
        cancelAutoReturnIfNeeded()
        showSignedAlert = false
        dismiss()
        appState.selectedTab = 0
        // 挂起 App 回到 iOS 桌面（主屏幕）；App 保留在后台，点图标可恢复
        appState.minimizeToHomeScreen()
    }

    /// 当失败原因是“源文件丢失”时，在错误信息后附加一行恢复指引，
    /// 避免用户只看到 zsign 桥接层返回的 "Input file not found" 英文错误。
    /// AppError.signFailed 的 errorDescription 自带"签名失败: "前缀，这里
    /// 识别后不再叠加，避免出现"签名失败: 签名失败: …"的重复读感。
    private func signingFailureMessage(for error: Error) -> String {
        let description = error.localizedDescription
        let base = description.hasPrefix("签名失败: ") ? description : "签名失败: \(description)"
        if description.contains("文件已被删除") || description.contains("Input file not found") || description.contains("源文件") {
            return base + "\n\n该应用的源文件已丢失（可能被清理），请在首页重新导入后再签名。"
        }
        return base
    }
}

struct InstallCertificatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let onConfirm: (CertificateInfo) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("选择用于安装的证书") {
                    ForEach(appState.certificates) { cert in
                        // 过期证书置灰禁用但不从列表隐藏：用户需要看到“为什么不能选”，
                        // 隐藏会让人误以为证书丢了；选中过期证书发起安装必然被 iOS 拒绝。
                        Button {
                            onConfirm(cert)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                HStack(spacing: 6) {
                                    Text(cert.name)
                                        .foregroundColor(cert.status == .expired ? .secondary : .primary)
                                    if cert.status == .expired {
                                        Text("已过期")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(.red)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.red.opacity(0.12)))
                                    }
                                }
                                // 副标题补充禁用原因（status 由 expireDate 与当前时间比较得出）
                                Text(cert.status == .expired
                                     ? "到期: \(cert.expireDateDescription) · 已过期，无法用于安装"
                                     : "到期: \(cert.expireDateDescription)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(cert.status == .expired)
                    }
                }
            }
            .navigationTitle("安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 手动签名模式的 Bundle ID 编辑弹窗（默认关，入口仅在该模式开启时出现）。
/// 兼容性判定规则与签名时一致（ProvisioningInfo.bundleIDOverrideError，镜像
/// zsign/系统通配覆盖语义）。编辑器对【全部】有效描述文件做兼容性对比并展示
/// ✓/✗ + footer 论断，但【不拦截保存】：保存门槛只有"非空"（空 = 什么都没改，
/// 等效取消）——实测 v1.0.195 的"零兼容描述文件时禁保存"把「先改名、稍后再
/// 导入兼容描述文件 / 换证书」的正常路径也卡死；字符格式同样不拦，用户要的
/// 是"改完直接能存"，非法字符的代价出现在签名环节（引擎 fail-fast 给出精确
/// 原因），不在编辑环节设卡。修改只落本机记录，包内重写在下次签名时发生。
struct BundleIDEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let app: AppInfo

    @State private var draft = ""
    @State private var saveError: String?

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 字符白名单提示（纯信息展示，不拦截保存：非法字符由签名环节的引擎
    /// fail-fast 校验给出精确原因；放这里仅让用户提前看到"这样改签不成"）
    private var formatWarning: String? {
        ProvisioningInfo.bundleIDFormatError(trimmedDraft)
    }

    /// 有效描述文件（未过期）：兼容性判定的对比范围
    private var validProfiles: [ProvisioningInfo] {
        appState.profiles.filter { $0.status == .valid }
    }

    /// 能接受当前草稿的描述文件（兼容 = 签名成功可安装）
    private var compatibleProfiles: [ProvisioningInfo] {
        validProfiles.filter { $0.bundleIDOverrideError(trimmedDraft) == nil }
    }

    /// 允许保存的条件：输入非空即可直接保存（空 = 等效取消）。字符白名单与
    /// 描述文件兼容性一律不拦——用户要的是"改完直接能存"；兼容性按信息展示，
    /// 格式问题在签名环节由引擎 fail-fast 精确报出，编辑环节不设卡。
    private var canSave: Bool {
        !trimmedDraft.isEmpty
    }

    /// 兼容性展示行（Identifiable 包装：key path 不支持元组成员，ForEach 需走结构体 id）
    private struct CompatibilityRow: Identifiable {
        let profile: ProvisioningInfo
        let compatible: Bool
        var id: UUID { profile.id }
    }

    /// 兼容性展示：兼容在前，最多 6 条（证书包一导入可能挂几十条描述文件）
    private var displayProfileRows: [CompatibilityRow] {
        let rows = validProfiles.map { CompatibilityRow(profile: $0, compatible: $0.bundleIDOverrideError(trimmedDraft) == nil) }
        return Array((rows.filter { $0.compatible } + rows.filter { !$0.compatible }).prefix(6))
    }

    /// 兼容性 section 的 footer 结论（用户看得懂下一步怎么办）
    private var compatibilityFooter: String {
        if validProfiles.isEmpty {
            return "还没有可用描述文件：可以先保存（签名时会再次校验），或先到「证书」页导入描述文件。"
        }
        let defaultCompatible = appState.selectedProfile.map { selected in
            selected.status == .valid && compatibleProfiles.contains(where: { $0.id == selected.id })
        } ?? false
        if compatibleProfiles.isEmpty {
            if trimmedDraft == app.bundleID {
                return "这个名字不被当前任何描述文件接受（描述文件只认自己的 AppID，与这个应用的原始名无关）。签名不受影响：会按包内原包名出包（与自动模式完全一致，能装上）；但想改名生效，需要通配描述文件（application-identifier 以 * 结尾）或让证书供应商按此名字出一条精确描述文件。"
            }
            return "当前所有描述文件都无法接受这个 Bundle ID（多见于「每应用精确绑定」描述文件）。保存不受影响：签名时会按包内原包名出包（与自动模式完全一致，能装上），你改的这个名字那次签名不会生效。想让它生效需要：① 通配描述文件（可向证书供应商申请）；或 ② 让供应商直接按这个名字出一条精确描述文件。"
        }
        if defaultCompatible {
            return "默认描述文件兼容，可直接一键签名。"
        }
        return "默认描述文件不与改后的 ID 兼容：一键签名时会自动改选兼容的描述文件，也可在「签名选项」中手动选择。"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("com.example.myapp", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        // 弹窗再次出现时草稿始终对齐当前记录值（保存失败重开兜底）
                        .onAppear { if draft.isEmpty { draft = app.bundleID } }
                } header: {
                    Text("新的 Bundle ID")
                } footer: {
                    Text("仅修改本机记录；包内 Bundle ID 在下次点击「开始签名」时被重写（主程序与扩展一并修改）。原值：\(app.bundleID.isEmpty ? "未知" : app.bundleID)")
                }

                if let formatWarning {
                    Section {
                        Label(formatWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                        Text("此提示不拦保存；非法字符的名字在签名时会被拦下并说明原因")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    ForEach(displayProfileRows) { row in
                        HStack(spacing: 10) {
                            Image(systemName: row.compatible ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.subheadline)
                                .foregroundColor(row.compatible ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.profile.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(row.profile.bundleID.isEmpty ? "未知 AppID" : row.profile.bundleID)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if row.profile.id == appState.selectedProfile?.id {
                                Text("默认")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                        }
                    }
                    if validProfiles.count > displayProfileRows.count {
                        Text("…共 \(validProfiles.count) 条有效描述文件，其中 \(compatibleProfiles.count) 条兼容（仅展示前 6 条）")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("描述文件兼容性（哪个名字能签成）")
                } footer: {
                    Text(compatibilityFooter)
                }
            }
            .navigationTitle("修改 Bundle ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        let newID = trimmedDraft
        // 未发生变化：视为无操作，直接关闭（避免记一条无意义的修改日志）
        guard newID != app.bundleID else {
            dismiss()
            return
        }
        if appState.updateImportedAppBundleID(id: app.id, path: app.path, newBundleID: newID) {
            // 零兼容时说明签名行为（按包内原包名兜底、与自动模式一致），避免误解
            let zeroCompatible = !validProfiles.isEmpty && compatibleProfiles.isEmpty
            AppState.shared.showToast(zeroCompatible
                ? "Bundle ID 已保存；这个名字当前描述文件不认，下次签名会按包内原包名出包（与自动模式一致，不影响安装）"
                : "Bundle ID 已更新，签名时生效")
            dismiss()
        } else {
            saveError = "未找到对应的导入记录，无法保存修改（请从首页/待签名列表进入该应用后重试）"
        }
    }
}

struct SignOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let app: AppInfo
    let onConfirm: (CertificateInfo, ProvisioningInfo, Bool) -> Void

    @State private var selectedCert: CertificateInfo?
    @State private var selectedProfile: ProvisioningInfo?
    @AppStorage("installAfterSigning") private var installAfterSigning = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("签名后自动安装", isOn: $installAfterSigning)
                } footer: {
                    Text("开启后签名完成会自动调用安装")
                }

                Section("选择证书") {
                    if appState.certificates.isEmpty {
                        Text("还没有证书，请先在「证书」标签页导入 P12/zip 证书包")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(appState.certificates) { cert in
                            Button {
                                selectedCert = cert
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(cert.name)
                                            .foregroundColor(.primary)
                                        Text("到期: \(cert.expireDateDescription)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedCert?.id == cert.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("选择描述文件") {
                    if appState.profiles.isEmpty {
                        Text("还没有描述文件，请先在「证书」标签页导入 mobileprovision/zip 证书包")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(appState.profiles) { profile in
                            Button {
                                selectedProfile = profile
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(profile.name)
                                            .foregroundColor(.primary)
                                        Text("到期: \(profile.expireDateDescription)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedProfile?.id == profile.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("签名选项")
            .navigationBarTitleDisplayMode(.inline)
            // 打开弹窗时，若尚未手动选择，则默认勾选 AppState 中自动选中的默认证书/描述文件（存在且有效时）
            .onAppear {
                if selectedCert == nil,
                   let cert = appState.selectedCertificate,
                   cert.status == .valid,
                   appState.certificates.contains(where: { $0.id == cert.id }) {
                    selectedCert = cert
                }
                if selectedProfile == nil,
                   let profile = appState.selectedProfile,
                   profile.status == .valid,
                   appState.profiles.contains(where: { $0.id == profile.id }) {
                    selectedProfile = profile
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("开始签名") {
                        if let cert = selectedCert, let profile = selectedProfile {
                            onConfirm(cert, profile, installAfterSigning)
                            dismiss()
                        }
                    }
                    .disabled(selectedCert == nil || selectedProfile == nil)
                }
            }
        }
    }
}