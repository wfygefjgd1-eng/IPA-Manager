# IPA Manager

本地 IPA 签名与管理工具（iOS / SwiftUI）。所有签名均在设备本地完成，不上传任何文件；内置浏览器可直达 GitHub Releases / 各大 IPA 站点下载应用，导入后一键签名并安装到本机。

## 核心能力

- **本地签名**：基于 zsign（OpenSSL）在设备内完成 IPA 重签名，支持 P12 / PFX 证书 + mobileprovision 描述文件，或 zip 证书包一键导入。
- **一键签名并安装**：签名完成后自动发起安装（itms-services 本地通道），全程无需电脑。
- **内置浏览器**：浏览 GitHub Releases 或任意下载站，点击 .ipa/.zip 链接直接下载，无需复制链接。
- **断点续传下载**：下载任务支持暂停/恢复/断点续传，重启 App 后自动恢复。
- **已签应用管理**：浏览已安装/已签名的应用，支持分享、删除、清除全部。
- **多文件导入**：支持 IPA / ZIP（含 zip 内嵌 .ipa、.app 重打包）批量导入，自动识别应用信息并提取图标。
- **系统分享接收（分享扩展）**：分享面板应用行出现「IPA Manager」入口（类似 QQ 邮箱/ChatGPT 的第三方入口），任意 App 里分享 .ipa/.zip/证书文件一键接收，打开 App 自动导入并签名安装；同时保留文档类型投递（「拷贝到 IPA Manager」）双通道。
- **诊断报告**：一键导出完整诊断日志（中文 ERROR/INFO 级别），便于排障。

## 安装方式（网络要求）

- 支持任意网络环境：蜂窝网络、Wi-Fi、VPN（如 Loon/Shadowrocket 等）均可用，**无需关闭 VPN、无需连接 Wi-Fi**。
- 安装通道（manifest 与载荷分离，Feather 同款方案）：签名完成后生成**公网 HTTPS manifest**（api.palera.in/genPlist，仅描述应用元数据与下载地址），IPA 本体由本机回环 `http://127.0.0.1:<随机端口>` 以明文 HTTP 提供，数据不出设备；回环地址在任何网络（蜂窝/VPN）下对本机始终可达，因此**无需关闭 VPN、无需连接 Wi-Fi**，任何网络下均可成功下载并安装。
- 注：安装时系统会弹出“某某想要安装”的确认提示，这是 iOS 系统级安全确认（通用签名工具均无法绕过），点击“安装”后系统自动回到桌面并完成安装。

## 使用流程

1. **准备证书**：在“证书”标签页导入自己的 P12/PFX（若为 zip 证书包 zip 内含 p12 + 描述文件，导入尝试常见密码 `1`，失败请改在证书页手动输入密码导入）与 mobileprovision 描述文件；选择默认证书与描述文件。
2. **下载或导入应用**：在“下载”标签页浏览器中下载 .ipa/.zip；或在“首页”从文件 App 导入 / 用其他 App 的“打开方式”发送到本 App；也可以直接在微信 / QQ / 电报 / Safari / 文件等任意 App 里对 .ipa/.zip 文件点“分享”，选择“**IPA Manager**”（分享扩展入口，文件直接接收）或“**拷贝到 IPA Manager**”（文档投递入口），App 会自动导入并按第 3 步的“自动一条龙”签名安装。
3. **签名并安装**：进入应用详情，点击“签名并安装”；签名完成后弹窗提示“签名完成，已发起安装”，可点“确定”留在详情页，或点“返回”关闭详情页并回到桌面首页。默认开启“签名完成后自动返回桌面”，弹窗出现约 1.5 秒后自动回桌面（设置中可关）。
   - **自动一条龙**（默认开，设置中可关）：任意方式导入成功（首页导入 / 下载完成自动导入 / 外部打开）后，App 自动用默认证书签名并直接发起安装，完成后自动回桌面等 iOS 弹安装确认，无需手动点操作；未配置有效默认证书时自动跳过并保留手动入口。
   - 签名完成后也可点“安装”用指定证书重新发起安装、或“分享”导出 IPA。
4. **管理已签应用**：“已签应用”标签页查看签名产物，可删除或清除全部。

## 本地构建

### 前置要求

- macOS 14+，Xcode 15.2（构建脚本在 macos-14 镜像与本地均已验证）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- 网络可达 GitHub（下载 OpenSSL 3.3.2 源码）

### 步骤

