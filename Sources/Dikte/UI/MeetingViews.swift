import AppKit
import SwiftUI

/// Toplantı penceresinde seçili toplantı (pencere denetleyicisi de dışarıdan değiştirir).
final class MeetingSelection: ObservableObject {
    @Published var id: UUID?
}

struct MeetingRootView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var session: MeetingSession
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var selection: MeetingSelection

    var body: some View {
        HStack(spacing: 0) {
            MeetingSidebar(store: store, session: session, transcription: transcription, selection: selection)
                .frame(width: 240)
            Divider()
            Group {
                if let id = selection.id, let meeting = store.meeting(id) {
                    MeetingDetailView(meeting: meeting, store: store, session: session, selection: selection)
                        .id(meeting.id)
                } else {
                    MeetingEmptyView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Kenar çubuğu

private struct MeetingSidebar: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var session: MeetingSession
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var selection: MeetingSelection

    var body: some View {
        VStack(spacing: 0) {
            primaryButton
                .padding(14)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            selected: selection.id == meeting.id,
                            live: session.activeID == meeting.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selection.id = meeting.id }
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()
            modelStatus
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch session.phase {
        case .idle:
            Button {
                Task {
                    if let id = await session.start() { selection.id = id }
                }
            } label: {
                Label("Toplantıyı başlat", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(!transcription.isReady)
            .opacity(transcription.isReady ? 1 : 0.45)
        case .recording:
            Button {
                session.finish()
            } label: {
                Label("Bitir ve özetle", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Son parçalar yazıya dökülüyor…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        HStack(spacing: 6) {
            switch transcription.state {
            case .ready:
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Model hazır")
            case .downloading(let progress):
                ProgressView().controlSize(.mini)
                Text("Model indiriliyor %\(Int(progress * 100))")
            case .preparing:
                ProgressView().controlSize(.mini)
                Text("Model bu Mac'e göre hazırlanıyor…")
            case .loading:
                ProgressView().controlSize(.mini)
                Text("Model yükleniyor…")
            case .idle:
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                Text("Model yüklenmedi")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let selected: Bool
    let live: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if live {
                Circle().fill(Color.red).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8).fill(Brand.softGradient)
            }
        }
    }

    private var subtitle: String {
        let date = Meeting.shortDateLabel(meeting.startedAt)
        return live ? "\(date) · kayıtta" : "\(date) · \(Meeting.durationLabel(meeting.duration))"
    }
}

// MARK: - Boş durum

private struct MeetingEmptyView: View {
    @ObservedObject var session: MeetingSession

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text("Toplantı notları")
                .font(.title3.weight(.semibold))
            Text("“Toplantıyı başlat”a bastığında Dikte mikrofonunu ve Mac'te çalan sesi dinler; kim ne dediyse ayrı ayrı yazıya döker, bitince özetini çıkarır. Tarayıcı, Teams, Slack, Zoom fark etmez.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let notice = session.notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 6)
            }
        }
        .padding(40)
    }
}

// MARK: - Ayrıntı

private struct MeetingDetailView: View {
    let meeting: Meeting
    @ObservedObject var store: MeetingStore
    @ObservedObject var session: MeetingSession
    @ObservedObject var selection: MeetingSelection

    enum Tab: String, CaseIterable, Identifiable {
        case transcript = "Döküm"
        case summary = "Özet"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .transcript
    @State private var titleDraft = ""
    @State private var confirmingDelete = false
    @State private var copied = false

    private var isLive: Bool { session.activeID == meeting.id }
    private var isSummarizing: Bool { session.summarizingID == meeting.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)

            if isLive {
                LiveStrip(session: session, startedAt: meeting.startedAt)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
            if let notice = session.notice, isLive || isSummarizing || selection.id == meeting.id {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            }

            Divider()

            Group {
                switch tab {
                case .transcript:
                    TranscriptView(blocks: meeting.blocks, follow: isLive,
                                   speaking: isLive ? session.speaking : [])
                case .summary:
                    SummaryView(text: meeting.summary, working: isSummarizing) {
                        session.summarize(meeting.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .onAppear {
            titleDraft = meeting.title
            if !meeting.summary.isEmpty || isSummarizing { tab = .summary }
        }
        .onChange(of: meeting.title) { _, newValue in
            if newValue != titleDraft { titleDraft = newValue }
        }
        .onChange(of: isSummarizing) { _, working in
            if working { tab = .summary }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Başlık", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .onSubmit(commitTitle)
            HStack(spacing: 10) {
                Text(Meeting.dateLabel(meeting.startedAt))
                if !isLive {
                    Text("·")
                    Text(Meeting.durationLabel(meeting.duration))
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(copied ? "Kopyalandı" : (tab == .summary ? "Özeti kopyala" : "Dökümü kopyala"), action: copy)
                .disabled(tab == .summary ? meeting.summary.isEmpty : meeting.lines.isEmpty)
            Button("Finder'da göster") { store.revealInFinder(meeting) }
            Spacer()
            if !isLive {
                Button(meeting.summary.isEmpty ? "Özet çıkar" : "Yeniden özetle") {
                    session.summarize(meeting.id)
                }
                .disabled(session.summarizingID != nil || meeting.lines.isEmpty)
                Button("Sil", role: .destructive) { confirmingDelete = true }
                    .disabled(isSummarizing)
            }
        }
        .controlSize(.regular)
        .confirmationDialog("Bu toplantı Çöp Sepeti'ne taşınsın mı?", isPresented: $confirmingDelete) {
            Button("Çöp Sepeti'ne taşı", role: .destructive) {
                let id = meeting.id
                selection.id = nil
                store.trash(id)
            }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    private func commitTitle() {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != meeting.title else {
            titleDraft = meeting.title
            return
        }
        store.update(meeting.id) {
            $0.title = title
            $0.titleEdited = true
        }
    }

    private func copy() {
        let text = tab == .summary ? meeting.summaryMarkdown : meeting.transcriptMarkdown
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Canlı şerit

private struct LiveStrip: View {
    @ObservedObject var session: MeetingSession
    let startedAt: Date

    /// Seviyeler saniyede onlarca kez değişir; yalnız bu küçük görünüm yeniden çizilsin
    private struct Meters: View {
        @ObservedObject var levels: MeetingLevels
        let micActive: Bool

        var body: some View {
            LevelMeter(label: Speaker.me.label, level: levels.mic, color: Brand.blue, dimmed: !micActive)
            LevelMeter(label: Speaker.them.label, level: levels.system, color: Brand.purple, dimmed: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Meeting.clock(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                    }
                }
                Meters(levels: session.levels, micActive: session.micActive)
                Spacer()
                if session.pendingSegments > 0 {
                    Text("\(session.pendingSegments) parça sırada")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if session.systemAudioPending {
                Text("Sistem sesi için izin bekleniyor. İzin sorusunu yanıtlayınca karşı tarafın sesi de yazıya dökülür; mikrofon şimdiden dinleniyor.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: startedAt, by: 5)) { context in
                if !session.systemAudioPending, !session.systemAudioHeard,
                   context.date.timeIntervalSince(startedAt) > 20 {
                    HStack(spacing: 8) {
                        Text("Mac'ten henüz ses gelmedi. Bir şey çalıyorsa Dikte'nin sistem sesi izni kapalı olabilir.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("İzinleri aç") { SystemAudioPermission.openSettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float
    let color: Color
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dimmed ? Color.secondary : color)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color)
                        .frame(width: max(0, geometry.size.width * CGFloat(min(1, level))))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(width: 70, height: 5)
            .opacity(dimmed ? 0.4 : 1)
        }
    }
}

enum SystemAudioPermission {
    /// macOS'in sistem sesi izni için ayrı bir "iste" çağrısı yok; soru, yakalama ilk kez
    /// başladığında çıkar. Bu yüzden yakalamayı kısa süre açıp kapatır.
    static func request() {
        DispatchQueue.global(qos: .userInitiated).async {
            let capture = SystemAudioCapture()
            do {
                try capture.start()
            } catch {
                Log.write("Sistem sesi izni istenemedi: \(error.localizedDescription)")
                return
            }
            Thread.sleep(forTimeInterval: 2)
            capture.stop()
        }
    }

    /// Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Döküm

private struct TranscriptView: View {
    let blocks: [TranscriptBlock]
    /// Canlıyken yeni satır geldikçe sona kay
    let follow: Bool
    /// Konuşması süren, satırı henüz düşmemiş kanallar
    let speaking: Set<Speaker>

    private static let bottomID = "son"

    private var speakingNow: [Speaker] {
        [Speaker.me, .them].filter(speaking.contains)
    }

    var body: some View {
        if blocks.isEmpty, speaking.isEmpty {
            Text(follow ? "Dinleniyor… konuşma başlayınca satırlar burada akacak." : "Bu toplantıda döküm yok.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(blocks) { block in
                            TranscriptBlockView(block: block)
                        }
                        ForEach(speakingNow, id: \.self) { speaker in
                            SpeakingRow(speaker: speaker)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .onChange(of: blocks) { _, _ in
                    guard follow else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: speaking) { _, _ in
                    guard follow else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }
}

/// Konuşma sürerken, satır düşmeden önce görünen "konuşuyor…" satırı.
private struct SpeakingRow: View {
    let speaker: Speaker

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Brand.color(for: speaker).opacity(0.45))
                .frame(width: 3, height: 16)
            Text(speaker.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.color(for: speaker))
            Text("konuşuyor…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptBlock

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Brand.color(for: block.speaker))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(block.speaker.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.color(for: block.speaker))
                    Text(Meeting.clock(block.start))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(block.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Özet

private struct SummaryView: View {
    let text: String
    let working: Bool
    let onSummarize: () -> Void

    var body: some View {
        if text.isEmpty {
            VStack(spacing: 10) {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Özet yazılıyor… model belleğe yüklenirken ilk satır biraz gecikebilir.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Bu toplantının özeti yok.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button("Özet çıkar", action: onSummarize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownLiteView(text: text)
                    if working {
                        ProgressView().controlSize(.small).padding(.top, 12)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Özetin kullandığı Markdown alt kümesi: "## başlık", "- madde", "- [ ] iş", paragraf.
private struct MarkdownLiteView: View {
    let text: String

    private enum Row {
        case heading(String)
        case bullet(String)
        case task(String, done: Bool)
        case paragraph(String)
    }

    private var rows: [Row] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .heading(String(line.dropFirst(2))) }
            if line.hasPrefix("- [ ] ") { return .task(String(line.dropFirst(6)), done: false) }
            if line.lowercased().hasPrefix("- [x] ") { return .task(String(line.dropFirst(6)), done: true) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                switch row {
                case .heading(let title):
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.blue)
                        .padding(.top, index == 0 ? 0 : 12)
                case .bullet(let content):
                    item(marker: "•", content: content)
                case .task(let content, let done):
                    item(marker: done ? "☑" : "☐", content: content)
                case .paragraph(let content):
                    inline(content)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func item(marker: String, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            inline(content)
        }
    }

    private func inline(_ content: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
        return Text(attributed)
            .font(.system(size: 14))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
