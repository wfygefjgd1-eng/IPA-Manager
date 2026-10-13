import Foundation
import UniformTypeIdentifiers

extension UTType {
    // 自定义扩展名的类型必须以 Info.plist 的 UTImportedTypeDeclarations（project.yml）
    // 声明为准，用 UTType(importedAs:) 引用；filenameExtension 只作声明缺失时的回退。
    // 背景：UIDocumentPickerViewController 的文件类型过滤在系统进程内完成，
    // UTType(filenameExtension:) 对系统未收录的扩展名（mobileprovision 必然如此，
    // p12 部分系统版本同样）只会生成本进程内的动态 UTI（dyn.*），选择器进程解析
    // 不了 → 证书页选择器打开后对应文件灰显/选不了，表现为"证书/描述文件导入不了"。
    static let ipaType = UTType(importedAs: "com.ipamanager.ipa")
        ?? UTType(filenameExtension: "ipa")
        ?? .data
    static let p12Type = UTType(importedAs: "com.ipamanager.p12")
        ?? UTType(filenameExtension: "p12")
        ?? UTType(filenameExtension: "pfx")
        ?? .data
    static let mobileprovisionType = UTType(importedAs: "com.ipamanager.mobileprovision")
        ?? UTType(filenameExtension: "mobileprovision")
        ?? .data
}
