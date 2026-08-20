import Foundation

struct AnyCodable: Codable, Hashable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let uint = try? container.decode(UInt.self) {
            value = uint
        } else if let int64 = try? container.decode(Int64.self) {
            value = int64
        } else if let uint64 = try? container.decode(UInt64.self) {
            value = uint64
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let uint as UInt: try container.encode(uint)
        case let int64 as Int64: try container.encode(int64)
        case let uint64 as UInt64: try container.encode(uint64)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map(AnyCodable.init))
        case let dict as [String: Any]: try container.encode(dict.mapValues(AnyCodable.init))
        default: try container.encodeNil()
        }
    }

    /// 数值语义相等：1 与 1.0、Int64(1) 与 Double(1.0) 视为相等
    /// （NSNumber 数值语义比较），避免 String(describing:) 的精度/类型差异。
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as NSNumber, r as NSNumber):
            return l.isEqual(to: r)
        case let (l as String, r as String):
            return l == r
        case let (l as Bool, r as Bool):
            return l == r
        case let (l as [Any], r as [Any]):
            guard l.count == r.count else { return false }
            for (a, b) in zip(l, r) where AnyCodable(a) != AnyCodable(b) {
                return false
            }
            return true
        case let (l as [String: Any], r as [String: Any]):
            guard l.count == r.count else { return false }
            for (k, v) in l {
                guard let rv = r[k], AnyCodable(v) == AnyCodable(rv) else { return false }
            }
            return true
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        // 与 == 保持一致：数值统一按 NSNumber 哈希，字符串/布尔/数组/字典各自哈希
        if let number = value as? NSNumber {
            hasher.combine(number)
        } else if let string = value as? String {
            hasher.combine(string)
        } else if let bool = value as? Bool {
            hasher.combine(bool)
        } else if let array = value as? [Any] {
            hasher.combine(array.map(AnyCodable.init))
        } else if let dict = value as? [String: Any] {
            var h = Hasher()
            for (k, v) in dict {
                h.combine(k)
                h.combine(AnyCodable(v))
            }
            hasher.combine(h.finalize())
        } else {
            hasher.combine(ObjectIdentifier(NSNull.self))
        }
    }
}