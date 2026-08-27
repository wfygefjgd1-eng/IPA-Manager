import Foundation

// MARK: - Centralized constants for the whole project

/// Progress weighting used in import flow (AppState + IPAParser).
/// Overall import is split into 4 logical stages:
/// unzip (60%) -> copy (20%) -> parse (15%) -> icon (5%)
enum ProgressWeight {
    static let unzip: Double = 0.6
    static let copy: Double = 0.2
    static let parse: Double = 0.15
    static let icon: Double = 0.05

    /// Fixed progress checkpoints used when mapping sub-progress into overall progress.
    static let unzipEnd: Double = 0.6
    static let copyProgress: Double = 0.6
    static let copyEnd: Double = 0.8

    /// Zip import: second parse (re-parse) maps 0.8 -> 0.95
    static let parseStartZip: Double = 0.8
    static let parseRangeZip: Double = 0.15
    static let iconProgressZip: Double = 0.95

    /// Direct .ipa import: parse maps 0.05 -> 0.98
    static let parseStartDirect: Double = 0.05
    static let parseRangeDirect: Double = 0.93
    static let iconProgressDirect: Double = 0.98

    /// IPAParser.convertToIPAIfNeeded: unzip phase is 0 -> 0.6 of total
    static let convertUnzipWeight: Double = 0.6

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
    static let backupTTLSeconds: TimeInterval = 7 * 24 * 60 * 60 // 7 days
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
