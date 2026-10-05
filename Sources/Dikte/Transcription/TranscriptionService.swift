import Foundation
import WhisperKit

/// WhisperKit tabanlı, tamamen yerel (offline) transkripsiyon servisi.
/// Model ilk açılışta Hugging Face'ten indirilir, sonrasında internet gerekmez.
@MainActor
final class TranscriptionService: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case preparing             // Core ML modeli bu Mac'e göre derliyor (ilk seferde dakikalar sürebilir)
        case loading
        case ready
        case failed(String)
    }

    struct Output {
        let text: String
        let language: String
        let avgLogprob: Float
        let noSpeechProb: Float
        /// 0'dan büyükse çözüm yedek tura (örneklemeye) düşmüş demektir
        let temperature: Float
    }

    @Published private(set) var state: State = .idle
    /// Test: modeli yalnız işlemcide çalıştır (Neural Engine'siz bir Mac'in hızını kestirmek için)
    var cpuOnly = false
    private var whisper: WhisperKit?
    private var loadedModel: String?
    /// "[", "(", "♪" gibi konuşma dışı etiketleri başlatan belirteçler
    private var nonSpeechTokens: [Int] = []

    var isReady: Bool { state == .ready }

    /// Modeli indir (gerekliyse) ve belleğe yükle.
    /// Model bir kez tam indiyse ağa hiç çıkılmaz (klasördeki işaret dosyasına bakılır).
    /// - Parameter force: Aynı model yüklü olsa da yeniden yükle (model klasörü değiştiğinde).
    func load(model: String, force: Bool = false) async {
        guard force || loadedModel != model || whisper == nil else { return }
        whisper = nil
        loadedModel = nil

        let base = AppSettings.shared.modelBaseURL
        guard Self.volumeAvailable(for: base) else {
            state = .failed("Model klasörüne ulaşılamıyor (\(base.path)). Disk takılı mı?")
            Log.write("Model klasörü yok: \(base.path)")
            return
        }

        Log.write("Model yükleniyor: \(model) (klasör: \(base.path))")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let folder = try await modelFolder(for: model, base: base)

            state = .preparing
            let started = Date()
            let config = WhisperKitConfig(
                downloadBase: base,
                modelFolder: folder.path,
                tokenizerFolder: base,
                computeOptions: cpuOnly
                    ? ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
                    : nil,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: false,
                download: false
            )
            let pipe = try await WhisperKit(config)
            // Önce tek tek derle-boşalt (bellek tepesini düşürür), sonra yükle
            try await pipe.prewarmModels()
            let prepared = Date()
            state = .loading
            try await pipe.loadModels()

            whisper = pipe
            loadedModel = model
            nonSpeechTokens = Self.nonSpeechTokens(of: pipe.tokenizer)
            state = .ready
            Log.write(String(format: "Model hazır: %@ (hazırlık %.1f sn, yükleme %.1f sn)",
                             model, prepared.timeIntervalSince(started), Date().timeIntervalSince(prepared)))
        } catch {
            let message = Self.friendlyError(error)
            state = .failed(message)
            Log.write("Model yükleme hatası: \(error)")
        }
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        try await transcribeDetailed(samples, language: language).text
    }

    /// `language` nil ise dil sesten algılanır.
    ///
    /// Küçük modeller net konuşmayı bile bazen "[Müzik]" diye etiketliyor (WhisperKit, özgün
    /// Whisper'ın aksine bu belirteçleri kendiliğinden yasaklamıyor). Sonuç yalnız böyle bir
    /// etiketse parça bir kez de o belirteçler yasakken çözülür; model bu kez de emin değilse
    /// (düşük güven) ilk sonuç kalır ve çağıran onu "söz yok" diye eler.
    func transcribeDetailed(_ samples: [Float], language: String?) async throws -> Output {
        let first = try await decode(samples, language: language, suppressing: [])
        guard !first.text.isEmpty, HallucinationFilter.isNonSpeechTag(first.text), !nonSpeechTokens.isEmpty else {
            return first
        }
        let retry = try await decode(samples, language: language, suppressing: nonSpeechTokens)
        let accepted = retry.avgLogprob > -1 && !retry.text.isEmpty && !HallucinationFilter.isHallucination(retry.text)
        Log.write(String(format: "Etiket çıktı (%@); etiketsiz yeniden çözüldü, güven %.2f → %@",
                         first.text, retry.avgLogprob, accepted ? "kabul" : "ret"))
        return accepted ? retry : first
    }

    private func decode(_ samples: [Float], language: String?, suppressing suppressed: [Int]) async throws -> Output {
        guard let whisper else {
            throw NSError(domain: "Dikte", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Model henüz hazır değil."])
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressTokens: suppressed,
            // WhisperKit ilk kelimeden emin olamazsa parçayı baştan, rastgele örneklemeyle
            // çözüyor; cümle ortasından başlayan parçalarda bu sık tetikleniyor ve yazımı
            // bozuyor (duraksamasız konuşma testinde karakter hatası %3,5 → %1,0).
            // Tekrar ve düşük güven denetimleri duruyor.
            firstTokenLogProbThreshold: nil
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let segments = results.flatMap(\.segments)
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let avgLogprob = segments.isEmpty ? 0 : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
        return Output(
            text: text,
            language: results.first?.language ?? language ?? "",
            avgLogprob: avgLogprob,
            noSpeechProb: segments.map(\.noSpeechProb).max() ?? 0,
            temperature: segments.map(\.temperature).max() ?? 0
        )
    }

    private static func nonSpeechTokens(of tokenizer: WhisperTokenizer?) -> [Int] {
        guard let tokenizer else { return [] }
        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        var ids = Set<Int>()
        for symbol in ["[", "(", "♪", "*", "【", "（"] {
            for text in [symbol, " " + symbol] {
                let tokens = tokenizer.encode(text: text).filter { $0 < specialBegin }
                if tokens.count == 1 { ids.insert(tokens[0]) }
            }
        }
        return ids.sorted()
    }

    // MARK: - Model klasörü

    private static let completeMarker = ".dikte-indirildi"

    private func modelFolder(for model: String, base: URL) async throws -> URL {
        let local = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
        let marker = local.appendingPathComponent(Self.completeMarker)
        if FileManager.default.fileExists(atPath: marker.path) {
            return local
        }

        state = .downloading(0)
        let folder = try await WhisperKit.download(
            variant: model,
            downloadBase: base,
            useBackgroundSession: false
        ) { progress in
            Task { @MainActor in
                if case .downloading = self.state {
                    self.state = .downloading(progress.fractionCompleted)
                }
            }
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.completeMarker).path, contents: nil)
        Log.write("Model indirildi: \(folder.path)")
        return folder
    }

    /// Klasör harici bir diskteyse disk takılı mı?
    private static func volumeAvailable(for url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])")
    }

    private static func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Model indirilemedi — internet bağlantısı gerekiyor (yalnızca ilk kurulumda)."
        }
        return "Model yüklenemedi: \(error.localizedDescription)"
    }
}
