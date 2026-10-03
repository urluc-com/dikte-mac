import Accelerate
import Foundation

/// Bir kanaldan kesilen tek konuşma parçası.
struct SpeechSegment {
    /// Kanalın başından itibaren örnek sırası (16 kHz)
    let startSample: Int
    let samples: [Float]

    var startTime: Double { Double(startSample) / SpeechSegmenter.sampleRate }
    var duration: Double { Double(samples.count) / SpeechSegmenter.sampleRate }
}

/// 16 kHz mono akışı enerjiye bakarak konuşma parçalarına böler.
///
/// Whisper 30 sn'lik pencereyle çalıştığı için parçalar bunu aşmamalı: konuşmacı durunca
/// (0,7 sn sessizlik) parça kapanır; 12 sn'yi geçen konuşma ilk kısa duraksamada, hiç
/// duraksama yoksa 27 sn'de en sessiz yerinden bölünür.
///
/// Gürültü tabanı son 3 sn'nin en sessiz çerçevesinden alınır; böylece klima ya da fan gibi
/// sürekli gürültü konuşma sayılmaz. Thread-safe değildir, tek yerden çağrılmalı.
final class SpeechSegmenter {
    static let sampleRate: Double = 16_000

    struct Config {
        /// 30 ms
        var frameSize = 480
        /// Mutlak alt eşik (RMS), yaklaşık -48 dBFS
        var minThreshold: Float = 0.004
        var maxThreshold: Float = 0.05
        /// Eşik = gürültü tabanı × bu kat
        var noiseMultiplier: Float = 3
        /// Gürültü tabanı penceresi: 100 çerçeve = 3 sn
        var noiseWindowFrames = 100
        /// Konuşma başlangıcı için gereken art arda sesli çerçeve (90 ms)
        var startFrames = 3
        /// Başlangıçtan geriye alınan pay (300 ms)
        var preRollFrames = 10
        /// Parçayı kapatan sessizlik (690 ms)
        var endSilenceFrames = 23
        /// Bu uzunluktan sonra (12 sn) kısa duraksama da parçayı kapatır
        var softMaxFrames = 400
        var softSilenceFrames = 8
        /// Kesin üst sınır (27 sn)
        var hardMaxFrames = 900
        /// Bundan az sesli çerçevesi olan parça atılır (240 ms)
        var minSpeechFrames = 8
        /// Parçanın sonunda bırakılan sessizlik (210 ms)
        var tailKeepFrames = 7
    }

    private let config: Config
    private var pending: [Float] = []
    private var processedFrames = 0

    private var noiseWindow: [Float] = []
    private var noiseCursor = 0

    // Konuşma dışındayken tutulan son çerçeveler
    private var preRoll: [Float] = []
    private var preRollRMS: [Float] = []
    private var preRollVoiced: [Bool] = []
    private var voicedRun = 0

    // Süren parça
    private(set) var inSpeech = false
    private var current: [Float] = []
    private var currentRMS: [Float] = []
    private var currentVoiced: [Bool] = []
    private var currentStartSample = 0
    private var silenceRun = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Yeni örnekleri ekler; bu çağrıyla kapanan parçaları döndürür.
    func append(_ chunk: [Float]) -> [SpeechSegment] {
        pending.append(contentsOf: chunk)
        var finished: [SpeechSegment] = []
        let size = config.frameSize
        var offset = 0
        while pending.count - offset >= size {
            let frame = Array(pending[offset..<(offset + size)])
            offset += size
            if let segment = process(frame) { finished.append(segment) }
        }
        if offset > 0 { pending.removeFirst(offset) }
        return finished
    }

    /// Akış bitti: süren parça varsa kapatır.
    func flush() -> SpeechSegment? {
        guard inSpeech else { return nil }
        return closeCurrent()
    }

    // MARK: - Çerçeve işleme

    private func process(_ frame: [Float]) -> SpeechSegment? {
        let rms = vDSP.rootMeanSquare(frame)
        let voiced = rms > threshold(including: rms)
        processedFrames += 1

        guard inSpeech else {
            preRoll.append(contentsOf: frame)
            preRollRMS.append(rms)
            preRollVoiced.append(voiced)
            if preRollRMS.count > config.preRollFrames {
                preRoll.removeFirst(config.frameSize)
                preRollRMS.removeFirst()
                preRollVoiced.removeFirst()
            }
            voicedRun = voiced ? voicedRun + 1 : 0
            if voicedRun >= config.startFrames {
                inSpeech = true
                current = preRoll
                currentRMS = preRollRMS
                currentVoiced = preRollVoiced
                currentStartSample = processedFrames * config.frameSize - current.count
                silenceRun = 0
                clearPreRoll()
            }
            return nil
        }

        current.append(contentsOf: frame)
        currentRMS.append(rms)
        currentVoiced.append(voiced)
        silenceRun = voiced ? 0 : silenceRun + 1

        let frames = currentRMS.count
        if silenceRun >= config.endSilenceFrames
            || (frames >= config.softMaxFrames && silenceRun >= config.softSilenceFrames) {
            return closeCurrent()
        }
        if frames >= config.hardMaxFrames {
            return splitAtQuietest()
        }
        return nil
    }

    private func threshold(including rms: Float) -> Float {
        if noiseWindow.count < config.noiseWindowFrames {
            noiseWindow.append(rms)
        } else {
            noiseWindow[noiseCursor] = rms
            noiseCursor = (noiseCursor + 1) % config.noiseWindowFrames
        }
        let floor = vDSP.minimum(noiseWindow)
        return min(config.maxThreshold, max(config.minThreshold, floor * config.noiseMultiplier))
    }

    /// Süren parçayı kapatır; yeterince konuşma içermiyorsa nil döner.
    private func closeCurrent() -> SpeechSegment? {
        let dropped = max(0, silenceRun - config.tailKeepFrames)
        let keptFrames = currentRMS.count - dropped
        let speechFrames = currentVoiced.prefix(keptFrames).filter { $0 }.count
        let segment = speechFrames >= config.minSpeechFrames
            ? SpeechSegment(startSample: currentStartSample,
                            samples: Array(current.prefix(keptFrames * config.frameSize)))
            : nil

        inSpeech = false
        current.removeAll()
        currentRMS.removeAll()
        currentVoiced.removeAll()
        silenceRun = 0
        clearPreRoll()
        return segment
    }

    /// Üst sınıra dayanan konuşmayı son 3 sn'nin en sessiz çerçevesinden böler;
    /// kalan kısım yeni parçanın başı olur, ses kaybı olmaz.
    private func splitAtQuietest() -> SpeechSegment? {
        let frames = currentRMS.count
        let searchFrom = max(config.minSpeechFrames, frames - config.noiseWindowFrames)
        var quietest = searchFrom
        for index in searchFrom..<frames where currentRMS[index] < currentRMS[quietest] {
            quietest = index
        }
        let headFrames = quietest + 1
        let headSpeech = currentVoiced.prefix(headFrames).filter { $0 }.count
        let head = SpeechSegment(startSample: currentStartSample,
                                 samples: Array(current.prefix(headFrames * config.frameSize)))

        current.removeFirst(headFrames * config.frameSize)
        currentRMS.removeFirst(headFrames)
        currentVoiced.removeFirst(headFrames)
        currentStartSample += headFrames * config.frameSize
        silenceRun = currentVoiced.reversed().prefix { !$0 }.count

        return headSpeech >= config.minSpeechFrames ? head : nil
    }

    private func clearPreRoll() {
        preRoll.removeAll()
        preRollRMS.removeAll()
        preRollVoiced.removeAll()
        voicedRun = 0
    }
}
