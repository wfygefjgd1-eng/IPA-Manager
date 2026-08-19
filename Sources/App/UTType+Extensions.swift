import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let ipaType = UTType(filenameExtension: "ipa") ?? .data
    static let p12Type = UTType(filenameExtension: "p12") ?? UTType(filenameExtension: "pfx") ?? .data
    static let mobileprovisionType = UTType(filenameExtension: "mobileprovision") ?? .data
    static let pkcs12 = p12Type
}
