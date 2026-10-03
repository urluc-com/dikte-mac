import AppKit
import SwiftUI

/// Kayıt sırasında ekranın altında görünen küçük, kenarlıksız floating panel.
final class RecordingPanelController {
    private var panel: NSPanel?
    private let levelModel = LevelModel()

    final class LevelModel: ObservableObject {
        @Published var level: Float = 0
    }

    func updateLevel(_ level: Float) {
        levelModel.level = level
    }

    func show() {
        if panel == nil {
            let content = NSHostingView(rootView: RecordingIndicatorView(model: levelModel))
            let size = NSSize(width: 160, height: 44)
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = content
            panel = p
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        levelModel.level = 0
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct RecordingIndicatorView: View {
    @ObservedObject var model: RecordingPanelController.LevelModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16, weight: .semibold))
            // Ses seviyesine tepki veren basit bar animasyonu
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 4, height: barHeight(index))
                        .animation(.easeOut(duration: 0.12), value: model.level)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let base: CGFloat = 6
        let weights: [CGFloat] = [0.4, 0.7, 1.0, 1.2, 1.0, 0.7, 0.4]
        return base + CGFloat(model.level) * 22 * weights[index]
    }
}