```bash
# 1. 构建 OpenSSL 静态库（产物输出到 Vendor/openssl/{include,lib}，CI 已缓存此目录）
bash scripts/build-openssl.sh

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 用 Xcode 打开 IPA Manager.xcodeproj，选真机运行；
#    或命令行构建（与 CI 相同，产物为未签名 IPA）：
xcodebuild -project "IPA Manager.xcodeproj" \
  -scheme "IPA Manager" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="1.0.0" \
  CURRENT_PROJECT_VERSION="1" \
  build
```

### OpenSSL 构建约束（勿改动）

- 固定 OpenSSL 3.3.2，静态库（`no-shared`）；
- **不启用 legacy provider、不 install providers.h**（本工程不 include 它，避免链接触发缺失头文件）；
- 仅 iOS 真机 arm64（`ios64-xcrun`）；测试/示例/应用禁用（`no-tests no-apps`）；
- **仅构建 libcrypto**（`make build_libcrypto`）：全库无任何 SSL_*/TLS_* 调用，不构建也不链接 libssl（工程链接项只有 `libcrypto-device.a`），节省约 25-30% 编译时间；
- 构建脚本 `scripts/build-openssl.sh` 为本地与 CI 共用入口；CI 的 OpenSSL 缓存 key 由 `hashFiles('scripts/build-openssl.sh')` 随脚本内容自动失效（脚本内容变化即自动换 key 重建），仅当脚本内容未变而需要强制重建时才手动修改 key 后的 `-v2` 后缀。

## 持续集成（CI）

- 推送 `main` 分支自动触发 GitHub Actions（`.github/workflows/build.yml`）：macos-14 + Xcode 15.2 构建未签名 IPA，产物上传为 Actions Artifact（`IPA-Manager-Build`，保留 14 天）。
- 版本号自动跟随运行号：`1.0.<run_number>`（构建号 = run number）。
- OpenSSL 产物按脚本哈希缓存（key `openssl-ios-*`），命中时跳过重新编译，显著缩短构建时间。
- 产物需自行签名后在设备安装（App 不支持自签安装流程，供应链上保持旁路）。

### 发布流程

- 构建成功后，未签名 IPA 作为 Actions Artifact 上传（保留 14 天；Artifact 页面入口在 Actions 运行记录页底部）。
- 正式发布由人工完成：在 Actions 运行记录页底部打开 Artifact 页面，下载 `IPA-Manager-v1.0.<run_number>-unsigned.ipa`，然后用 `gh release create` 创建 Release 并上传 IPA：

    ```bash
    gh release create v1.0.<run_number> \
      IPA-Manager-v1.0.<run_number>-unsigned.ipa \
      --title "v1.0.<run_number>" \
      --notes "未签名 IPA：请用 IPA Manager 导入自有证书签名后安装"
    ```

- Release 版本号固定为 `v1.0.<run_number>`（与构建号一一对应）；发布物为未签名 IPA，需导入 IPA Manager 用自有证书签名后安装到设备。

### 版本历史

- **v1.0.125**（分享扩展版）：新增分享扩展（Share Extension）——分享面板应用行出现「IPA Manager」入口（类似 QQ 邮箱/ChatGPT 的第三方入口），从电报/微信/文件等任意 App 分享 .ipa/.zip/证书文件点它即可接收，保存后打开 App 自动完成「导入 → 默认证书签名 → 发起安装 → 回桌面」一条龙。文件经 App Group 共享容器交接（扩展与主 App 沙盒隔离，无法直接传递）；若签名描述文件未包含 App Group 能力（通配符 profile 常见），扩展给出明确提示、主 App 跳过共享目录扫描，安装不受影响（zsign 按描述文件内嵌 entitlements 签名，签名结果与 profile 一致，不存在 entitlement 不匹配拒装问题）。同时修复扫描器触发点：诊断实测 iOS 27 不再回调 UIApplicationDelegate.applicationDidBecomeActive（冷启动有投递日志而回前台扫描无记录），回前台兜底扫描改挂 SwiftUI scenePhase（onOpenURL 同源通道实测可用），AppDelegate 回调保留作旧系统兜底；主 App 新增 ipamanager:// scheme，扩展保存成功后尝试直接拉起主 App 开始导入。
- **v1.0.123**（分享投递修正 + 追踪版）：修复"第三方 App 分享 → 入口显示为直接分享到（非拷贝到）→ 点开 App 毫无反应"且诊断报告无信号的残余问题。① 移除 UISupportsDocumentBrowser 声明（true→false）：该 key 声明本 App 为"文档浏览器"应用，与 UIFileSharingEnabled（文件共享）是 Apple 定位中两种互斥的文件暴露模式，组合声明矛盾；iOS 27 分享面板出现"无载荷入口"（直接分享到、点开 App 却不拷贝文件）的头号嫌疑即此——系统按文档浏览器语义路由分享而不走拷贝投递。本 App 从不使用 UIDocumentBrowserViewController，Documents 在文件 App 的可见性由 UIFileSharingEnabled 单独提供。② 新增外部投递追踪日志（ExternalDeliveryJournal，持久化跨启动 120 条环形）：启动（launchOptions 是否携带 URL）、openURL 事件（含 openInPlace）、回前台扫描结果、外部文件处理路由与结算结果全部落盘，诊断报告新增"外部投递追踪"章节——此前日志纯内存态，分享发生在上一次会话时报告完全不可见，"分享后无反应"无从定位。③ 回前台兜底扫描扩展到 Documents 根目录：除 Documents/Inbox 外，同时自动导入直接放入 Documents 根目录的 ipa/zip/p12/pfx/mobileprovision 文件（document-browser 式"保存到 App"投递与用户经文件 App 放入文件的兜底），导入后清理源文件。

