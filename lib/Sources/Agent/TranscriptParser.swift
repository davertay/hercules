import Foundation

public func parseTranscriptLine(_ data: Data) throws -> TranscriptLine {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type_ = obj["type"] as? String,
          type_.hasPrefix("hercules.")
    else {
        return .harness(rawJSON: data)
    }
    let event = try JSONDecoder.transcript.decode(HerculesEvent.self, from: data)
    return .hercules(event)
}

extension JSONDecoder {
    static let transcript: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithMilliseconds
        return d
    }()
}

extension JSONEncoder {
    static let transcript: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601WithMilliseconds
        return e
    }()
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithMilliseconds: Self = .custom { decoder in
        let s = try decoder.singleValueContainer().decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: s) { return date }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(s)")
        )
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithMilliseconds: Self = .custom { date, encoder in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var c = encoder.singleValueContainer()
        try c.encode(formatter.string(from: date))
    }
}
