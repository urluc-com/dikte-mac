import Foundation
import SwiftUI
import ServiceManagement

enum HotkeyOption: String, CaseIterable, Identifiable {
    case rightOption
    case fn
    case rightCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption:  return "Sağ Option (⌥)"
        case .fn:           return "Fn (🌐)"
        case .rightCommand: return "Sağ Command (⌘)"
        }
    }
}

enum ModelSize: String, CaseIterable, Identifiable {
    case small   = "openai_whisper-small"
    case medium  = "openai_whisper-medium"
    /// OpenAI'ın 30 Eylül 2024 tarihli large-v3-turbo modeli (WhisperKit'in hızlandırılmış derlemesi)
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"
    case largeV3 = "openai_whisper-large-v3"

    var id: String { rawValue }

    /// Apple Silicon'da Neural Engine büyük modeli canlı konuşmaya yetiştirir. Intel'de model
    /// işlemcide koşar; turbo'nun kodlayıcısı large ile aynı ağırlıkta olduğu için canlı
    /// döküme ancak küçük model yetişir.
    static var recommended: ModelSize {
        #if arch(x86_64)
        return .small
        #else
        return .largeV3Turbo
        #endif
    }

    var label: String {
        let name: String
        switch self {
        case .small:        name = "Small (hızlı, ~500 MB)"
        case .medium:       name = "Medium (~1,5 GB)"
        case .largeV3Turbo: name = "Large v3 Turbo (~1,6 GB)"
        case .largeV3:      name = "Large v3 (en doğru, ~3 GB)"
        }
        return self == Self.recommended ? name + " — önerilen" : name
    }
}

enum LanguageOption: String, CaseIterable, Identifiable {
    case turkish = "tr"
    case auto    = "auto"
    case english = "en"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .turkish: return "Türkçe"
        case .auto:    return "Otomatik algıla"
        case .english: return "İngilizce"
        }
    }

    /// WhisperKit'e verilecek dil kodu; auto ise nil
    var whisperCode: String? { self == .auto ? nil : rawValue }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("hotkey")         var hotkeyRaw: String = HotkeyOption.rightOption.rawValue
    @AppStorage("modelSize")      var modelRaw: String = ModelSize.recommended.rawValue
    @AppStorage("language")       var languageRaw: String = LanguageOption.turkish.rawValue
    @AppStorage("llmCleanup")     var llmCleanupEnabled: Bool = false
    @AppStorage("ollamaModel")    var ollamaModel: String = "qwen3.8:27b-mlx"
    @AppStorage("onboardingDone") var onboardingDone: Bool = false
    /// Whisper modellerinin duracağı klasör; boşsa Application Support/Dikte/Modeller
    @AppStorage("modelFolder")    var modelFolderPath: String = ""
    @AppStorage("meetingSummary") var summaryEnabled: Bool = true
    /// Toplantı başlarken Ollama'daki büyük modeli bellekten çıkar (özet için sonda yeniden yüklenir)
    @AppStorage("freeOllamaOnMeetingStart") var freeOllamaOnMeetingStart: Bool = true

    var hotkey: HotkeyOption { HotkeyOption(rawValue: hotkeyRaw) ?? .rightOption }
    var model: ModelSize { ModelSize(rawValue: modelRaw) ?? .recommended }
    var language: LanguageOption { LanguageOption(rawValue: languageRaw) ?? .turkish }

    /// Uygulamanın kendi verileri (toplantılar, varsayılan model klasörü)
    static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dikte", isDirectory: true)
    }

    var modelBaseURL: URL {
        guard !modelFolderPath.isEmpty else {
            return Self.supportURL.appendingPathComponent("Modeller", isDirectory: true)
        }
        return URL(fileURLWithPath: (modelFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("Login item hatası: \(error.localizedDescription)")
            }
        }
    }
}