- **v1.0.121**（分享导入加固版）：修复"第三方 App（电报/微信等）分享 → 拷贝到/打开方式 → App 打开后毫无反应"的残余场景。① 关闭 LSSupportsOpeningDocumentsInPlace（true→false）：开启 in-place 时系统可能直接把来源 App 沙盒内的原位 URL 投递给本 App（文件不落地到 Documents/Inbox），open 事件一旦丢失连兜底扫描都无文件可扫；关闭后所有投递一律由系统先拷入 Inbox 再打开，回前台兜底扫描成为"事件丢了也必导入"的保险（本 App 对外部文件只做导入复制、从不原位编辑，in-place 无实际收益）；② 证书文件/证书包分享导入补结算回调（onSettled 贯穿 handleDownloadedFile / importCertificateBundleOrFile / handleSingleCertificateFile）：p12/pfx/mobileprovision/zip 证书包导入收尾（含失败）后删除 Inbox 源文件并落盘"已处理"标记（原证书链路无结算点，残留只能等 24h 清扫且每次启动重复尝试导入）；③ 已处理标记改为结算时落盘：进程在导入中途被杀时投递未结算，下次启动自动重新导入（原投递即落盘会让该文件永远不再导入）；④ 回前台追加 2.5 秒延迟复查（系统极少数情况在 App 激活后才完成 Inbox 拷贝），在途/已结算投递在 AppState 内部去重，不会重复导入。
- **v1.0.120**（系统分享导入版）：打通系统分享面板——在微信 / QQ / Safari / 文件等任意 App 里对 .ipa/.zip 文件点“分享”→“**拷贝到 IPA Manager**”，App 自动完成 导入 → 默认证书签名 → 发起安装 → 回桌面 的完整一条龙（复用既有自动流程，无需任何手动操作）。① 冷启动投递丢失修复：分享冷启动时个别系统版本/时序下 application(_:open:) 与 onOpenURL 均不回调（表现为“分享后毫无反应”），didFinishLaunchingWithOptions 补读 launchOptions[.url]，与后续重复投递由既有去重兜住；② Inbox 兜底扫描：「拷贝到 App」的文件本体必然落在 Documents/Inbox，回前台扫描补处理丢失事件的投递，导入结算（成功/失败）后自动删除 Inbox 源文件（防重复导入、防 GB 级残留），已处理记录持久化防跨启动重复导入，超过 24 小时的残留自动清扫（证书包 zip 等无结算回调的链路兜底）；③ 分享可见性增强：显式声明 com.ipamanager.ipa UTI（UTImportedTypeDeclarations）并把 public.zip-archive 加入文档类型，提升各来源 App 分享面板中「拷贝到 IPA Manager」的出现率；④ 自动签名跳过不再静默：无默认证书/描述文件时导入成功即 toast 提示去证书页配置（原只写日志，分享方视角“毫无动静”）。注：分享面板对文件的集成入口显示为“拷贝到 IPA Manager”（iOS 文档类型机制），非 Share Extension——扩展传递文件必须 App Group，而本 App 由用户用任意企业证书自签，通配符 profile 不含 App Group 能力，嵌套 appex 的 entitlement 校验会导致整个 App 无法安装。
- **v1.0.118**（第五轮深度代码审查版）：并行 5 路代理全库审查后修复 20+ 处与性能优化——① 并发/崩溃：新增全局 zsign 串行队列（手动签名与证书 p12 解析不再与自动签名并发进桥接层）；连续安装防互踩（上一个安装仍在进行时新安装等待空闲，不再用下一个 start() 的 stop() 掐断上一下载中的安装）；监听器偶发端口冲突自动换端口重试 3 次；本地服务器读文件改 throwing API（I/O 错误不再以 ObjC 异常崩溃进程）。② vendor/zsign：ZSignAsset 补析构函数（修复每次签名泄漏 EVP_PKEY/X509/CA 栈、明文私钥材料滞留堆中）+ Init 失败路径释放；extern "C" 边界补 C++ 异常屏障（坏包深解析的 std::bad_alloc 不再终止进程）；OpenSSL provider 进程级一次性加载（原每次解析 load 且从不 unload）；删除约 420 行无调用方的 TLS 身份死代码（zsign_p12_export_identity / zsign_p12_recreate_legacy / TLSIdentityHelper）。③ 安装链路：自动回桌面锚定到 itms-services open 成功之后（原 1.2s 固定计时早于 open，后台态 open 被忽略 → 自动安装静默失败）；api.palera.in 2s 可达性预检失败直接走本地 manifest（原"本地回退"条件不可达，无外网/被墙必败）；静音保活补 AVAudioSession 中断处理（来电/闹钟后自动恢复播放）+ 心跳自愈 + 激活失败后台时间兜底。④ 下载链路：失效 resumeData 死循环修复（-1100 等文件类失败正确毒化断点整包重下，completed/retry 同步清空）；续传一致性校验（偏移+期望字节数 ≠ 原总大小时放弃断点，防服务器换内容拼出损坏产物）；暂停改用 cancel(byProducingResumeData:)（暂停过夜的大文件"继续"可真续传）；产物认领追加"已收满"守卫 + 进度 5s 周期持久化（同 URL 双任务不再互相错误认领）；retry 重置 totalBytes 落盘标记。⑤ 解析/导入（性能为主）：zip 分类改中央目录路径扫描 + 内嵌 .ipa 单条目抽取（自动导入不再为看文件名全量解压两遍，2GB 包峰值磁盘减半）；已签应用解析加 (path,mtime,size) 会话缓存 + 解压目录用后即清（每次刷新不再全量重复解压，会话内解压副本不再线性堆积）；同名冲突 bundleID 比对与安装元数据统一走轻量单条目 API；证书包查找补 .pfx 盲区；启动清扫明文 P12 托管副本与 bundle-extract-* 残留（导入中途被杀的私钥材料不再永久驻留 Documents）；描述文件导入失败补 toast 并清理副本；磁盘满解压单独归因（原误报"ZIP 已损坏请重新下载"）；hasPayloadDirectory 全量扫描（__MACOSX/ 前置的标准包不再被误判整包重打包）；tgz/tar/gz 准确提示暂不支持；签名历史上限 300 条；导入进度节流前置到调用线程。⑥ UI：已签应用/下载列表勾选集合随刷新剪枝（后台刷新重建条目后批量删除不再静默失效、计数虚报）；证书页导入进行中禁用再次导入（并发导入不再泄漏明文 P12）；下载页自动导入中点击直接提示稍候、4s 兜底不再吞真实导入回调；浏览器补 webViewWebContentProcessDidTerminate 自动重载（白屏自愈）+ text/json/xml 不再误拦为下载；书签 toast 可取消计时；详情页源文件缺失禁用分享；图标 mtime 5s 记忆缓存。⑦ 构建/CI：OpenSSL 仅构建 libcrypto（全库无 SSL_* 调用，冷缓存省约 25-30%）；CI 缓存拆 restore/save（仅成功后保存）+ 产物缺失就地重建（失败/取消不再污染缓存）；IPA 附 SHA256SUMS 完整性基准；ZIPFoundation 锁定 exactVersion 0.9.19。
- **v1.0.112**（列表排序调整版）：下载任务列表改为最新在前（原按任务创建时间升序，最早的任务排在最上，现改为倒序）；已签应用列表改为最新在前（原按磁盘目录原始顺序展示，现按签名产物的修改时间倒序，刚签名完成的应用排最前；排序在解析 IPA 之前基于文件元数据完成，不产生额外磁盘 IO 与解析开销）。
- **v1.0.110**（第四轮复审版）：修复 19 处——① 批量导入/签名队列：修复批量导入选「仅导入，不自动安装」后仍自动签名安装（autoSign 参数穿透到 importFile 统一出口，视图层拦截被无视）；自动签名队列出队复验（批量签名期间删除/失效默认证书/描述文件或关闭开关，剩余项直接跳过而不再用失效组合签出无法安装的包）；同 bundleID 重导入不再绕过自动签名去重（追加 bundleID 维度）；批量自动签名队列未清空时不自动回桌面（后台 open itms-services 不可靠，保持前台逐个弹确认）。② 删除/磁盘泄漏：修复删除已签应用只删产物不删源（按 signedPath 关联 importedApps 记录，源 IPA/解析目录/图标目录一并清理，原数 GB 源文件永久泄漏且记录残留无 UI 入口可清）；签名失败停蠕动定时器（85% 后失败最常见，每次泄漏一个每 0.5s 空转的常驻 DispatchSourceTimer，另加 deinit 兜底）；结构规范化失败清理 workRoot 与半成品 normalized-*.ipa（整包解压副本可达数百 MB/次）；zip 重打包失败清理半成品 .ipa；persistProfile 换位失败清理 .tmp 残留。③ 长传输/安装会话：活动时间戳在分块发送循环内刷新（SpringBoard 只发一次 GET，多 GB 包传输超窗口会被回前台/保活超时误判为无活动而掐断）；新增安装会话判定（弹窗停留超 4 分钟后回 App 不再误停服务器）。④ 正确性：恢复任务认领产物的大小校验真正生效（totalBytes 首次已知时持久化，原 didWriteData 从不落盘，崩溃恢复场景校验形同虚设）；启动孤儿清扫加 mtime 保护并移至首次已签应用扫描后执行（防误删解析中/进行中导入的解压目录）；embedded.mobileprovision 不再被证书包抓取（与分类器语义对齐）；AnyCodable 64 位数值不再被 32 位截断；导入归档处理串行化（两个下载同时完成不再双倍解压内存/磁盘峰值）。⑤ 反馈与杂项：zip 证书包失败/无证书/密码不匹配补 toast；批量自动签名保持前台逐个确认；外部打开 tgz/tar/gz 与下载链路统一走归档分类、坏包计入失败数；未知 Content-Length 不再显示 "−1 字节"；密码框取消清空密码；UserDefaults 降级时跳过写入兑现只读承诺；C++ 桥接 PEM 私钥不再被 p12 诊断器误诊、关闭无效的 .zsign_cache 写盘；build-openssl.sh 本地复跑不再嵌套拷贝头文件。
- **v1.0.108**（第三轮深度代码审查版）：并行 4 路代理全库审查后修复 20+ 处 bug 与性能问题——① 安装链路：本地安装服务器全部可变状态收敛到串行队列（原主线程/GCD/服务器队列三方无同步访问同一数组，大 IPA 传输中回前台即可触发并发崩溃）；IPA 分块发送检查 NWError（客户端断开后不再读完整个文件空转数百次失败发送）；HTTP 请求循环累积到 

 再解析（半包不再误判 404）；fetchurl 固定 127.0.0.1（回环探测被取消时可能误选 utun/VPN 地址导致安装概率性失败）；回前台仅在无近期安装活动时才停服务器（原无条件停，掐死进行中的安装下载且无提示）；保活 5 分钟硬超时改为活动感知顺延（大包/弹窗停留不再被挂起）；安装后台失败改用全局 toast 反馈（原完全静默）；ready 等待改用 semaphore（DispatchGroup 在 .cancelled 多 leave 会崩溃）。② 签名/证书：修复 ECC 证书签名必然失败（EC 私钥 PEM 导出把 X9.63 原始字节包 SEC1 头尾，OpenSSL 解析必败，现重组为 PKCS#8）；SecPKCS12Import 回退路径从证书 subject OU 解析 Team ID（原恒为空，Team 匹配校验被静默架空）；ProgressSmoother.complete() 切主线程消除数据竞争；证书凭据检查前移（大 IPA 不再白做数十秒规范化才发现证书不可用）；受保护证书读不到密码（设备锁定）给出明确提示；证书重复导入按 Keychain 标识去重（原两条记录共享私钥，删除一条摧毁另一条）；证书包递归查找 + 精确解压目录清理 + 两样皆无抛错（原深层 p12 静默失败且明文 P12 残留 Documents 可被文件 App 导出）。③ 下载：DownloadTask 自定义 decodeIfPresent 解码（修复升级后全部下载任务记录丢失）；恢复任务认领产物校验文件大小（防同名任务张冠李戴）；重试计数真正持久化（原内存字典重启清零，实现承诺的 24h 重置）；didFinishDownloadingTo 幽灵任务守卫。④ 解析/ZIP：zip64 体积累加改 addingReportingOverflow（防伪造字段触发整型溢出崩溃/绕过炸弹防线）；zip 进度双重加权修复（原最多显示 36%）；转换后立即清理源解压目录（峰值磁盘占用减半）；.APP 大写扩展名统一识别；Info.plist 顶层非字典不再静默降级；空 bundleID 不按空串去重；importedApps 后台读取改主线程快照消除竞争。⑤ UI：浏览器地址栏与导航分离（原每敲一个字符触发一次真实导航并覆盖输入文本）；toast 计时器互踩修复；导入进度卡与全局 toast 收敛到同一 overlay（跨容器 zIndex 不参与比较，原必然叠压）；导入中禁用再次导入；书签→浏览器 sheet 改 onDismiss 串联（边 dismiss 边 present 间歇性丢失）；详情页删除与本地 @State 完全重复的 SignViewModel（双状态+双计时器）；DateFormatter static 化/图标过采样减半/启动孤儿清扫移后台。⑥ 死代码清理：SignViewModel 类、SecurityScopedAccess.swift、renameItem、contentsAsync、validateEntryPaths、sweep(prefix:)、bundleExtractRoot、recordFailure、冗余常量与字段等。
