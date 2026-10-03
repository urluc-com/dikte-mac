import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var transcription: TranscriptionService
    @State private var launchAtLogin: Bool = AppSettings.shared.launchAtLogin

    var onModelChanged: (() -> Void)?
    var onHotkeyChanged: (() -> Void)?

    var body: some View {
        Form {
            Section("Kısayol") {
                Picker("Bas-konuş tuşu", selection: $settings.hotkeyRaw) {
                    ForEach(HotkeyOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .onChange(of: settings.hotkeyRaw) { _, _ in onHotkeyChanged?() }
                Text("Tuşa basılı tutun, konuşun, bırakın — metin odaklı alana yazılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Whisper modeli", selection: $settings.modelRaw) {
                    ForEach(ModelSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .onChange(of: settings.modelRaw) { _, _ in onModelChanged?() }

                Picker("Dil", selection: $settings.languageRaw) {
                    ForEach(LanguageOption.allCases) { lang in
                        Text(lang.label).tag(lang.rawValue)
                    }
                }
                modelStateRow
            }

            Section("Genel") {
                Toggle("Girişte otomatik başlat", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        AppSettings.shared.launchAtLogin = newValue
                    }
            }

            Section("LLM Temizleme (opsiyonel)") {
                Toggle("Ollama ile transkripti düzelt", isOn: $settings.llmCleanupEnabled)
                TextField("Ollama modeli", text: $settings.ollamaModel)
                    .disabled(!settings.llmCleanupEnabled)
                Text("Yerel Ollama (localhost:11434) çalışmıyorsa ham transkript kullanılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 480)
    }

    @ViewBuilder
    private var modelStateRow: some View {
        switch transcription.state {
        case .idle:
            Label("Model yüklenmedi", systemImage: "circle.dashed")
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
            }
        case .loading:
            Label("Model belleğe yükleniyor…", systemImage: "hourglass")
        case .ready:
            Label("Model hazır — offline çalışıyor", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
