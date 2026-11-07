import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    /// 可选：多选时一次性回调全部 URL；设置了它时优先使用，onPick 仅用于单文件场景（如 CertificatesView）
    var onPickMany: (([URL]) -> Void)?
    var allowsMultiple = false
    /// 可选：限定可选的文档类型（如仅 p12/pfx/zip 或仅 mobileprovision/zip）；
    /// nil 时允许所有类型（.item）
    var contentTypes: [UTType]? = nil
    /// 可选：用户在系统选择器里点「取消」的回调。旧实现保持 no-op，但嵌在 SwiftUI
    /// sheet 里的选择器取消后系统并不接管 sheet 的收起——页面表现为选择器窗口
    /// 关不掉（消失的回调链请去投递追踪日志核对），调用方需要显式复位 sheet 状态。
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = contentTypes ?? [.item]
        // asCopy=true（Copy 模式）必须保留，实测回归教训：
        // asCopy=false（Open 模式）有两个 Copy 模式没有的限制——
        // 1) 严格类型过滤：文件可选性由系统进程解析出的 UTI 是否 conforms 到请求类型
        //    决定。p12/mobileprovision 在 iOS 无系统 UTI（文件解析为 dyn.* 动态 UTI，
        //    与 App 声明的 com.ipamanager.p12 只是 public.data 下的兄弟节点、不互相
        //    conforms），Info.plist 声明也救不了文件提供方的解析 → 证书文件灰显、
        //    点击无反应（"一键导入证书点不动"）；
        // 2) 只能原位打开：位于其它 App 容器（下载器/微信 Documents 等）的 IPA 无
        //    安全作用域权限 → 同样灰显选不了（"找到 IPA 点击打开无效"）。
        // Copy 模式由系统代为拷贝进 tmp，任何位置/任何类型的文件都可点选，170 版本
        // （asCopy=true）一直正常。代价是 GB 级 IPA 多一份 tmp 拷贝 IO——正确性优先，
        // 不要再为省 IO 改回 Open 模式。tmp 拷贝非 security-scoped，消费方的
        // startAccessingSecurityScopedResource 返回 false 即跳过，成对管理无副作用。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // 落投递追踪：回调是否到达、带几个文件——"点击打开后毫无反应"类反馈
            // 的第一诊断口径（回调缺失 ⇒ 断在系统拷贝/回调环节，而非 App 导入环节）
            let shown = urls.prefix(3).map { $0.lastPathComponent }.joined(separator: "、")
            let more = urls.count > 3 ? " 等 \(urls.count) 个" : ""
            ExternalDeliveryJournal.record("文件选择器回调：\(urls.count) 个文件（\(shown)\(more)）")
            if let onPickMany = parent.onPickMany {
                onPickMany(urls)
            } else if let url = urls.first {
                parent.onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            ExternalDeliveryJournal.record("文件选择器已取消")
            onCancel?()
        }
    }
}