- **v1.0.100**（bug 修复 + 性能优化版）：① 修复"同一证书重复导入产生 N 条记录"：keychainIdentifier 改为基于 P12 内容 SHA256 前 8 字节的稳定指纹，密码单独再哈希一份，重复导入可按 ID 去重 / 复用 Keychain 私钥，避免 N 份私钥副本堆积；② 修复 HTML 检测误判：把 `"not found"` / `"404"` 这种常见正常文本（file_not_found.txt、v2.0.4 等）从 HTML markers 中移除，只保留 `<!doctype html` / `<html` / `<head>` 等真正标签起首；③ 修复"续传失败误触发整包重下"：`NSURLErrorCannotConnectToHost(-3004)` 等网络瞬态错误不再被当作 resumeData 无效，只对真正文件/数据异常（-3000 / -1020）才整包兜底；④ 修复"长 Header 致 IPA 下载无响应"：LocalInstallServer 单次 receive 缓冲从 8KB 提至 64KB，HTTP GET + 多 Header 请求不再被截断到 fallback 的 `/manifest.plist`；⑤ Logger 锁升级为 `OSAllocatedUnfairLock`（防 os_log 内部再调 Logger 时同线程重入死锁）、签名进度蠕动 Timer 改 `DispatchSourceTimer`（itms-services 退后台 RunLoop 暂停时仍能继续蠕动到 98%）、批量删除已签应用改为 `concurrentPerform` 并行 IO（IPA + 解析目录 + 图标目录按 baseName 分桶同时删）、证书 ASN.1 时间加月日时分秒范围校验（拒绝 month=0/13、day=32、hour=24 等畸形日期，避免 DateComponents 静默循环进位导致过期时间算错）；⑥ 清理：删除根目录误落的脏文件 `0` 和 `1048576`（UTF-16-LE "15011\r\n"）、空的 `Sources/Sources/` 重复目录。
- **v1.0.99**（代码审查清理版）：全面代码审查后的一轮优化——① 清理冗余代码（-431 行）：删除 `Installer.generateManifest`（自改用公网 manifest 后未再被调用）、`CertificateManager.listCertificates`（证书列表实际由持久层维护）、整个 `ServerIdentityProvider.swift`（369 行无引用文件，本地安装服务器早已改明文 HTTP，TLS 身份路径整体废弃）；② 性能优化：Logger 的 OSLog 对象由"每次调用新建"改为单一 static 实例，减少签名/下载进度等高频日志的分配开销。审查结论：核心链路（签名/安装/证书/下载/持久化）线程处理细致、防御完善，未发现崩溃级或数据丢失级 bug。
- **v1.0.97**（证书页低调配色版）：证书管理页配色全面低调化——底部「一键导入证书」去掉蓝色渐变底 + 蓝色光晕（双层叠套不协调），改为极简单层中性浅底胶囊（深浅色自适应），无外层容器轮廓；证书/描述文件图标底透明度 0.14→0.07、前景同步降饱和；「默认」徽章 accent→secondary、底 0.14→0.07；状态胶囊底 0.12→0.07、文字降饱和；空态「点击导入」accent→secondary。整体无大面积高饱和色块，符合"用户几个月才进一次、画面感不需强"的定位。
- **v1.0.94**（浏览器 Safari 化 + 证书页交互重构版）：① 内置浏览器更 Safari 风格：地址栏改大号圆角胶囊（https 锁图标 / http 橙色开锁警示 / 加载中转圈 / 有内容时一键清除、空时 Safari 图标占位），底部工具栏改毛玻璃材质 + 圆形小按钮（后退/前进/刷新-停止二合一/外部打开/书签/关闭），新增浏览器内「重新加载/停止加载」，下载拦截、前进后退、书签、收藏、外部打开等功能全部保留；② 证书管理页交互重构：移除左上角「卸载证书」按钮（右滑单删保留）；空态卡片可点击——无企业证书时点击直达「选择企业证书」（限 p12/pfx/zip），无描述文件时点击直达「选择描述文件」（限 mobileprovision/zip）；右上角小按钮移除，改页面底部悬浮「一键导入证书」大胶囊按钮（品牌色渐变 + 阴影，全类型导入）。
- **v1.0.91**（防二次签名 + 证书卸载 + 公告卡版）：① 修复"下载过一次却出现二次签名/已签应用重复"：上次下载任务中断/重试会把状态残留成"下载中"并持久化，下次启动被当作未完成任务整包重新下载，又触发"下载后自动签名并安装"，于是多出一个已签应用；现在启动恢复下载任务时先检查下载目录是否已有该任务的完成产物，有就直接按"已完成"恢复，不再重复下载、不再二次签名；② 证书管理页左上角新增「卸载证书」按钮：确认后一键卸载全部证书（同步清理 Keychain 私钥），右滑单删功能保留；③ 证书卡片改为纯展示，默认标记从勾选圈改为安静的「默认」胶囊徽章；④ 设置页「功能亮点」改为公告式卡片：虚线边框 + 浅色底，与下方可点击的操作卡片明显区分，避免误以为可点；⑤ 批量导入"预防针"：多选导入（>1 个）且自动签名开启时，先询问"顺序自动签名并安装 / 仅导入不自动安装"，避免毫无预告地连弹一串系统安装确认；选"仅导入"则进未签名列表手动签名，汇总里注明。
- **v1.0.89**（证书管理 + 设置页美化版）：① 证书管理页：企业证书 / 描述文件改为统一卡片（半透明圆角底 + 细描边 + 行间留白），与已签应用 / 下载页风格一致；卡片数据充实——组织 / 通用名、Team ID、有效期范围（起 ~ 止）、描述文件的 Bundle ID / Team ID / 设备范围（限定 N 台 / 企业通配）、状态胶囊；行首状态色图标底一眼可辨；空态改为虚线圆角引导卡；② 按钮去重：右上角「一键导入」与原「+」打开的是同一个文件选择器，功能完全相同，移除「+」只保留「一键导入」；③ 设置页：分组重构为「功能亮点 / 自动流程 / 诊断与反馈 / 关于」，每行图标瓦片 + 标题 + 副标题，Section 标题带小图标，行改为卡片容器与全局毛玻璃风格统一。
- **v1.0.86**（毛玻璃加强 + 列表卡片化版）：① 毛玻璃效果加强：背景改为统一中性底色 + 彩色光斑 + 半透明材质，玻璃质感明显，同时消除旧版大块品牌色渐变造成的"两种颜色"割裂观感；② 应用列表全部卡片化：首页未签名应用 / 已签应用 / 下载任务 均为圆角卡片（浅色半透明底 + 细描边），行与行之间留白间隔，图标与文字整体一块，不再一溜到底无分隔；③ 空态底色统一：已签应用空态等不再出现第二种底色，与页面背景一致；④ 下载任务卡片底色统一为半透明，透出玻璃质感。
- **v1.0.82**（毛玻璃 + 时间预估 + 反选版）：① 全局毛玻璃效果（第一版）：所有页面（首页/已签应用/下载/证书/设置/应用详情）接入"品牌色渐变 + ultraThinMaterial"背景层，列表透明化透出玻璃质感，深浅色模式自适应，底部悬浮操作条保持半透明材质；② 签名时间预估优化：zsign 真实进度仅 5/20/85/100 四档（旧算法用平滑器假进度线性外推，20% 停留时剩余暴涨、85% 蠕动时虚低），改为阶段感知分段估算——准备/解压按已用×2 封顶 30s、签名主程序按已用×1.5 封顶 80s、重新打包以真实 85% 锚点为基准按总耗时≈85%前×1.6 收敛，更接近真实剩余；③ 多选模式新增「反选」按钮（已签应用页/下载页悬浮条，勾选未选中的、取消已选中的）。
- **v1.0.80**（自动一条龙 + 悬浮操作条版）：① 导入/下载完成后自动签名并安装（设置"导入/下载后自动签名并安装"开关，默认开）：导入成功即自动用默认证书签名并发起安装，完成后自动回桌面等 iOS 弹安装提示，无需再手动点操作；② 签名完成后自动返回桌面（设置"签名完成后自动返回桌面"开关，默认开）：详情页签名完成弹窗约 1.5 秒后自动执行"返回"，用户手动点"确定/返回"即取消自动动作；③ 已签应用页/下载页操作按钮全部移至底部悬浮操作条（半透明材质胶囊悬浮在 Tab 栏上方，拇指可及），选择模式新增「全选/取消全选」，与原「全部清除/选择/删除选中 (N)」统一在底部；④ 修复自动返回功能因 SwiftUI View(struct) 误用 `[weak self]` 导致的编译失败。
- **v1.0.76**（多选删除版）：已签应用页与下载页工具栏「全部清除」旁新增「选择」按钮，进入多选模式勾选要删除的项，点「删除选中 (N)」只删除勾选项、保留其余（下载中任务先取消再移除），删完自动退出选择模式；v1.0.68 / v1.0.74 / v1.0.76 三版同时在线上（v1.0.80 起保留四版）。
- **v1.0.74**（导入修复版）：修复 v1.0.72 引入的严重倒退——导入 IPA/ZIP 一律报"ZIP 文件已损坏或下载不完整"。根因是带进度的解压 `unzipWithProgress` 把解压根目录直接传给 `archive.extract(entry, to:)`，而该参数应为条目自身完整路径，导致第一条目在已存在目录上 createFile 抛 `NSFileWriteFileExistsError`(516) 被误报为归档损坏；改为按条目拼接完整路径（与 ZIPFoundation `unzipItem` 官方行为一致），516 仅兜底跳过。保留 v1.0.72 全部功能（签名阶段显示、时间预估、弹窗提速、导入进度线性化）。
- **v1.0.72**（签名可视化版）：签名时进度条实时显示当前阶段（正在解压 / 正在签名主程序 / 正在重新打包 / 签名完成）；新增"已用 X 秒 · 预计剩余 Y 秒"时间预估（完成显示总用时）；签名完成弹窗提速（不再被后台刷新阻塞卡顿）；安装提示加快（本地服务器探测 4s→1s）；导入进度线性化（直接导入 .ipa 从 5% 按真实解压字节涨到 98%，不再跳 80%）；首页"我的应用"改名"未签名应用"。
- **v1.0.68**（全面修复版）：修复取消下载产生删不掉的"幽灵任务"、断点续传失败自动整包重下、浏览器与下载共享登录态（Cookie）+ 防盗链 Referer；导入进度条实时百分比、修复文件 App 打开导入失败（安全作用域时序）、同名二次导入不再覆盖旧文件；签名打包提速（压缩级别 6→1）+ 85% 阶段进度平滑、签名前校验证书/描述文件过期与匹配、失败残留清理；安装流程重活移后台不再卡界面、安装完成回到前台自动停止本地服务器与后台音频；密码弹窗取消清理明文私钥、启动清理钥匙串孤儿条目；CI 新增产物自动校验（缺 Payload 层/版本号错误直接终止）。
- **v1.0.64**：修复 CI 打包丢 Payload/ 层问题（`ditto -c -k` 打包目录不保留目录名，改用 `zip -qr`），签名前自动规范化非标准 IPA（解压找 .app 重打包为 Payload/ 结构），下载失败临时文件生命周期修复（URLSession 回调内同步移动）。
- **v1.0.61/1.0.59**：下载完成流程、首页导入进度条、"签名完成"返回按钮同时回桌面、书签与浏览器 UI 等修复（已归档）。

