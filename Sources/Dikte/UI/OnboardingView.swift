import SwiftUI
import AVFoundation
import Combine

/// İlk açılışta izinleri adım adım toplayan onboarding ekranı.
struct OnboardingView: View {
    @State private var micGranted = AudioEngine.microphoneAuthorized
    @State private var accessibilityGranted = TextInjector.hasAccessibilityPermission()
    @State private var inputMonitoringGranted = HotkeyManager.inputMonitoringAuthorized
    @State private var systemAudioRequested = false

    var onFinished: () -> Void

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dikte'ye hoş geldin 👋")
                    .font(.title.bold())
                Text("Toplantı notları için mikrofon ve sistem sesi yeter. Sesle yazı yazmak (bas-konuş) için erişilebilirlik ve giriş izleme de gerekir; onları sonra da verebilirsin.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                title: "1. Mikrofon",
                detail: "Sesini yakalamak için.",
                granted: micGranted,
                buttonTitle: "İzin ver"
            ) {
                Task {
                    micGranted = await AudioEngine.requestMicrophonePermission()
                }
            }

            permissionRow(
                title: "2. Erişilebilirlik",
                detail: "Metni odaklı uygulamaya yapıştırmak için (Cmd+V simülasyonu).",
                granted: accessibilityGranted,
                buttonTitle: "Ayarları aç"
            ) {
                _ = TextInjector.hasAccessibilityPermission(prompt: true)
                TextInjector.openAccessibilitySettings()
            }

            permissionRow(
                title: "3. Giriş İzleme",
                detail: "Kısayol tuşunu her uygulamada dinlemek için.",
                granted: inputMonitoringGranted,
                buttonTitle: "İzin iste"
            ) {
                HotkeyManager.requestInputMonitoring()
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("4. Sistem sesi (toplantı için)").font(.headline)
                    Text("Toplantıda karşı tarafın sesini yazıya dökmek için. Şimdi vermezsen ilk toplantıda sorulur.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if systemAudioRequested {
                    // macOS bu iznin durumunu uygulamaya söylemiyor; soru bir kez çıkar,
                    // sonrası Sistem Ayarları'ndan görülür
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("İstendi", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Button("Ayarlarda gör") { SystemAudioPermission.openSettings() }
                            .controlSize(.small)
                    }
                } else {
                    Button("İzin iste") {
                        systemAudioRequested = true
                        SystemAudioPermission.request()
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            Spacer()

            HStack {
                Spacer()
                Button("Başla") { onFinished() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!micGranted)
            }
            Text("İpucu: İzinleri verdikten sonra macOS uygulamayı yeniden başlatmanı isteyebilir.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 480, height: 570)
        .onReceive(timer) { _ in
            // İzin durumlarını periyodik yenile (kullanıcı Sistem Ayarları'ndan dönünce)
            micGranted = AudioEngine.microphoneAuthorized
            accessibilityGranted = TextInjector.hasAccessibilityPermission()
            inputMonitoringGranted = HotkeyManager.inputMonitoringAuthorized
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Verildi", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
