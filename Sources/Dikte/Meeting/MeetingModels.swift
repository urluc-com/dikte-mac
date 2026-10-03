import Foundation

/// Toplantıdaki iki ses kanalı: mikrofon (ben) ve Mac'te çalan ses (karşı taraf).
enum Speaker: String, Codable {
    case me
    case them

    var label: String {
        switch self {
        case .me:   return "Ben"
        case .them: return "Karşı taraf"
        }
    }
}

/// Dökümün tek satırı: bir konuşmacının duraksamadan söylediği parça.
struct TranscriptLine: Identifiable, Codable, Equatable {
    var id = UUID()
    var speaker: Speaker
    /// Toplantının başından itibaren saniye
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// Aynı konuşmacının art arda satırları, okunur bir paragraf olarak.
struct TranscriptBlock: Identifiable, Equatable {
    let id: UUID
    let speaker: Speaker
    let start: TimeInterval
    var text: String
}

struct Meeting: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// Başlığı kullanıcı elle değiştirdiyse özet onu ezmez
    var titleEdited = false
    var startedAt: Date
    var endedAt: Date?
    var lines: [TranscriptLine] = []
    var summary = ""
    var summaryModel = ""
    /// Depodaki klasör adı
    var folderName: String

    var duration: TimeInterval {
        if let endedAt { return endedAt.timeIntervalSince(startedAt) }
        return lines.last?.end ?? 0
    }

    /// Aynı konuşmacının art arda satırlarını birleştirir; uzun bir aradan sonra yeni paragraf açar.
    var blocks: [TranscriptBlock] {
        var result: [TranscriptBlock] = []
        var lastEnd: TimeInterval = 0
        for line in lines {
            if var last = result.last, last.speaker == line.speaker, line.start - lastEnd < 30 {
                last.text += " " + line.text
                result[result.count - 1] = last
            } else {
                result.append(TranscriptBlock(id: line.id, speaker: line.speaker, start: line.start, text: line.text))
            }
            lastEnd = line.end
        }
        return result
    }

    /// Dökümün düz metin hali: "[02:15] Ben: …"
    var transcriptText: String {
        blocks.map { "[\(Self.clock($0.start))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n")
    }

    var transcriptMarkdown: String {
        var out = "# \(title)\n\(Self.dateLabel(startedAt)) · \(Self.durationLabel(duration))\n"
        for block in blocks {
            out += "\n**\(block.speaker.label)** (\(Self.clock(block.start)))\n\(block.text)\n"
        }
        return out
    }

    var summaryMarkdown: String {
        "# \(title)\n\(Self.dateLabel(startedAt)) · \(Self.durationLabel(duration))\n\n\(summary)\n"
    }

    // MARK: - Biçimleme

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(max(1, Int(seconds.rounded()))) sn" }
        if minutes < 60 { return "\(minutes) dk" }
        return "\(minutes / 60) sa \(minutes % 60) dk"
    }

    static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy HH:mm"
        return formatter.string(from: date)
    }

    static func shortDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }
}
