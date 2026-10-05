import AppKit
import AVFoundation
import SwiftUI

/// Toplantı hattını uçtan uca, ölçerek çalıştırır ve çıkar. İki kipi var:
///
/// - Dosya kipi: iki ses dosyasını "karşı taraf" ve "ben" kanalı olarak besler; ses aygıtı da
///   izin de gerekmez (bölütleme → yazıya döküm → yankı süzgeci → depo → özet → pencere).
/// - Canlı kip: gerçek mikrofon ve sistem sesi yakalamayı N saniye çalıştırır.
///
/// Ortam değişkenleri:
///
///     DIKTE_TEST_CIKTI=<klasör>   zorunlu; sonuc.json, pencere-*.png ve test deposu buraya yazılır
///     DIKTE_TEST_SISTEM=<ses>     karşı taraf kanalı (dosya kipi)
///     DIKTE_TEST_MIK=<ses>        mikrofon kanalı (dosya kipi)
///     DIKTE_TEST_HIZ=<kat>        besleme hızı, gerçek zamanın katı (varsayılan 10)
///     DIKTE_TEST_CANLI=<sn>       canlı kip: bu kadar saniye dinle
///     DIKTE_TEST_DOKUM=<json>     ses yerine hazır döküm yükle (yalnız özeti sınamak için);
///                                 [{"konusmaci": "Ben"|"Karşı taraf", "baslangic", "bitis", "metin"}]
///     DIKTE_TEST_TAP=<sn>         yalnız sistem sesi yakalamayı dene: bu kadar saniye dinle, gelen
///                                 parça sayısını ve seviyeyi yaz, sesi tap.wav'a kaydet
///     DIKTE_TEST_GORUNUM=<adlar>  yalnız pencere görüntüsü al: "ayarlar", "kurulum" (virgülle)
///     DIKTE_TEST_MODEL=<ad>       ayardaki yerine bu Whisper modelini kullan (ör. openai_whisper-small)
///     DIKTE_TEST_ISLEMCI=1        modeli yalnız işlemcide çalıştır (Neural Engine'siz Mac kestirimi)
///     DIKTE_TEST_OZET=1           özet de çıkar
///     DIKTE_TEST_PENCERE=1        toplantı penceresini aç, görüntüsünü al
struct TestHarness {
    let outputURL: URL
    let systemFile: URL?
    let micFile: URL?
    let speed: Double
    let liveSeconds: Double?
    let transcriptFile: URL?
    let staticViews: [String]
    let tapSeconds: Double?
    let summarize: Bool
    let showWindow: Bool

    static func fromEnvironment() -> TestHarness? {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["DIKTE_TEST_CIKTI"], !output.isEmpty else { return nil }
        return TestHarness(
            outputURL: URL(fileURLWithPath: output, isDirectory: true),
            systemFile: env["DIKTE_TEST_SISTEM"].map { URL(fileURLWithPath: $0) },
            micFile: env["DIKTE_TEST_MIK"].map { URL(fileURLWithPath: $0) },
            speed: env["DIKTE_TEST_HIZ"].flatMap(Double.init) ?? 10,
            liveSeconds: env["DIKTE_TEST_CANLI"].flatMap(Double.init),
            transcriptFile: env["DIKTE_TEST_DOKUM"].map { URL(fileURLWithPath: $0) },
            staticViews: env["DIKTE_TEST_GORUNUM"]?.components(separatedBy: ",") ?? [],
            tapSeconds: env["DIKTE_TEST_TAP"].flatMap(Double.init),
            summarize: env["DIKTE_TEST_OZET"] == "1",
            showWindow: env["DIKTE_TEST_PENCERE"] == "1"
        )
    }

    /// Test toplantıları kullanıcının gerçek listesine karışmasın
    static var storeURL: URL? {
        fromEnvironment()?.outputURL.appendingPathComponent("Toplantilar", isDirectory: true)
    }

