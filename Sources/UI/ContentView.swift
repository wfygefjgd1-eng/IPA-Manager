import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)

            AppsView()
                .tabItem {
                    Label("已签应用", systemImage: "apps.iphone")
                }
                .tag(1)

            DownloadsView()
                .tabItem {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .tag(2)

            CertificatesView()
                .tabItem {
                    Label("证书", systemImage: "lock.shield")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(4)
        }
        // 统一浮层：一条龙进度弹窗（导入→签名→安装）与全局 toast 同挂一个容器、
        // 垂直排布，置于屏幕中央（用户要求：处理状态一眼可见，不再沉在底部被拇指遮挡）。
        // 导入进度卡与自动流水线卡合并为一张弹窗：旧版两张独立黑胶囊在导入→签名
        // 交接时一消一现还会闪空一帧；合并后总百分比、计时、步骤指示器全程连续。
        .overlay(alignment: .center) {
            VStack(spacing: 8) {
                if let display = pipelineDisplay {
                    PipelineProgressCard(
                        display: display,
                        startedAt: appState.pipelineStartedAt
                    )
                }
                if let message = appState.toastMessage {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .foregroundColor(.white)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.toastMessage)
        .animation(.easeInOut(duration: 0.25), value: appState.importProgress)
        .animation(.easeInOut(duration: 0.25), value: appState.autoPipelineStatus)
        .onChange(of: scenePhase) { phase in
            // 回前台兜底扫描的主触发点：iOS 27 实测不再回调 UIApplicationDelegate 的
            // applicationDidBecomeActive（冷启动有投递日志而回前台扫描无记录），而
            // SwiftUI 场景通道（onOpenURL/scenePhase）实测可用。AppDelegate 的
            // applicationDidBecomeActive 里保留同一扫描（旧系统兜底），扫描内部去重。
            guard phase == .active else { return }
            ExternalDeliveryJournal.record("scenePhase → active（回前台）")
            appState.processInboxFilesIfNeeded()
            // 迟到投递保险：极少数场景系统在激活之后才完成文件拷贝，2.5 秒后复查一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                appState.processInboxFilesIfNeeded()
            }
            // 大包慢拷贝兜底：Safari/文件 App 投递大包时系统拷贝可能超过 2.5s，
            // 与 AppDelegate 暖启动 10s 复查对称，去重机制保证不重复导入
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                appState.processInboxFilesIfNeeded()
            }
        }
    }

    /// 把导入进度与自动流水线状态合成为一条龙弹窗显示模型。
    /// 整体百分比权重（PipelineOverallWeight）：导入 0–50%、签名 50–95%、
    /// 发起安装 95–100%——各阶段内部仍是真实进度（解压按字节、签名按 zsign 回报），
    /// 安装确认由系统弹窗接管，不纳入本百分比。
    private var pipelineDisplay: PipelineDisplay? {
        if let p = appState.importProgress {
            return PipelineDisplay(
                title: p.fileName,
                stage: .importing,
                phase: p.phase,
                detail: p.totalCount > 1 ? "第 \(p.currentIndex)/\(p.totalCount) 个文件" : "",
                overall: p.progress * PipelineOverallWeight.importShare
            )
        }
        guard let pipeline = appState.autoPipelineStatus else { return nil }
        switch pipeline.stage {
        case .signing:
            return PipelineDisplay(
                title: pipeline.appName,
                stage: .signing,
                phase: pipeline.phase,
                detail: pipeline.detail,
                overall: PipelineOverallWeight.signStart
                    + (pipeline.progress ?? 0) * PipelineOverallWeight.signRange
            )
        case .installLaunching:
            return PipelineDisplay(
                title: pipeline.appName,
                stage: .installLaunching,
                phase: pipeline.phase,
                detail: pipeline.detail,
                overall: PipelineOverallWeight.installLaunch
            )
        case .installInitiated:
            return PipelineDisplay(
                title: pipeline.appName,
                stage: .installInitiated,
                phase: pipeline.phase,
                detail: pipeline.detail,
                overall: 1.0
            )
        }
    }
}

/// 一条龙弹窗显示模型（导入/签名/安装三阶段统一视图）
struct PipelineDisplay: Equatable {
    enum Stage: Equatable {
        case importing
        case signing
        case installLaunching
        case installInitiated
    }
    let title: String
    let stage: Stage
    /// 当前阶段文字（解压转换中… / 正在签名… / 安装已发起 等）
    let phase: String
    /// 次要说明（多文件序号、zsign 阶段明细、系统弹窗指引等）
    let detail: String
    /// 整体进度 0~1（跨阶段加权合成）
    let overall: Double
}

