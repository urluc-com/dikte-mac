import AVFoundation

/// Mikrofonu 16 kHz mono Float32 PCM olarak yakalar (Whisper'ın beklediği format).
/// İki kip var: bas-konuş (startRecording/stopRecording, örnekleri biriktirir) ve
/// toplantı (startStreaming, parçaları geldikçe verir).
final class AudioEngine {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    private var resampler: Resampler16k?
    private var streamHandler: (([Float]) -> Void)?
    private var configObserver: NSObjectProtocol?

    /// 0...1 arası anlık ses seviyesi (UI animasyonu için)
    var levelHandler: ((Float) -> Void)?
    /// Toplantı kipinde giriş aygıtı değişip akış yeniden kurulduğunda çağrılır.
    var streamRestartHandler: (() -> Void)?

    private(set) var isRecording = false
    var isStreaming: Bool { streamHandler != nil }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Bas-konuş

    func startRecording() throws {
        guard !isRecording, !isStreaming else { return }
        samplesLock.lock(); samples.removeAll(); samplesLock.unlock()
        try startEngine()
        isRecording = true
    }

    @discardableResult
    func stopRecording() -> [Float] {
        guard isRecording else { return [] }
        stopEngine()
        isRecording = false
        samplesLock.lock()
        let result = samples
        samples.removeAll()
        samplesLock.unlock()
        Log.write("Kayıt bitti: \(result.count) örnek (~\(String(format: "%.1f", Double(result.count) / 16_000)) sn)")
        return result
    }

    // MARK: - Toplantı (kesintisiz akış)

    /// Parçalar ses iş parçacığında gelir. Giriş aygıtı değişirse (kulaklık takma vb.)
    /// akış kendini yeniden kurar ve `streamRestartHandler` çağrılır.
    func startStreaming(handler: @escaping ([Float]) -> Void) throws {
        guard !isRecording, !isStreaming else { return }
        streamHandler = handler
        do {
            try startEngine()
        } catch {
            streamHandler = nil
            throw error
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func stopStreaming() {
        guard isStreaming else { return }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        stopEngine()
        streamHandler = nil
        Log.write("Mikrofon akışı durdu")
    }

    private func handleConfigurationChange() {
        guard isStreaming else { return }
        Log.write("Mikrofon aygıtı değişti; akış yeniden kuruluyor")
        stopEngine()
        restartStreaming(attempt: 1)
    }

    private func restartStreaming(attempt: Int) {
        guard isStreaming else { return }
        do {
            try startEngine()
            streamRestartHandler?()
        } catch {
            // Aygıt değişiminin hemen ardından giriş biçimi kısa süre 0 Hz görünebilir
            guard attempt < 5 else {
                Log.write("Mikrofon akışı yeniden kurulamadı: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restartStreaming(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Ortak

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let resampler = Resampler16k(from: inputFormat) else {
            throw NSError(domain: "Dikte", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Mikrofon girişi bulunamadı."])
        }
        self.resampler = resampler

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        Log.write("Kayıt başladı (giriş: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) kanal)")
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let chunk = resampler?.convert(buffer), !chunk.isEmpty else { return }

        if let streamHandler {
            streamHandler(chunk)
        } else {
            samplesLock.lock()
            samples.append(contentsOf: chunk)
            samplesLock.unlock()
        }

        // RMS -> 0...1 seviye
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let level = min(1, rms * 20)
        DispatchQueue.main.async { [weak self] in
            self?.levelHandler?(level)
        }
    }
}
