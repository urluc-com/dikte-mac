import AppKit
import Foundation

/// Toplantıların diskteki deposu. Her toplantı kendi klasöründe durur:
/// `toplanti.json` (asıl kayıt) + okunur kopyalar `Döküm.md` ve `Özet.md`.
@MainActor
final class MeetingStore: ObservableObject {
    /// Yeniden eskiye
    @Published private(set) var meetings: [Meeting] = []
    let baseURL: URL

    nonisolated static var defaultBaseURL: URL {
        AppSettings.supportURL.appendingPathComponent("Toplantilar", isDirectory: true)
    }

    init(baseURL: URL = MeetingStore.defaultBaseURL) {
        self.baseURL = baseURL
        load()
    }

    func meeting(_ id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func folderURL(for meeting: Meeting) -> URL {
        baseURL.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        write(meeting)
    }

    /// - Parameter persist: false ise yalnız bellekteki kopya güncellenir (akan özet gibi sık değişimler)
    func update(_ id: UUID, persist: Bool = true, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        if persist { write(meetings[index]) }
    }

    /// Klasörü Çöp Sepeti'ne taşır (geri alınabilir).
    func trash(_ id: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let folder = folderURL(for: meetings[index])
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            Log.write("Toplantı çöpe taşınamadı: \(error.localizedDescription)")
        }
        meetings.remove(at: index)
    }

    /// Hiç konuşma çıkmamış boş kaydı tamamen kaldırır.
    func discardEmpty(_ id: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == id }), meetings[index].lines.isEmpty else { return }
        try? FileManager.default.removeItem(at: folderURL(for: meetings[index]))
        meetings.remove(at: index)
    }

    func revealInFinder(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([folderURL(for: meeting)])
    }

    // MARK: - Adlandırma

    static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }

    static func defaultTitle(for date: Date) -> String {
        "Toplantı — \(Meeting.shortDateLabel(date))"
    }

    // MARK: - Disk

    private static let recordName = "toplanti.json"

    private func load() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [Meeting] = []
        for folder in folders {
            let record = folder.appendingPathComponent(Self.recordName)
            guard let data = try? Data(contentsOf: record) else { continue }
            do {
                loaded.append(try decoder.decode(Meeting.self, from: data))
            } catch {
                Log.write("Toplantı kaydı okunamadı (\(folder.lastPathComponent)): \(error.localizedDescription)")
            }
        }
        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    private func write(_ meeting: Meeting) {
        let folder = folderURL(for: meeting)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(meeting).write(to: folder.appendingPathComponent(Self.recordName), options: .atomic)
            try meeting.transcriptMarkdown.write(to: folder.appendingPathComponent("Döküm.md"),
                                                 atomically: true, encoding: .utf8)
            let summaryURL = folder.appendingPathComponent("Özet.md")
            if meeting.summary.isEmpty {
                try? FileManager.default.removeItem(at: summaryURL)
            } else {
                try meeting.summaryMarkdown.write(to: summaryURL, atomically: true, encoding: .utf8)
            }
        } catch {
            Log.write("Toplantı kaydedilemedi: \(error.localizedDescription)")
        }
    }
}
