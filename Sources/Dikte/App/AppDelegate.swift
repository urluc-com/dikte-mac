import AppKit
import AVFoundation
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
    private let meetingStore = MeetingStore(baseURL: TestHarness.storeURL ?? MeetingStore.defaultBaseURL)
    private lazy var meetingSession = MeetingSession(
        transcription: transcription, store: meetingStore, mic: audioEngine
    )
    private lazy var meetingWindow = MeetingWindowController(
        store: meetingStore, session: meetingSession, transcription: transcription
    )

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var lastTranscript: String = ""
    private var isBusy = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Yaşam döngüsü

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        Log.write("Dikte başlatıldı")

        audioEngine.levelHandler = { [weak self] level in
            Task { @MainActor in
                self?.recordingPanel.updateLevel(level)
            }
        }

        // Model ve toplantı durumu değiştikçe menü çubuğunu güncelle
        transcription.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusIcon() }
            }
            .store(in: &cancellables)
        meetingSession.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshStatusIcon() }
            }
            .store(in: &cancellables)

        if let harness = TestHarness.fromEnvironment() {
            harness.run(transcription: transcription, session: meetingSession,
                        store: meetingStore, window: meetingWindow, model: settings.model.rawValue)
            return
        }

        hotkey.option = settings.hotkey
        hotkey.onPress = { [weak self] in
            Task { @MainActor in self?.beginRecording() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in self?.endRecordingAndTranscribe() }
        }
        hotkey.start()

        // 16 Eki 2026: URLuc Dash'in mikrofon düğmesi — dağıtık bildirimle kayıt başlat/bitir (metin, kısayoldaki gibi
        // odaktaki kutuya yapıştırılır). Bildirim: com.urluc.dikte.kayit, userInfo["eylem"] = "basla" | "bitir" | "degistir".
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.urluc.dikte.kayit"), object: nil,
                                                            queue: .main) { [weak self] n in
            guard let self else { return }
            let eylem = (n.userInfo?["eylem"] as? String) ?? "degistir"
            Task { @MainActor in
                switch eylem {
                case "basla": self.beginRecording()
                case "bitir": self.endRecordingAndTranscribe()
                default: self.audioEngine.isRecording ? self.endRecordingAndTranscribe() : self.beginRecording()
                }
            }
        }

        if settings.onboardingDone {
            Task { await transcription.load(model: settings.model.rawValue) }
        } else {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        meetingSession.stopForTermination()
    }

    // MARK: - Menü çubuğu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusIcon()
        statusItem.menu = buildMenu()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        if meetingSession.phase != .idle {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Toplantı kaydı")
            button.contentTintColor = .systemRed
            button.title = ""
        } else if audioEngine.isRecording {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Kayıtta")
            button.contentTintColor = .systemRed
            button.title = ""
        } else {
            switch transcription.state {
            case .downloading(let progress):
                button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "İndiriliyor")
                button.contentTintColor = nil
                button.title = " %\(Int(progress * 100))"
            case .preparing, .loading:
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
        if meetingSession.phase == .recording {
            statusText = "🔴 Toplantı kaydı sürüyor"
        } else if meetingSession.phase == .finishing {
            statusText = "Toplantının son parçaları yazıya dökülüyor…"
        } else if audioEngine.isRecording {
            statusText = "🔴 Kayıtta…"
        } else {
            switch transcription.state {
            case .idle:               statusText = "Model yüklenmedi"
            case .downloading(let p): statusText = "Model indiriliyor… %\(Int(p * 100))"
            case .preparing:          statusText = "Model bu Mac'e göre hazırlanıyor…"
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

        switch meetingSession.phase {
        case .idle:
            let startItem = NSMenuItem(title: "Toplantıyı başlat", action: #selector(startMeeting), keyEquivalent: "")
            startItem.target = self
            startItem.isEnabled = transcription.isReady
            menu.addItem(startItem)
        case .recording:
            let finishItem = NSMenuItem(title: "Toplantıyı bitir ve özetle", action: #selector(finishMeeting), keyEquivalent: "")
            finishItem.target = self
            menu.addItem(finishItem)
        case .finishing:
            break
        }
        let meetingsItem = NSMenuItem(title: "Toplantılar…", action: #selector(openMeetings), keyEquivalent: "")
        meetingsItem.target = self
        menu.addItem(meetingsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(title: "İzin kurulumunu yeniden yap…", action: #selector(redoOnboarding), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    /// Toplantı penceresi açıkken uygulama Dock'ta görünür; ⌘C/⌘V/⌘W'nin çalışması için
    /// standart Düzen ve Pencere menüleri gerekir.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Dikte'yi Gizle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Dikte'den Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Düzen")
        editMenu.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Pencere")
        windowMenu.addItem(withTitle: "Kapat", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Küçült", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func copyLastTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // MARK: - Toplantı

    @objc private func startMeeting() {
        Task { @MainActor in
            let id = await meetingSession.start()
            meetingWindow.show(selecting: id)
        }
    }

    @objc private func finishMeeting() {
        let id = meetingSession.activeID
        meetingSession.finish()
        meetingWindow.show(selecting: id)
    }

    @objc private func openMeetings() {
        meetingWindow.show()
    }

    // MARK: - Kayıt akışı

    private func beginRecording() {
        guard !audioEngine.isRecording, !isBusy else { return }
        // Toplantı sürerken mikrofon ve model toplantıya ayrılmış durumda
        guard !meetingSession.isBusy else { return }
        guard transcription.isReady else {
            notify("Model henüz hazır değil", body: "Model indirmesi/yüklemesi bitince tekrar dene.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // İzin hiç sorulmamış (ya da tccutil ile sıfırlanmış): burada iste, sonraki basışta çalışır
            Task { _ = await AudioEngine.requestMicrophonePermission() }
            return
        default:
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
        // Sessiz kayıtta Whisper altyazı künyesi uyduruyor; hiç göndermeyelim
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.002 else {
            Log.write("Sessiz kayıt, yazıya dökülmedi")
            return
        }

        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                var text = try await transcription.transcribe(
                    samples,
                    language: settings.language.whisperCode
                )
                guard !text.isEmpty, !HallucinationFilter.isHallucination(text) else { return }
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
                    Task { await self.transcription.load(model: self.settings.model.rawValue, force: true) }
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

    @objc private func redoOnboarding() {
        settings.onboardingDone = false
        showOnboarding()
    }

    private func showOnboarding() {
        guard onboardingWindow == nil else {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow?.makeKeyAndOrderFront(nil)
            return
        }
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
