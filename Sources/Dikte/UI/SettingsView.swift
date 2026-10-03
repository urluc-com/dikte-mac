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
                LabeledContent("Model klasörü") {
                    HStack(spacing: 8) {
                        Text(settings.modelBaseURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Seç…", action: chooseModelFolder)
                            .controlSize(.small)
                    }
                }
            }

            Section("Toplantı") {
                Toggle("Toplantı bitince özet çıkar", isOn: $settings.summaryEnabled)
                Toggle("Başlarken Ollama modelini bellekten çıkar", isOn: $settings.freeOllamaOnMeetingStart)
                Text("Toplantı sırasında bellek Whisper'a kalır; özet için model sonda yeniden yüklenir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Genel") {
                Toggle("Girişte otomatik başlat", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        AppSettings.shared.launchAtLogin = newValue
                    }
            }

            Section("Ollama (yerel model)") {
                TextField("Model", text: $settings.ollamaModel)
                Toggle("Dikte metnini modelle düzelt", isOn: $settings.llmCleanupEnabled)
                Text("Toplantı özeti ve dikte düzeltmesi bu modeli kullanır. Ollama (localhost:11434) çalışmıyorsa dikte ham metni yazar, özet çıkmaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 800)
    }

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.modelBaseURL
        panel.prompt = "Seç"
        panel.message = "Whisper modellerinin indirileceği klasör"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.modelFolderPath = url.path
        onModelChanged?()
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
        case .preparing:
            Label("Model bu Mac'e göre hazırlanıyor (ilk seferde birkaç dakika)…", systemImage: "gearshape.2")
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
