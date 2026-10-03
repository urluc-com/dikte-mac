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
    case largeV3 = "openai_whisper-large-v3"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small:   return "Small (hızlı, ~500 MB)"
        case .medium:  return "Medium (önerilen, ~1.5 GB)"
        case .largeV3: return "Large v3 (en doğru, ~3 GB)"
        }
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
    @AppStorage("modelSize")      var modelRaw: String = ModelSize.medium.rawValue
    @AppStorage("language")       var languageRaw: String = LanguageOption.turkish.rawValue
    @AppStorage("llmCleanup")     var llmCleanupEnabled: Bool = false
    @AppStorage("ollamaModel")    var ollamaModel: String = "qwen2.5"
    @AppStorage("onboardingDone") var onboardingDone: Bool = false

    var hotkey: HotkeyOption { HotkeyOption(rawValue: hotkeyRaw) ?? .rightOption }
    var model: ModelSize { ModelSize(rawValue: modelRaw) ?? .medium }
    var language: LanguageOption { LanguageOption(rawValue: languageRaw) ?? .turkish }

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
