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
            if let onPickMany = parent.onPickMany {
                onPickMany(urls)
            } else if let url = urls.first {
                parent.onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}