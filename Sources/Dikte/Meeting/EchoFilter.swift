import Foundation

/// Hoparlör kullanılırken mikrofon karşı tarafın sesini de duyar; aynı konuşma dökümde bir
/// "Karşı taraf", bir de "Ben" satırı olarak iki kez çıkar. Bu süzgeç, aynı anda sistem
/// sesinden gelen konuşmayla büyük ölçüde aynı kelimeleri taşıyan mikrofon satırını yakalar.
enum EchoFilter {
    /// Zaman penceresi payı (sn): iki kanalın parça sınırları birebir örtüşmez
    static let slack: TimeInterval = 2
    /// Mikrofon satırındaki kelimelerin en az bu oranı karşı tarafta da geçiyorsa yankıdır
    static let minOverlap = 0.6

    static func isEcho(_ line: TranscriptLine, in lines: [TranscriptLine]) -> Bool {
        guard line.speaker == .me else { return false }
        let mine = tokens(line.text)
        guard !mine.isEmpty else { return false }

        var theirs: [String: Int] = [:]
        for other in lines
        where other.speaker == .them && other.end > line.start - slack && other.start < line.end + slack {
            for token in tokens(other.text) { theirs[token, default: 0] += 1 }
        }
        guard !theirs.isEmpty else { return false }

        var matched = 0
        for token in mine {
            if let count = theirs[token], count > 0 {
                theirs[token] = count - 1
                matched += 1
            }
        }
        return Double(matched) / Double(mine.count) >= minOverlap
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
