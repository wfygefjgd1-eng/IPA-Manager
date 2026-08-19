import Foundation

final class CertificateBundleImporter {
    static let shared = CertificateBundleImporter()

    private let zipManager = ZipManager.shared
    private let fileManager = AppFileManager.shared

    struct BundleContent {
        let p12URL: URL?
        let profileURL: URL?
    }

    func extract(from zipURL: URL) throws -> BundleContent {
        let accessed = zipURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                zipURL.stopAccessingSecurityScopedResource()
            }
        }

        let extractDir = fileManager.directoryURL(.certificates)
            .appendingPathComponent("bundle-extract-\(UUID().uuidString)", isDirectory: true)

        try zipManager.unzip(archiveURL: zipURL, destinationURL: extractDir)

        let p12Path = try findFile(extension: "p12", in: extractDir)
        let provPath = try findFile(extension: "mobileprovision", in: extractDir)

        return BundleContent(
            p12URL: p12Path.map { URL(fileURLWithPath: $0) },
            profileURL: provPath.map { URL(fileURLWithPath: $0) }
        )
    }

    func moveToManagedLocation(p12URL: URL?, profileURL: URL?) throws -> (p12URL: URL?, profileURL: URL?) {
        var resultP12: URL?
        var resultProfile: URL?

        if let url = p12URL {
            let dest = fileManager.directoryURL(.certificates)
                .appendingPathComponent("cert-\(UUID().uuidString).p12")
            try fileManager.copyItem(from: url, to: dest)
            resultP12 = dest
        }
        if let url = profileURL {
            let dest = fileManager.directoryURL(.profiles)
                .appendingPathComponent("profile-\(UUID().uuidString).mobileprovision")
            try fileManager.copyItem(from: url, to: dest)
            resultProfile = dest
        }
        return (resultP12, resultProfile)
    }

    func cleanup(extractDir: URL) {
        try? fileManager.deleteItem(at: extractDir)
    }

    private func findFile(extension ext: String, in directory: URL) throws -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        for item in items {
            let itemURL = directory.appendingPathComponent(item)
            let lower = (item as NSString).pathExtension.lowercased()
            if lower == ext.lowercased() {
                return itemURL.path
            }
        }
        // search one level deep
        for sub in items {
            let subPath = directory.appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subPath.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let inner = try? FileManager.default.contentsOfDirectory(atPath: subPath.path),
               let match = inner.first(where: { (($0 as NSString).pathExtension.lowercased() == ext.lowercased()) }) {
                return subPath.appendingPathComponent(match).path
            }
        }
        return nil
    }
}