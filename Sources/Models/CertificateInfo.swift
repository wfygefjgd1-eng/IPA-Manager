import Foundation

struct CertificateInfo: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var teamID: String = ""
    var commonName: String = ""
    var organization: String = ""
    var startDate: Date?
    var expireDate: Date?
    var isPasswordProtected: Bool = false
    var keychainIdentifier: String?
    var passwordKeychainIdentifier: String?

    enum Status: String, Codable {
        case valid
        case expired
        case unknown
    }

    var status: Status {
        guard let expire = expireDate else { return .unknown }
        return expire > Date() ? .valid : .expired
    }

    var statusDescription: String {
        switch status {
        case .valid: return "有效"
        case .expired: return "已过期"
        case .unknown: return "未知"
        }
    }

    var expireDateDescription: String {
        guard let expire = expireDate else { return "未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: expire)
    }
}
