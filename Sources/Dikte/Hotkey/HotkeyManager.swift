import AppKit
import IOKit.hid

/// Push-to-talk: seçilen tuşa basılı tutunca kayıt, bırakınca durdurma.
/// flagsChanged event'leri global + local monitor ile dinlenir.
/// NOT: Global monitor için Sistem Ayarları > Gizlilik ve Güvenlik >
/// Giriş İzleme (Input Monitoring) izni gerekir.
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false

    /// Ayarlardan değiştirilebilir
    var option: HotkeyOption = .rightOption

    private enum KeyCode {
        static let rightOption: UInt16 = 61
        static let rightCommand: UInt16 = 54
    }

    static var inputMonitoringAuthorized: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
        Log.write("Hotkey dinleniyor: \(option.rawValue)")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let nowPressed: Bool
        switch option {
        case .rightOption:
            guard event.keyCode == KeyCode.rightOption else { return }
            nowPressed = event.modifierFlags.contains(.option)
        case .rightCommand:
            guard event.keyCode == KeyCode.rightCommand else { return }
            nowPressed = event.modifierFlags.contains(.command)
        case .fn:
            nowPressed = event.modifierFlags.contains(.function)
        }

        guard nowPressed != isPressed else { return }
        isPressed = nowPressed
        if nowPressed {
            onPress?()
        } else {
            onRelease?()
        }
    }
}
