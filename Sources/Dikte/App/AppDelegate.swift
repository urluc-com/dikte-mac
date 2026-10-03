import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = AppSettings.shared
    private let audioEngine = AudioEngine()
    private let hotkey = HotkeyManager()
    private let transcription = TranscriptionService()
    private let recordingPanel = RecordingPanelController()

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var lastTranscript: String = ""
    private var isBusy = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Yaşam döngüsü

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        Log.write("Dikte başlatıldı")

        audioEngine.levelHandler = { [weak self] level in
            Task { @MainActor in
                self?.recordingPanel.updateLevel(level)
            }
        }

        hotkey.option = settings.hotkey
        hotkey.onPress = { [weak self] in
            Task { @MainActor in self?.beginRecording() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in self?.endRecordingAndTranscribe() }
        }
        hotkey.start()

        // Model durumu değiştikçe menü çubuğunu güncelle
        transcription.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusIcon() }
            }
            .store(in: &cancellables)

        if settings.onboardingDone {
            Task { await transcription.load(model: settings.model.rawValue) }
        } else {
            showOnboarding()
        }
    }

    // MARK: - Menü çubuğu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusIcon()
        statusItem.menu = buildMenu()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        if audioEngine.isRecording {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Kayıtta")
            button.contentTintColor = .systemRed
            button.title = ""
        } else {
            switch transcription.state {
            case .downloading(let progress):
                button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "İndiriliyor")
                button.contentTintColor = nil
                button.title = " %\(Int(progress * 100))"
            case .loading:
                button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Yükleniyor")
                button.contentTintColor = nil
                button.title = ""
            case .failed:
                button.image = NSImage(systemSymbolName: "mic.badge.xmark", accessibilityDescription: "Hata")
                button.contentTintColor = .systemOrange
                button.title = ""
            default:
                button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dikte")
                button.contentTintColor = nil
                button.title = ""
            }
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusText: String
        if audioEngine.isRecording {
            statusText = "🔴 Kayıtta…"
        } else {
            switch transcription.state {
            case .idle:               statusText = "Model yüklenmedi"
            case .downloading(let p): statusText = "Model indiriliyor… %\(Int(p * 100))"
            case .loading:            statusText = "Model yükleniyor…"
            case .ready:              statusText = "Hazır — \(settings.hotkey.label) ile konuş"
            case .failed(let msg):    statusText = "⚠️ \(msg)"
            }
        }
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if !lastTranscript.isEmpty {
            menu.addItem(.separator())
            let preview = lastTranscript.count > 60
                ? String(lastTranscript.prefix(60)) + "…"
                : lastTranscript
            let previewItem = NSMenuItem(title: "Son: \(preview)", action: #selector(copyLastTranscript), keyEquivalent: "")
            previewItem.target = self
            menu.addItem(previewItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    @objc private func copyLastTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // MARK: - Kayıt akışı

    private func beginRecording() {
        guard !audioEngine.isRecording, !isBusy else { return }
        guard transcription.isReady else {
            notify("Model henüz hazır değil", body: "Model indirmesi/yüklemesi bitince tekrar dene.")
            return
        }
        guard AudioEngine.microphoneAuthorized else {
            notify("Mikrofon izni yok", body: "Sistem Ayarları > Gizlilik ve Güvenlik > Mikrofon.")
            return
        }
        do {
            try audioEngine.startRecording()
            recordingPanel.show()
            refreshStatusIcon()
        } catch {
            Log.write("Kayıt başlatılamadı: \(error.localizedDescription)")
            notify("Kayıt başlatılamadı", body: error.localizedDescription)
        }
    }

    private func endRecordingAndTranscribe() {
        guard audioEngine.isRecording else { return }
        let samples = audioEngine.stopRecording()
        recordingPanel.hide()
        refreshStatusIcon()

        // 0.4 saniyeden kısa kayıtları yok say (yanlışlıkla basma)
        guard samples.count > 6_400 else { return }

        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                var text = try await transcription.transcribe(
                    samples,
                    language: settings.language.whisperCode
                )
                guard !text.isEmpty else { return }
                if settings.llmCleanupEnabled {
                    text = await OllamaCleanup.cleanup(text, model: settings.ollamaModel)
                }
                lastTranscript = text
                TextInjector.inject(text)
                refreshStatusIcon()
            } catch {
                Log.write("Transkripsiyon hatası: \(error.localizedDescription)")
                notify("Transkripsiyon hatası", body: error.localizedDescription)
            }
        }
    }

    // MARK: - Pencereler

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                transcription: transcription,
                onModelChanged: { [weak self] in
                    guard let self else { return }
                    Task { await self.transcription.load(model: self.settings.model.rawValue) }
                },
                onHotkeyChanged: { [weak self] in
                    guard let self else { return }
                    self.hotkey.option = self.settings.hotkey
                    self.hotkey.start()
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Dikte Ayarları"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        let view = OnboardingView { [weak self] in
            guard let self else { return }
            self.settings.onboardingDone = true
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            Task { await self.transcription.load(model: self.settings.model.rawValue) }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Dikte Kurulumu"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Bildirim

    private func notify(_ title: String, body: String) {
        // Basit, izin gerektirmeyen uyarı: menü çubuğu ikonunu turuncu yap + log
        Log.write("UYARI: \(title) — \(body)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
