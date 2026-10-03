import AVFoundation
import Foundation

/// Canlı ses seviyeleri. Saniyede onlarca kez değiştiği için oturumdan ayrı tutulur;
/// yalnız seviye göstergesi bunu izler, pencerenin geri kalanı yeniden çizilmez.
@MainActor
final class MeetingLevels: ObservableObject {
    @Published fileprivate(set) var mic: Float = 0
    @Published fileprivate(set) var system: Float = 0
}

/// Bir toplantının canlı akışı: mikrofonu ("Ben") ve Mac'te çalan sesi ("Karşı taraf") dinler,
/// konuşma parçalarını sırayla yazıya döker, dökümü depoya işler ve sonunda özet çıkarır.
@MainActor
final class MeetingSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        /// Kayıt durdu; sıradaki parçalar yazıya dökülüyor
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    /// Kaydı süren (ya da son parçaları işlenen) toplantı
    @Published private(set) var activeID: UUID?
    /// Özeti o an yazılan toplantı
    @Published private(set) var summarizingID: UUID?
    let levels = MeetingLevels()
    @Published private(set) var pendingSegments = 0
    /// Sistem sesi kanalından sıfırdan farklı ses geldi mi (izin verilmediyse hep sessiz kalır)
    @Published private(set) var systemAudioHeard = false
    @Published private(set) var micActive = false
    @Published var notice: String?
    /// Son özetin token ve süre ölçümü
    private(set) var lastSummaryStats: OllamaClient.ChatStats?
    /// nil ise ayardaki "toplantı bitince özet çıkar" tercihi geçerlidir
    var autoSummarize: Bool?

    private let transcription: TranscriptionService
    private let store: MeetingStore
    private let mic: AudioEngine
    private let settings = AppSettings.shared
    private let systemAudio = SystemAudioCapture()

    private var micPipeline: ChannelPipeline?
    private var systemPipeline: ChannelPipeline?

    private struct Pending {
        let speaker: Speaker
        let start: Double
        let samples: [Float]
    }

    private var queue: [Pending] = []
    private var worker: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?

    init(transcription: TranscriptionService, store: MeetingStore, mic: AudioEngine) {
        self.transcription = transcription
        self.store = store
        self.mic = mic
    }

    var isBusy: Bool { phase != .idle }

    // MARK: - Başlat / bitir

    /// - Returns: Başlayan toplantının kimliği; başlatılamadıysa nil (neden `notice`'te).
    @discardableResult
    func start() async -> UUID? {
        guard phase == .idle else { return activeID }
        guard transcription.isReady else {
            notice = "Model henüz hazır değil; yüklenince yeniden dene."
            return nil
        }
        notice = nil

        var micAllowed = AudioEngine.microphoneAuthorized
        if !micAllowed, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            micAllowed = await AudioEngine.requestMicrophonePermission()
        }
        // İzin penceresi beklerken başka bir başlatma araya girmiş olabilir
        guard phase == .idle else { return activeID }

        if settings.freeOllamaOnMeetingStart, summarizingID == nil {
            Task.detached { await OllamaClient.unloadLargeModels() }
        }

        let id = begin(at: Date(), fixedOffset: nil)

        // Kapanışlar ses iş parçacığında çalışır; oturumun alanlarına değil, kendi kilidi olan
        // hat nesnesine dokunurlar.
        guard let micPipeline, let systemPipeline else { return nil }

        var systemStarted = false
        systemAudio.chunkHandler = { chunk in systemPipeline.ingest(chunk) }
        systemAudio.restartHandler = { systemPipeline.resync() }
        do {
            try systemAudio.start()
            systemStarted = true
        } catch {
            Log.write("Sistem sesi başlatılamadı: \(error.localizedDescription)")
        }

        var micStarted = false
        if micAllowed {
            mic.streamRestartHandler = { micPipeline.resync() }
            do {
                try mic.startStreaming { chunk in micPipeline.ingest(chunk) }
                micStarted = true
            } catch {
                Log.write("Mikrofon akışı başlatılamadı: \(error.localizedDescription)")
            }
        }
        micActive = micStarted

        guard systemStarted || micStarted else {
            notice = "Ne mikrofon ne sistem sesi açılabildi; toplantı başlatılamadı."
            clearActive()
            store.discardEmpty(id)
            return nil
        }
        if !systemStarted {
            notice = "Sistem sesi yakalanamadı: yalnız mikrofon yazıya dökülecek."
        } else if !micStarted {
            notice = micAllowed
                ? "Mikrofon açılamadı: yalnız karşı tarafın sesi yazıya dökülecek."
                : "Mikrofon izni yok: yalnız karşı tarafın sesi yazıya dökülecek."
        }
        Log.write("Toplantı başladı (mikrofon: \(micStarted), sistem sesi: \(systemStarted))")
        return id
    }

    /// Kaydı durdurur; sıradaki parçalar yazıya dökülünce özet başlar.
    func finish() {
        guard phase == .recording, let id = activeID else { return }
        phase = .finishing
        systemAudio.stop()
        mic.stopStreaming()
        store.update(id) { $0.endedAt = Date() }
        Task { @MainActor in
            // Ses iş parçacıklarından yoldaki son parçalar ana kuyruğa ulaşsın
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self.complete(id)
        }
    }

    /// Uygulama kapanıyor: yakalamayı durdur ve bitiş saatini yaz. Döküm satırları geldikçe
    /// kaydedildiği için o ana kadarki döküm durur; özet sonradan pencereden çıkarılabilir.
    func stopForTermination() {
        guard phase == .recording, let id = activeID else { return }
        systemAudio.stop()
        mic.stopStreaming()
        store.update(id) { $0.endedAt = Date() }
        Log.write("Uygulama kapanırken toplantı kaydı durduruldu")
    }

    private func begin(at date: Date, fixedOffset: Double?) -> UUID {
        let meeting = Meeting(title: MeetingStore.defaultTitle(for: date), startedAt: date,
                              folderName: MeetingStore.folderName(for: date))
        store.add(meeting)
        activeID = meeting.id
        phase = .recording
        systemAudioHeard = false
        levels.mic = 0
        levels.system = 0

        micPipeline = ChannelPipeline(
            speaker: .me, meetingStart: date, fixedOffset: fixedOffset,
            onSegment: { [weak self] speaker, start, samples in
                Task { @MainActor in self?.enqueue(Pending(speaker: speaker, start: start, samples: samples)) }
            },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.levels.mic = level }
            }
        )
        systemPipeline = ChannelPipeline(
            speaker: .them, meetingStart: date, fixedOffset: fixedOffset,
            onSegment: { [weak self] speaker, start, samples in
                Task { @MainActor in self?.enqueue(Pending(speaker: speaker, start: start, samples: samples)) }
            },
            onLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self else { return }
                    self.levels.system = level
                    if level > 0.0005, !self.systemAudioHeard { self.systemAudioHeard = true }
                }
            }
        )
        return meeting.id
    }

    private func complete(_ id: UUID) async {
        for pipeline in [micPipeline, systemPipeline] {
            if let pipeline, let last = pipeline.finish() {
                enqueue(Pending(speaker: pipeline.speaker, start: last.start, samples: last.samples))
            }
        }
        micPipeline = nil
        systemPipeline = nil
        levels.mic = 0
        levels.system = 0

        while let worker { await worker.value }

        clearActive()
        guard let meeting = store.meeting(id) else { return }
        guard !meeting.lines.isEmpty else {
            store.discardEmpty(id)
            notice = "Konuşma algılanmadı; toplantı kaydedilmedi."
            Log.write("Toplantı boş bitti, kayıt atıldı")
            return
        }
        Log.write("Toplantı bitti: \(meeting.lines.count) satır, \(Meeting.durationLabel(meeting.duration))")
        if autoSummarize ?? settings.summaryEnabled { summarize(id) }
    }

    private func clearActive() {
        phase = .idle
        activeID = nil
        micActive = false
        pendingSegments = 0
    }

    // MARK: - Yazıya döküm sırası

    private func enqueue(_ item: Pending) {
        guard activeID != nil else { return }
        queue.append(item)
        pendingSegments = queue.count
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while !self.queue.isEmpty {
                let item = self.queue.removeFirst()
                self.pendingSegments = self.queue.count
                await self.transcribe(item)
            }
            self.worker = nil
        }
    }

    private func transcribe(_ item: Pending) async {
        guard let id = activeID else { return }
        do {
            let started = Date()
            let output = try await transcription.transcribeDetailed(item.samples, language: settings.language.whisperCode)
            let text = output.text
            Log.write(String(format: "Parça: %@ %@ · %.1f sn ses → %.1f sn'de yazıldı (%d karakter%@)",
                             item.speaker.label, Meeting.clock(item.start),
                             Double(item.samples.count) / SpeechSegmenter.sampleRate,
                             Date().timeIntervalSince(started), text.count,
                             output.temperature > 0 ? String(format: ", yedek tur %.1f", output.temperature) : ""))
            guard !text.isEmpty, !HallucinationFilter.isHallucination(text) else { return }
            // Whisper'ın kendi "konuşma yok" ölçütü: ses var ama söz değil (müzik, gürültü)
            if output.noSpeechProb > 0.6, output.avgLogprob < -1 { return }
            let line = TranscriptLine(
                speaker: item.speaker,
                start: item.start,
                end: item.start + Double(item.samples.count) / SpeechSegmenter.sampleRate,
                text: text
            )
            add(line, to: id)
        } catch {
            Log.write("Parça yazıya dökülemedi: \(error.localizedDescription)")
        }
    }

    /// Satırı başlangıç zamanına göre yerine koyar; hoparlörden mikrofona sızan kopyaları ayıklar.
    private func add(_ line: TranscriptLine, to id: UUID) {
        store.update(id) { meeting in
            if line.speaker == .me, EchoFilter.isEcho(line, in: meeting.lines) {
                Log.write("Yankı atıldı: \(line.text.prefix(60))")
                return
            }
            let index = meeting.lines.firstIndex { $0.start > line.start } ?? meeting.lines.count
            meeting.lines.insert(line, at: index)
            if line.speaker == .them {
                // Karşı tarafın satırı sonradan geldiyse, önceden eklenmiş mikrofon kopyasını da çıkar
                let all = meeting.lines
                meeting.lines.removeAll { other in
                    guard other.speaker == .me,
                          other.end > line.start - EchoFilter.slack,
                          other.start < line.end + EchoFilter.slack,
                          EchoFilter.isEcho(other, in: all)
                    else { return false }
                    Log.write("Yankı atıldı (sonradan): \(other.text.prefix(60))")
                    return true
                }
            }
        }
    }

    // MARK: - Özet

    /// Dökümden özet çıkarır (yeniden özetleme için de kullanılır).
    func summarize(_ id: UUID) {
        guard summarizingID == nil, let meeting = store.meeting(id), !meeting.lines.isEmpty else { return }
        summarizingID = id
        notice = nil
        let previous = meeting.summary
        let model = settings.ollamaModel
        store.update(id, persist: false) { $0.summary = "" }

        summaryTask = Task { @MainActor in
            defer {
                self.summarizingID = nil
                self.summaryTask = nil
            }
            do {
                let result = try await MeetingSummarizer.summarize(
                    meeting: meeting, model: model, language: self.settings.language
                ) { partial in
                    self.store.update(id, persist: false) { $0.summary = partial }
                }
                self.store.update(id) { meeting in
                    meeting.summary = result.body
                    meeting.summaryModel = model
                    if !meeting.titleEdited, let title = result.title { meeting.title = title }
                }
                self.lastSummaryStats = result.stats
                Log.write(String(format: "Özet hazır: %d istem + %d yanıt token, %.0f sn (%@)",
                                 result.stats.promptTokens, result.stats.outputTokens, result.stats.seconds, model))
            } catch {
                self.store.update(id, persist: false) { $0.summary = previous }
                self.notice = "Özet çıkarılamadı: \(error.localizedDescription)"
                Log.write("Özet hatası: \(error)")
            }
        }
    }

    /// Süren özet bitene kadar bekler (test için).
    func waitForSummary() async {
        while let summaryTask { await summaryTask.value }
    }

    // MARK: - Test (dosyadan besleme)

    /// Ses aygıtı açmadan toplantı başlatır; örnekler `ingestForTest` ile verilir ve kanal
    /// saatleri örnek sayısından hesaplanır.
    func startForTest() -> UUID {
        begin(at: Date(), fixedOffset: 0)
    }

    func ingestForTest(_ speaker: Speaker, _ chunk: [Float]) {
        (speaker == .me ? micPipeline : systemPipeline)?.ingest(chunk)
    }

    /// - Parameter duration: Beslenen sesin uzunluğu (hızlandırılmış beslemede duvar saati yanıltır)
    func finishForTest(duration: TimeInterval) async {
        guard phase == .recording, let id = activeID else { return }
        phase = .finishing
        store.update(id) { $0.endedAt = $0.startedAt.addingTimeInterval(duration) }
        // ingestForTest'in ana kuyruğa bıraktığı parçalar işlensin
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await complete(id)
    }
}