/// 一条龙进度弹窗（胶囊造型，字号与旧版进度胶囊一致）：左侧圆环实时总百分比
/// （环随进度描边、百分比居中）+ 文件名/阶段 + 渐变进度条（带 50%/95% 阶段分界
/// 刻度）+「导入 → 签名 → 安装」步骤指示器 + 右下角 0.1 秒精度的已用时间
/// （随弹窗一起消失）。
private struct PipelineProgressCard: View {
    let display: PipelineDisplay
    /// 计时起点（导入开始时刻）；nil 时理论不可达（状态置值前已登记起点），兜底显示 --
    let startedAt: Date?

    private enum StepState { case done, active, pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：圆环总百分比 + 文件名 + 阶段/明细
            HStack(spacing: 12) {
                progressRing
                VStack(alignment: .leading, spacing: 3) {
                    Text(display.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        // 发起安装阶段无可靠进度：转圈示意通道建立中
                        if display.stage == .installLaunching {
                            ProgressView()
                                .scaleEffect(0.55)
                        }
                        Text(display.phase)
                        if !display.detail.isEmpty {
                            Text("· \(display.detail)")
                                .opacity(0.85)
                        }
                    }
                    .font(.caption2)
                    .opacity(0.85)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)

            // 第二行：渐变进度条 + 阶段分界刻度（50% 签名起点 / 95% 安装起点）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(
                            colors: stageColors,
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(10, geo.size.width * CGFloat(display.overall)))
                    stageTick(at: PipelineOverallWeight.signStart, barWidth: geo.size.width)
                    stageTick(at: PipelineOverallWeight.installLaunch, barWidth: geo.size.width)
                }
            }
            .frame(height: 5)
            .animation(.linear(duration: 0.2), value: display.overall)

            // 第三行：步骤指示器（左）+ 已用时间（右，0.1s 精度随弹窗一起消失）
            HStack(spacing: 6) {
                stepIndicator
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(elapsedText(at: context.date))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(Capsule().fill(Color.black.opacity(0.8)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .frame(maxWidth: 340)
    }

    // MARK: - 圆环总百分比

    /// 左侧圆环：底环 + 随整体进度描边的渐变环 + 居中小号百分比
    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: CGFloat(display.overall))
                .stroke(
                    LinearGradient(colors: stageColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int((display.overall * 100).rounded()))%")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundColor(.white)
        }
        .frame(width: 40, height: 40)
        .animation(.linear(duration: 0.2), value: display.overall)
    }

    /// 阶段分界刻度：画在进度条轨道上的短竖线，标出阶段权重的接缝位置
    private func stageTick(at fraction: Double, barWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.4))
            .frame(width: 1.5, height: 5)
            .offset(x: barWidth * CGFloat(fraction))
    }

    // MARK: - 步骤指示器

    /// 步骤指示器：导入 → 签名 → 安装（已完成打勾、进行中高亮、未开始置灰）
    private var stepIndicator: some View {
        HStack(spacing: 5) {
            step(icon: "square.and.arrow.down.fill", label: "导入", state: stepState(column: 0))
            connector
            step(icon: "hammer.fill", label: "签名", state: stepState(column: 1))
            connector
            step(icon: "arrow.down.app.fill", label: "安装", state: stepState(column: 2))
        }
    }

    private func stepState(column: Int) -> StepState {
        switch display.stage {
        case .importing:
            return column == 0 ? .active : .pending
        case .signing:
            if column == 0 { return .done }
            return column == 1 ? .active : .pending
        case .installLaunching:
            return column < 2 ? .done : .active
        case .installInitiated:
            return .done
        }
    }

    private func step(icon: String, label: String, state: StepState) -> some View {
        HStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(fillColor(for: state))
                    .frame(width: 14, height: 14)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.white.opacity(state == .active ? 1 : 0.55))
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(state == .pending ? 0.45 : 0.9))
        }
    }

    private func fillColor(for state: StepState) -> Color {
        switch state {
        case .done: return Color(red: 0.16, green: 0.72, blue: 0.45)
        case .active: return Color(red: 0.35, green: 0.55, blue: 1.0)
        case .pending: return Color.white.opacity(0.16)
        }
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 10, height: 1.5)
    }

    // MARK: - 阶段配色

    /// 当前阶段的渐变配色：导入/签名蓝青，安装阶段绿色
    private var stageColors: [Color] {
        switch display.stage {
        case .importing, .signing:
            return [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.40, green: 0.85, blue: 1.0)]
        case .installLaunching, .installInitiated:
            return [Color(red: 0.10, green: 0.70, blue: 0.45), Color(red: 0.32, green: 0.85, blue: 0.55)]
        }
    }

    // MARK: - 计时

    /// 已用时间：从导入开始计时，精确到 0.1 秒；随弹窗消失而停止展示。
    private func elapsedText(at date: Date) -> String {
        guard let startedAt = startedAt else { return "已用时 --" }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        return String(format: "已用时 %.1fs", elapsed)
    }
}