    @MainActor
    func run(transcription: TranscriptionService, session: MeetingSession, store: MeetingStore,
             window: MeetingWindowController, model: String) {
        Task { @MainActor in
            let env = ProcessInfo.processInfo.environment
            let model = env["DIKTE_TEST_MODEL"] ?? model
            transcription.cpuOnly = env["DIKTE_TEST_ISLEMCI"] == "1"
            var report: [String: Any] = ["model": model, "yalnizIslemci": transcription.cpuOnly]
            #if arch(x86_64)
            report["mimari"] = "x86_64"
            #else
            report["mimari"] = "arm64"
            #endif
            try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            if !staticViews.isEmpty {
                await snapshotStaticViews(transcription: transcription)
            }
            if let tapSeconds {
                await runTapProbe(seconds: tapSeconds)
            }
            if let transcriptFile {
                await runSummaryOnly(transcriptFile, session: session, store: store, window: window, report: report)
            }

            let loadStart = Date()
            await transcription.load(model: model)
            report["modelYuklemeSn"] = round1(Date().timeIntervalSince(loadStart))
            guard transcription.isReady else {
                report["hata"] = "Model yüklenemedi: \(transcription.state)"
                finish(report, code: 1)
            }
            report["bellekModelSonrasiMB"] = round1(MemoryProbe.footprintMB())
            session.autoSummarize = summarize

            let transcribeStart = Date()
            let id: UUID
            if let liveSeconds {
                guard let started = await session.start() else {
                    report["hata"] = "Toplantı başlatılamadı: \(session.notice ?? "?")"
                    finish(report, code: 1)
                }
                id = started
                if showWindow { window.show(selecting: id) }
                try? await Task.sleep(nanoseconds: UInt64(liveSeconds * 1e9))
                report["sistemSesiDuyuldu"] = session.systemAudioHeard
                report["mikrofonAcik"] = session.micActive
                if showWindow { window.snapshot(to: outputURL.appendingPathComponent("pencere-canli.png")) }
                session.finish()
                while session.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            } else {
                let system = systemFile.flatMap(Self.loadSamples) ?? []
                let mic = micFile.flatMap(Self.loadSamples) ?? []
                guard !system.isEmpty || !mic.isEmpty else {
                    report["hata"] = "Ses dosyası okunamadı"
                    finish(report, code: 1)
                }
                let seconds = Double(max(system.count, mic.count)) / SpeechSegmenter.sampleRate
                report["sesSn"] = round1(seconds)

                id = session.startForTest()
                if showWindow { window.showForTest(selecting: id) }
                await feed(system: system, mic: mic, into: session) {
                    if showWindow { window.snapshot(to: outputURL.appendingPathComponent("pencere-orta.png")) }
                }
                // Beslenen parçalar yazıya dökülsün ki canlı görüntü dolu çıksın
                try? await Task.sleep(nanoseconds: 300_000_000)
                while session.pendingSegments > 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if showWindow { window.snapshot(to: outputURL.appendingPathComponent("pencere-canli.png")) }
                await session.finishForTest(duration: seconds)
            }
            report["dokumSn"] = round1(Date().timeIntervalSince(transcribeStart))
            report["bellekDokumSonrasiMB"] = round1(MemoryProbe.footprintMB())

            if summarize {
                await session.waitForSummary()
                addSummaryStats(session, to: &report)
            }
            if let notice = session.notice { report["uyari"] = notice }

            if let meeting = store.meeting(id) {
                report["baslik"] = meeting.title
                report["satirSayisi"] = meeting.lines.count
                report["satirlar"] = meeting.lines.map { line in
                    [
                        "konusmaci": line.speaker.label,
                        "baslangic": round1(line.start),
                        "bitis": round1(line.end),
                        "metin": line.text
                    ] as [String: Any]
                }
                report["ozet"] = meeting.summary
                report["klasor"] = store.folderURL(for: meeting).path
            } else {
                report["satirSayisi"] = 0
            }
            report["bellekTepeMB"] = round1(MemoryProbe.peakFootprintMB())

            if showWindow {
                try? await Task.sleep(nanoseconds: 600_000_000)
                window.snapshot(to: outputURL.appendingPathComponent("pencere-son.png"))
            }
            finish(report, code: 0)
        }
    }

