import Accelerate
import Foundation

/// Tek bir ses kanalının (mikrofon ya da sistem sesi) akışını konuşma parçalarına böler ve
/// her parçaya toplantı saatine göre başlangıç zamanı verir. Ses iş parçacığından beslenir.
final class ChannelPipeline {
    let speaker: Speaker

    private let meetingStart: Date
    /// Test kipi: kanal saati duvar saatine değil bu sabit değere bağlanır
    private let fixedOffset: Double?
    private let onSegment: (Speaker, Double, [Float]) -> Void
    private let onLevel: (Float) -> Void

    private let lock = NSLock()
    private var segmenter = SpeechSegmenter()
    /// Kanalın ilk örneğinin toplantı saatindeki yeri (sn)
    private var offset: Double?
    private var lastArrival: Date?
    private var lastLevelPost = Date.distantPast

    /// - Parameters:
    ///   - onSegment: (konuşmacı, toplantı başından itibaren saniye, 16 kHz örnekler)
    ///   - onLevel: 0...1 arası anlık seviye, saniyede en çok ~12 kez
    init(speaker: Speaker, meetingStart: Date, fixedOffset: Double? = nil,
         onSegment: @escaping (Speaker, Double, [Float]) -> Void,
         onLevel: @escaping (Float) -> Void) {
        self.speaker = speaker
        self.meetingStart = meetingStart
        self.fixedOffset = fixedOffset
        self.onSegment = onSegment
        self.onLevel = onLevel
    }

    func ingest(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let now = Date()
        var finished: [(Double, [Float])] = []

        lock.lock()
        // Akış 1,5 sn'den uzun kesildiyse (aygıt değişimi vb.) örnek sayacı artık duvar saatini
        // göstermez: yarım parçayı kapat, kanal saatini yeniden kur.
        if fixedOffset == nil, let lastArrival, now.timeIntervalSince(lastArrival) > 1.5 {
            if let segment = segmenter.flush(), let offset {
                finished.append((offset + segment.startTime, segment.samples))
            }
            segmenter = SpeechSegmenter()
            offset = nil
        }
        lastArrival = now
        let base: Double
        if let offset {
            base = offset
        } else {
            base = fixedOffset
                ?? max(0, now.timeIntervalSince(meetingStart) - Double(chunk.count) / SpeechSegmenter.sampleRate)
            offset = base
        }
        for segment in segmenter.append(chunk) {
            finished.append((base + segment.startTime, segment.samples))
        }
        let postLevel = now.timeIntervalSince(lastLevelPost) > 0.08
        if postLevel { lastLevelPost = now }
        lock.unlock()

        for (start, samples) in finished { onSegment(speaker, start, samples) }
        if postLevel { onLevel(min(1, vDSP.rootMeanSquare(chunk) * 12)) }
    }

    /// Yakalama yeniden kuruldu (aygıt değişti): yarım parçayı kapat, saati sıfırla.
    func resync() {
        lock.lock()
        var finished: (Double, [Float])?
        if let segment = segmenter.flush(), let offset {
            finished = (offset + segment.startTime, segment.samples)
        }
        segmenter = SpeechSegmenter()
        offset = nil
        lastArrival = nil
        lock.unlock()
        if let finished { onSegment(speaker, finished.0, finished.1) }
    }

    /// Toplantı bitti: süren parça varsa döndürür.
    func finish() -> (start: Double, samples: [Float])? {
        lock.lock()
        defer { lock.unlock() }
        guard let segment = segmenter.flush(), let offset else { return nil }
        return (offset + segment.startTime, segment.samples)
    }
}
