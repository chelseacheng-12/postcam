import Foundation

struct CaptureItem: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: Kind
    var createdAt: Date
    var duration: TimeInterval?

    enum Kind: String, Codable {
        case photo
        case video
    }
}

enum DurationFormat {
    static func clock(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func live(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        let tenths = Int((clamped - floor(clamped)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}

enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
