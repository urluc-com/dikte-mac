import AppKit
import ApplicationServices

/// Transkripti, o an odaklı olan uygulamaya yapıştırır.
/// Yöntem: pano -> Cmd+V simülasyonu -> eski pano içeriğini geri yükle.
/// Türkçe karakterler (ğ, ş, ı, ö, ü, ç) için karakter karakter type
/// simülasyonundan çok daha güvenilirdir.
enum TextInjector {

    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func inject(_ text: String, completion: (() -> Void)? = nil) {
        guard !text.isEmpty else { completion?(); return }
        guard hasAccessibilityPermission() else {
            Log.write("Accessibility izni yok, metin yapıştırılamadı.")
            completion?()
            return
        }

        let pasteboard = NSPasteboard.general

        // Eski pano içeriğini sakla (tüm tipleriyle)
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Panonun oturması için kısa bekleme, sonra Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            sendCmdV()
            // Yapıştırma tamamlandıktan sonra eski panoyu geri yükle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pasteboard.clearContents()
                if !savedItems.isEmpty {
                    let items: [NSPasteboardItem] = savedItems.map { dict in
                        let item = NSPasteboardItem()
                        for (type, data) in dict {
                            item.setData(data, forType: type)
                        }
                        return item
                    }
                    pasteboard.writeObjects(items)
                }
                completion?()
            }
        }
    }

    private static func sendCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