    /// Yalnız sistem sesi yakalamayı çalıştırır: tap kuruluyor mu, veri akıyor mu, ses var mı.
    /// İzin sorusu yanıtsız kalırsa kurulum dönmeyebilir; o durumda süre dolunca rapor yazıp çıkar.
    @MainActor
    private func runTapProbe(seconds: Double) async -> Never {
        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var chunks = 0
            var samples: [Float] = []
            var started: Bool?
            var error: String?
        }
        let tally = Tally()
        let capture = SystemAudioCapture()
        capture.chunkHandler = { chunk in
            tally.lock.lock()
            tally.chunks += 1
            tally.samples.append(contentsOf: chunk)
            tally.lock.unlock()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try capture.start()
                tally.lock.lock(); tally.started = true; tally.lock.unlock()
            } catch {
                tally.lock.lock(); tally.started = false; tally.error = error.localizedDescription; tally.lock.unlock()
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))

        let (started, chunks, samples, error) = tally.lock.withLock {
            (tally.started, tally.chunks, tally.samples, tally.error)
        }
        if started == true {
            DispatchQueue.global().async { capture.stop() }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        var report: [String: Any] = [
            "tapBasladi": started.map { $0 ? "evet" : "hayır" } ?? "kurulum dönmedi (izin sorusu bekliyor olabilir)",
            "parcaSayisi": chunks,
            "ornekSayisi": samples.count,
            "beklenenOrnek": Int(seconds * SpeechSegmenter.sampleRate),
            "sifirOlmayanOrnek": samples.filter { $0 != 0 }.count,
            "tepe": Double(samples.map { abs($0) }.max() ?? 0)
        ]
        if let error { report["hata"] = error }
        if !samples.isEmpty,
           let file = try? AVAudioFile(forWriting: outputURL.appendingPathComponent("tap.wav"),
                                       settings: Resampler16k.targetFormat.settings),
           let buffer = AVAudioPCMBuffer(pcmFormat: Resampler16k.targetFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) {
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            try? file.write(from: buffer)
        }
        finish(report, code: started == true ? 0 : 1)
    }

    /// Ayarlar ve kurulum pencerelerini arka planda açıp görüntülerini yazar.
    @MainActor
    private func snapshotStaticViews(transcription: TranscriptionService) async -> Never {
        for name in staticViews {
            let controller: NSViewController
            switch name {
            case "ayarlar":
                controller = NSHostingController(rootView: SettingsView(settings: .shared, transcription: transcription))
            case "kurulum":
                controller = NSHostingController(rootView: OnboardingView(onFinished: {}))
            default:
                continue
            }
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.orderBack(nil)
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: outputURL.appendingPathComponent("\(name).png"))
            }
            window.close()
        }
        finish(["gorunum": staticViews], code: 0)
    }

    /// Hazır dökümü toplantı olarak depoya koyar ve yalnız özeti çalıştırır.
    @MainActor
    private func runSummaryOnly(_ file: URL, session: MeetingSession, store: MeetingStore,
                                window: MeetingWindowController, report: [String: Any]) async -> Never {
        var report = report
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            report["hata"] = "Döküm dosyası okunamadı"
            finish(report, code: 1)
        }
        let lines = rows.compactMap { row -> TranscriptLine? in
            guard let text = row["metin"] as? String,
                  let start = (row["baslangic"] as? NSNumber)?.doubleValue,
                  let end = (row["bitis"] as? NSNumber)?.doubleValue
            else { return nil }
            let speaker: Speaker = (row["konusmaci"] as? String) == Speaker.me.label ? .me : .them
            return TranscriptLine(speaker: speaker, start: start, end: end, text: text)
        }
        let now = Date()
        var meeting = Meeting(title: MeetingStore.defaultTitle(for: now), startedAt: now,
                              folderName: MeetingStore.folderName(for: now))
        meeting.lines = lines
        meeting.endedAt = now.addingTimeInterval(lines.last?.end ?? 0)
        store.add(meeting)
        report["satirSayisi"] = lines.count
        report["dokumKarakter"] = meeting.transcriptText.count

        if showWindow { window.showForTest(selecting: meeting.id) }
        session.summarize(meeting.id)
        await session.waitForSummary()
        addSummaryStats(session, to: &report)
        if let notice = session.notice { report["uyari"] = notice }
        if let done = store.meeting(meeting.id) {
            report["baslik"] = done.title
            report["ozet"] = done.summary
            report["klasor"] = store.folderURL(for: done).path
        }
        if showWindow {
            try? await Task.sleep(nanoseconds: 600_000_000)
            window.snapshot(to: outputURL.appendingPathComponent("pencere-ozet.png"))
        }
        finish(report, code: 0)
    }

    @MainActor
    private func addSummaryStats(_ session: MeetingSession, to report: inout [String: Any]) {
        guard let stats = session.lastSummaryStats else { return }
        report["ozetSn"] = round1(stats.seconds)
        report["ozetIstemToken"] = stats.promptTokens
        report["ozetYanitToken"] = stats.outputTokens
    }

    /// İki kanalı aynı saatle, 100 ms'lik parçalarla besler.
    @MainActor
    private func feed(system: [Float], mic: [Float], into session: MeetingSession,
                      atMidpoint: () -> Void) async {
        let chunk = 1_600
        let total = max(system.count, mic.count)
        let pause = UInt64(0.1 / max(speed, 0.1) * 1e9)
        var position = 0
        var midpointDone = false
        while position < total {
            if !midpointDone, position >= total / 2 {
                midpointDone = true
                // Konuşma sürerken pencerenin hali ("konuşuyor…" satırı) görülsün
                try? await Task.sleep(nanoseconds: 150_000_000)
                atMidpoint()
            }
            if position < system.count {
                session.ingestForTest(.them, Array(system[position..<min(position + chunk, system.count)]))
            }
            if position < mic.count {
                session.ingestForTest(.me, Array(mic[position..<min(position + chunk, mic.count)]))
            }
            position += chunk
            try? await Task.sleep(nanoseconds: pause)
        }
    }

    private static func loadSamples(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let resampler = Resampler16k(from: file.processingFormat)
        else { return nil }
        return resampler.convert(buffer)
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func finish(_ report: [String: Any], code: Int32) -> Never {
        let url = outputURL.appendingPathComponent("sonuc.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        Log.flush()
        exit(code)
    }
}
