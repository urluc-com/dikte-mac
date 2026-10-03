import Foundation
import WhisperKit

/// WhisperKit tabanlı, tamamen yerel (offline) transkripsiyon servisi.
/// Model ilk açılışta Hugging Face'ten indirilir, sonrasında internet gerekmez.
@MainActor
final class TranscriptionService: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var whisper: WhisperKit?
    private var loadedModel: String?

    var isReady: Bool { state == .ready }

    /// Modeli indir (gerekliyse) ve belleğe yükle.
    /// WhisperKit.download önbelleği kullanır: model zaten indiyse
    /// mevcut dosyaları atlar, yani internetsiz de çalışır (offline-check).
    func load(model: String) async {
        guard loadedModel != model || whisper == nil else { return }
        whisper = nil
        loadedModel = nil
        state = .downloading(0)
        Log.write("Model yükleniyor: \(model)")
        do {
            let folder = try await WhisperKit.download(
                variant: model,
                useBackgroundSession: false
            ) { progress in
                Task { @MainActor in
                    self.state = .downloading(progress.fractionCompleted)
                }
            }
            state = .loading
            let config = WhisperKitConfig(modelFolder: folder.path)
            let pipe = try await WhisperKit(config)
            whisper = pipe
            loadedModel = model
            state = .ready
            Log.write("Model hazır: \(model)")
        } catch {
            let message = Self.friendlyError(error)
            state = .failed(message)
            Log.write("Model yükleme hatası: \(error)")
        }
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let whisper else {
            throw NSError(domain: "Dikte", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Model henüz hazır değil."])
        }
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language // nil => otomatik algıla
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Model indirilemedi — internet bağlantısı gerekiyor (yalnızca ilk kurulumda)."
        }
        return "Model yüklenemedi: \(error.localizedDescription)"
    }
}
