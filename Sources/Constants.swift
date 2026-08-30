import Foundation

// MARK: - Centralized constants for the whole project

/// Progress weighting used in the import flow (AppState).
/// Overall import is split into stages: unzip (0-60%) -> copy (60-80%)
/// -> parse (80-95% or 5-98% for direct .ipa) -> icon (to 100%).
enum ProgressWeight {
    static let unzip: Double = 0.6

    /// Fixed progress checkpoints used when mapping sub-progress into overall progress.
    static let copyProgress: Double = 0.6

    /// Zip import: second parse (re-parse) maps 0.8 -> 0.95
    static let parseStartZip: Double = 0.8
    static let parseRangeZip: Double = 0.15
    static let iconProgressZip: Double = 0.95

    /// Direct .ipa import: parse maps 0.05 -> 0.98
    static let parseStartDirect: Double = 0.05
    static let parseRangeDirect: Double = 0.93
    static let iconProgressDirect: Double = 0.98

    /// Throttle threshold for ImportProgress (skip update if delta < 1%)
    static let throttleDelta: Double = 0.01
}

/// Size / count limits used across modules.
enum Limits {
    // ZipManager safety limits (zip bomb protection)
    static let maxEntries: Int = 50_000
    static let maxTotalBytes: UInt64 = 4 * 1024 * 1024 * 1024 // 4 GB

    // Logger buffers
    static let maxLogEntries: Int = 300
    static let maxFailureEntries: Int = 100
    static let maxRecentInReport: Int = 100

    // UserDefaultsStore backup retention
    static let backupTTLInterval: TimeInterval = 7 * 24 * 60 * 60

    // DownloadManager retry
    static let maxRetryCount: Int = 1

    // Diagnostics / file handles
    static let zipHeaderReadLength: Int = 4
    static let downloadProbeLength: Int = 4096
    static let downloadEOCTailLength: UInt64 = 65_536
}

/// Timeout / duration constants.
enum Timeouts {
    /// LocalInstallServer: sync HEAD probe timeout (LocalInstallServer.probe)
    static let serverProbe: TimeInterval = 1.0
    /// LocalInstallServer: NWListener ready wait (DispatchGroup.wait)
    static let readyWait: TimeInterval = 5.0
    /// DownloadManager URLSession request timeout
    static let request: TimeInterval = 120
    /// AppState toast auto-clear
    static let toast: TimeInterval = 3.0
    /// AppState external-open dedupe window
    static let externalOpenDedupe: TimeInterval = 2.0
    /// LocalInstallServer isReachable HEAD timeout
    static let isReachable: TimeInterval = 5.0
}
