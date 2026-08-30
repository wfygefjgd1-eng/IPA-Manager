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
        case let num as NSNumber:
            // Foundation 桥接中任意 NSNumber 的 `as? Bool` 都会成功（按 boolValue
            // 转换）——旧实现把 Bool 分支放在数值之前，PropertyListSerialization
            // 解出的数值 2 会被编码成 true、1.5 编码成 true（值丢失、类型改变）。
            // 用 CFBoolean 类型判断精确区分布尔；数值再按 objCType 保真编码。
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                try container.encode(num.boolValue)
            } else {
                // 用 64 位读写避免 "q"/"Q"（long long）等类型被 32 位 intValue/uintValue 截断
                switch String(cString: num.objCType) {
                case "i", "l", "q": try container.encode(num.int64Value)
                case "I", "L", "Q": try container.encode(num.uint64Value)
                case "f": try container.encode(num.floatValue)
                default: try container.encode(num.doubleValue)
                }
            }
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
        // 与 == 的数值语义（NSNumber isEqualToNumber 跨类型数值相等）保持一致：
        // 统一按 doubleValue 哈希（1 / 1.0 / true 哈希一致）。NSNumber.hash 不保证
        // 跨类型一致，等值对象可能哈希不同，违反 Hashable 不变式。
        if let number = value as? NSNumber {
            hasher.combine(number.doubleValue)
        } else if let string = value as? String {
            hasher.combine(string)
        } else if let array = value as? [Any] {
            hasher.combine(array.map(AnyCodable.init))
        } else if let dict = value as? [String: Any] {
            // 按键排序后 combine：字典迭代顺序不定，相等的两个字典必须产生相同哈希
            for key in dict.keys.sorted() {
                hasher.combine(key)
                hasher.combine(AnyCodable(dict[key] ?? NSNull()))
            }
        } else {
            hasher.combine(ObjectIdentifier(NSNull.self))
        }
    }
}