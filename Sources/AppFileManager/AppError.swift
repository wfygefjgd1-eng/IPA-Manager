import Foundation

enum AppError: LocalizedError {
    case fileNotFound(String)
    case invalidPath(String)
    case operationFailed(String)
    case certificateInvalid(String)
    case profileInvalid(String)
    case signFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "文件不存在: \(path)"
        case .invalidPath(let path):
            return "无效路径: \(path)"
        case .operationFailed(let message):
            return "操作失败: \(message)"
        case .certificateInvalid(let message):
            return "证书无效: \(message)"
        case .profileInvalid(let message):
            return "描述文件无效: \(message)"
        case .signFailed(let message):
            return "签名失败: \(message)"
        case .installFailed(let message):
            return "安装失败: \(message)"
        }
    }
}
