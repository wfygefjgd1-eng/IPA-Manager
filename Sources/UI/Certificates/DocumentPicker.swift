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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = contentTypes ?? [.item]
        // asCopy=false：返回安全作用域 URL，消费方直接读原位置。旧实现 asCopy=true
        // 会让系统先把文件整份拷进 tmp、导入流程再从 tmp 二次拷贝——GB 级 IPA 的
        // 文件选择器导入凭空多一倍 IO 与磁盘峰值。全部消费方
        // （AppState.importFile / CertificateBundleImporter.extract /
        // ProvisioningManager.importProfile / CertificateManager.importCertificate）
        // 均已自带 startAccessingSecurityScopedResource 成对管理，直接读作用域 URL。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
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
            if let onPickMany = parent.onPickMany {
                onPickMany(urls)
            } else if let url = urls.first {
                parent.onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}