import AVFoundation

/// Mikrofonu 16 kHz mono Float32 PCM olarak yakalar (Whisper'ın beklediği format).
final class AudioEngine {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// 0...1 arası anlık ses seviyesi (UI animasyonu için)
    var levelHandler: ((Float) -> Void)?

    private(set) var isRecording = false

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func startRecording() throws {
        guard !isRecording else { return }
        samplesLock.lock(); samples.removeAll(); samplesLock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Dikte", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Mikrofon girişi bulunamadı."])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        Log.write("Kayıt başladı (giriş: \(Int(inputFormat.sampleRate)) Hz)")
    }

    @discardableResult
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        samplesLock.lock()
        let result = samples
        samples.removeAll()
        samplesLock.unlock()
        Log.write("Kayıt bitti: \(result.count) örnek (~\(String(format: "%.1f", Double(result.count) / 16_000)) sn)")
        return result
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        converter.convert(to: outBuffer, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let convError {
            Log.write("Ses dönüştürme hatası: \(convError.localizedDescription)")
            return
        }
        guard let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))

        samplesLock.lock()
        samples.append(contentsOf: chunk)
        samplesLock.unlock()

        // RMS -> 0...1 seviye
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let level = min(1, rms * 20)
        DispatchQueue.main.async { [weak self] in
            self?.levelHandler?(level)
        }
    }
}
