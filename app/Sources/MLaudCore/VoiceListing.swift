import Foundation

/// Вывод `python -m mlaud_worker.voices list --json`: кто в базе и какие образцы.
public struct VoiceSample: Decodable, Equatable, Sendable {
    public let id: String
    public let sourceFile: String
    public let label: String
    public let speechSec: Double
    public let channel: String
    public let added: String

    enum CodingKeys: String, CodingKey {
        case id, label, channel, added
        case sourceFile = "source_file"
        case speechSec = "speech_sec"
    }
}

public struct VoicePerson: Decodable, Equatable, Sendable {
    public let name: String
    public let created: String
    public let samples: [VoiceSample]
}

public struct VoiceListing: Decodable, Equatable, Sendable {
    public let root: String
    public let people: [VoicePerson]

    public static func parse(_ data: Data) throws -> VoiceListing {
        try JSONDecoder().decode(VoiceListing.self, from: data)
    }

    public var names: [String] { people.map(\.name) }
}
