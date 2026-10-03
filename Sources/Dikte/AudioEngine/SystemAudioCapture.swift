import AVFoundation
import AudioToolbox
import CoreAudio

/// Mac'te çalan bütün sesi (tarayıcı, Teams, Slack, Zoom…) Core Audio "process tap" ile
/// yakalar ve 16 kHz mono Float32 olarak verir. Ses, işletim sisteminin çıkışından alındığı
/// için hangi uygulamanın çaldığı fark etmez.
///
/// İlk kullanımda macOS "sistem sesini kaydetme" izni sorar (Info.plist:
/// NSAudioCaptureUsageDescription). İzin verilmezse akış gelir ama sessizdir (hep sıfır).
final class SystemAudioCapture {
    /// ~100 ms'lik 16 kHz mono parçalar; yakalama kuyruğunda çağrılır.
    var chunkHandler: (([Float]) -> Void)?
    /// Çıkış aygıtı değişip yakalama yeniden kurulduğunda çağrılır.
    var restartHandler: (() -> Void)?

    private let queue = DispatchQueue(label: "dikte.sistem-sesi", qos: .userInitiated)
    private var running = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sourceFormat: AVAudioFormat?
    private var resampler: Resampler16k?
    private var batch: [Float] = []
    private var loggedLayout = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var rebuildPending = false

    /// Bir parçada en az bu kadar örnek birikince teslim edilir (100 ms)
    private static let batchSize = 1_600

    var isRunning: Bool { queue.sync { running } }

    func start() throws {
        try queue.sync {
            guard !running else { return }
            do {
                try build()
            } catch {
                teardown()
                throw error
            }
            installOutputDeviceListener()
            running = true
        }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            running = false
            removeOutputDeviceListener()
            teardown()
            Log.write("Sistem sesi yakalama durdu")
        }
    }

    // MARK: - Kurulum

    private func build() throws {
        // 1) Tap: bütün süreçlerin çıkışı, mono karışım. Kendi sürecimiz ses çalmadığı için
        //    dışlanacak süreç yok.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Dikte Toplantı"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "Ses tap'i oluşturulamadı")
        tapID = tap

        var tapFormat = AudioStreamBasicDescription()
        try Self.read(tapID, kAudioTapPropertyFormat, &tapFormat, "Tap biçimi okunamadı")
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32
        else {
            throw Self.error("Beklenmeyen tap biçimi (Float32 değil)", code: -1)
        }

        // 2) Tap'i okuyabilmek için ona saat veren özel bir aggregate aygıt gerekir;
        //    saat kaynağı o anki varsayılan çıkış aygıtı.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dikte Toplantı",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // false: akış hemen başlasın, ses çalan yokken de (sessiz) sürsün
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]
            ]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
            "Aggregate aygıt oluşturulamadı"
        )
        aggregateID = aggregate

        // 3) IOProc verisi aggregate aygıtın hızında gelir
        var sampleRate = Float64(0)
        if (try? Self.read(aggregateID, kAudioDevicePropertyNominalSampleRate, &sampleRate, "")) == nil || sampleRate <= 0 {
            sampleRate = tapFormat.mSampleRate
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let resampler = Resampler16k(from: format)
        else {
            throw Self.error("Ses dönüştürücü kurulamadı (\(Int(sampleRate)) Hz)", code: -2)
        }
        sourceFormat = format
        self.resampler = resampler
        batch.removeAll(keepingCapacity: true)
        loggedLayout = false

        // 4) Okuma
        var proc: AudioDeviceIOProcID?
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
                self?.handle(inInputData)
            },
            "Ses okuma bloğu kurulamadı"
        )
        procID = proc
        try Self.check(AudioDeviceStart(aggregateID, procID), "Sistem sesi yakalama başlatılamadı")

        Log.write("Sistem sesi yakalama başladı (tap: \(Int(tapFormat.mSampleRate)) Hz \(tapFormat.mChannelsPerFrame) kanal, aygıt: \(Int(sampleRate)) Hz, çıkış: \(outputUID))")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        resampler = nil
        sourceFormat = nil
        batch.removeAll()
    }

    // MARK: - Veri

    private func handle(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let resampler, let sourceFormat else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        // Çıkış aygıtının kendi giriş akışı varsa (USB kulaklık vb.) tamponlarda tap'ten önce
        // gelir; tap'in tamponu sonuncudur.
        guard let last = buffers.last, let data = last.mData else { return }
        let channels = max(1, Int(last.mNumberChannels))
        let frames = Int(last.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
        guard frames > 0 else { return }

        if !loggedLayout {
            loggedLayout = true
            Log.write("Sistem sesi ilk tampon: \(buffers.count) tampon, sonuncusu \(channels) kanal × \(frames) çerçeve")
        }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let target = pcm.floatChannelData?[0]
        else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let source = data.assumingMemoryBound(to: Float32.self)
        if channels == 1 {
            target.update(from: source, count: frames)
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[frame * channels + channel] }
                target[frame] = sum / Float(channels)
            }
        }

        guard let chunk = resampler.convert(pcm), !chunk.isEmpty else { return }
        batch.append(contentsOf: chunk)
        if batch.count >= Self.batchSize {
            let out = batch
            batch.removeAll(keepingCapacity: true)
            chunkHandler?(out)
        }
    }

    // MARK: - Çıkış aygıtı değişimi

    private func installOutputDeviceListener() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.outputDeviceChanged()
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        deviceListener = block
    }

    private func removeOutputDeviceListener() {
        guard let deviceListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        self.deviceListener = nil
    }

    /// Kulaklık takılıp çıkarıldığında saat kaynağı değişir; yakalamayı yeni aygıtla yeniden kur.
    private func outputDeviceChanged() {
        guard running, !rebuildPending else { return }
        rebuildPending = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rebuild(attempt: 1)
        }
    }

    private func rebuild(attempt: Int) {
        guard running else { rebuildPending = false; return }
        Log.write("Çıkış aygıtı değişti; sistem sesi yakalama yeniden kuruluyor (deneme \(attempt))")
        teardown()
        do {
            try build()
            rebuildPending = false
            restartHandler?()
        } catch {
            teardown()
            guard attempt < 5 else {
                rebuildPending = false
                Log.write("Sistem sesi yakalama yeniden kurulamadı: \(error.localizedDescription)")
                return
            }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.rebuild(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Core Audio yardımcıları

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ value: inout T, _ what: String) throws {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, what)
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                 &deviceID, "Varsayılan çıkış aygıtı okunamadı")
        var uid: Unmanaged<CFString>?
        try read(deviceID, kAudioDevicePropertyDeviceUID, &uid, "Çıkış aygıtının kimliği okunamadı")
        guard let uid else { throw error("Çıkış aygıtının kimliği boş", code: -3) }
        return uid.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw error("\(what) (hata \(status))", code: Int(status)) }
    }

    private static func error(_ message: String, code: Int) -> NSError {
        NSError(domain: "Dikte.SistemSesi", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