## 目录结构

```
Sources/
  App/                  AppState（全局状态）、AppDelegate、UserDefaultsStore
  CertificateManager/   证书/描述文件/keychain 管理、证书 zip 包导入
  SigningEngine/        签名引擎（zsign + Security framework 双路径）
  DownloadManager/      下载管理（断点续传、恢复、回填）
  Installer/            本地 HTTP 服务器、TLS 身份、itms-services 安装
  IPAParser/            IPA/ZIP 解析、Info.plist 与图标提取
  ProvisioningManager/  描述文件解析（含 ProvisionedDevices）
  Models/               数据模型
  UI/                   SwiftUI 界面（首页/已签应用/下载/证书/设置）
  ZipManager/           ZIP 解压（zip-slip 防御）与打包
Vendor/
  zsign/                zsign 签名核心与 iOS 桥接
  openssl/              OpenSSL 静态库（构建脚本产物，不入库）
scripts/
  build-openssl.sh      OpenSSL 构建脚本（本地 + CI 共用）
.github/workflows/
  build.yml             iOS 构建流水线
```

## 安全说明

- 证书与描述文件由用户自行导入并保存在设备 Keychain / Documents 中；仓库不包含任何内置证书（bundled.p12 / bundled.mobileprovision 已移除）。
- 本地 HTTP 服务器仅在安装会话期间监听，仅提供本机签名产物，不对外网开放。
- 下载/解压链路带有路径穿越（zip-slip）防御与文件名净化。
- 所有错误信息为中文具体描述；诊断报告一次包含全部错误，供定位问题。

## 已知限制

- 安装时的系统确认弹窗不可自动绕过（iOS 平台限制，通用签名工具均如此）。
- 后台音频保活（`UIBackgroundModes: audio`）用于安装期间进程不被挂起；若未来上架 App Store 需评估该模式的审核要求。