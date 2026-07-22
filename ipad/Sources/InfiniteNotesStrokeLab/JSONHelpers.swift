import Foundation

enum JSONHelpers {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func object<T: Encodable>(from value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    static func data(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}
