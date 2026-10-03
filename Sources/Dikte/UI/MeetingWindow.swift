import AppKit
import SwiftUI

/// Toplantı penceresi. Dikte menü çubuğu uygulaması olduğu için pencere açıkken Dock'ta
/// görünür olur (⌘Tab ile bulunabilsin), kapanınca yine gizlenir.
@MainActor
final class MeetingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: MeetingStore
    private let session: MeetingSession
    private let transcription: TranscriptionService
    let selection = MeetingSelection()

    init(store: MeetingStore, session: MeetingSession, transcription: TranscriptionService) {
        self.store = store
        self.session = session
        self.transcription = transcription
    }

    func show(selecting id: UUID? = nil) {
        select(id)
        makeWindowIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Pencere açılınca başlık alanı kendiliğinden seçili gelmesin
        window?.makeFirstResponder(nil)
    }

    /// Test: pencereyi öne almadan, öteki pencerelerin arkasında açar (çalışan kişiyi bölmez);
    /// görüntüsü `snapshot` ile alınır.
    func showForTest(selecting id: UUID? = nil) {
        select(id)
        makeWindowIfNeeded()
        window?.orderBack(nil)
        window?.makeFirstResponder(nil)
    }

    private func select(_ id: UUID?) {
        if let id {
            selection.id = id
        } else if selection.id == nil {
            selection.id = session.activeID ?? store.meetings.first?.id
        }
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let root = MeetingRootView(store: store, session: session,
                                   transcription: transcription, selection: selection)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Dikte — Toplantılar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 620))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("DikteToplantiPenceresi")
        window.initialFirstResponder = nil
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Pencerenin o anki görüntüsünü PNG olarak yazar (test için; ekran kaydı izni gerektirmez).
    func snapshot(to url: URL) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
