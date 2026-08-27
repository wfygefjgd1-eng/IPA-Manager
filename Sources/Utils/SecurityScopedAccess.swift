import Foundation

/// Helper to wrap security-scoped resource access for files opened via
/// Files / document picker (LSSupportsOpeningDocumentsInPlace).
///
/// Usage:
/// ```swift
/// try withSecurityScopedAccess(to: url) {
///     try FileManager.default.copyItem(at: url, to: destination)
/// }
/// ```

@discardableResult
func withSecurityScopedAccess<T>(to url: URL, perform: () throws -> T) rethrows -> T {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
        if accessed {
            url.stopAccessingSecurityScopedResource()
        }
    }
    return try perform()
}

@discardableResult
func withSecurityScopedAccess<T>(to url: URL, perform: () async throws -> T) async rethrows -> T {
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
        if accessed {
            url.stopAccessingSecurityScopedResource()
        }
    }
    return try await perform()
}
