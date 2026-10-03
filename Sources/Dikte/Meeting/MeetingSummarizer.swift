import Foundation

/// Toplantı dökümünü yerel Ollama modeliyle özetler: başlık, özet, konuşulanlar, kararlar,
/// yapılacaklar. Bağlama sığmayan uzun dökümler bölüm bölüm notlanıp sonra birleştirilir.
@MainActor
enum MeetingSummarizer {
    struct Result {
        /// Modelin önerdiği başlık (ilk "# …" satırı), varsa
        let title: String?
        /// Başlık satırı ayrılmış Markdown özet
        let body: String
        let stats: OllamaClient.ChatStats
    }

    /// Bağlam boyunu seçerken kullanılan ihtiyatlı oran. Qwen 3.8 ile ölçülen değer Türkçe
    /// dökümde 1 token ≈ 3,1 karakter (4.400 karakterlik istem 1.425 token tuttu); pay
    /// kalsın diye daha düşük alındı.
    private static let charsPerToken = 2.4
    /// Tek seferde modele verilecek en uzun döküm (karakter): ihtiyatlı oranla ~24 bin token
    private static let maxSinglePassChars = 58_000
    private static let outputReserveTokens = 1_500

    static func summarize(
        meeting: Meeting,
        model: String,
        language: LanguageOption,
        onPartial: @MainActor (String) -> Void
    ) async throws -> Result {
        let english = language == .english
        let header = (english ? "Meeting date: " : "Toplantı tarihi: ") + Meeting.dateLabel(meeting.startedAt)
        let transcript = meeting.transcriptText

        var stats = OllamaClient.ChatStats()
        let material: String
        if transcript.count <= maxSinglePassChars {
            material = (english ? "TRANSCRIPT:\n" : "DÖKÜM:\n") + transcript
        } else {
            // Uzun toplantı: bölümleri ayrı ayrı notla, özeti notlardan çıkar
            let parts = split(transcript, maxChars: maxSinglePassChars)
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                onPartial(english ? "Reading part \(index + 1) of \(parts.count)…"
                                  : "Döküm okunuyor: bölüm \(index + 1)/\(parts.count)…")
                let user = (english ? "PART \(index + 1) OF \(parts.count):\n" : "BÖLÜM \(index + 1)/\(parts.count):\n") + part
                let (text, partStats) = try await OllamaClient.chatStream(
                    model: model,
                    system: english ? partPromptEN : partPromptTR,
                    user: user,
                    numCtx: await contextSize(forChars: user.count, model: model),
                    onDelta: { _ in }
                )
                notes.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                stats.promptTokens += partStats.promptTokens
                stats.outputTokens += partStats.outputTokens
                stats.seconds += partStats.seconds
            }
            material = (english ? "NOTES FROM EACH PART OF THE MEETING, IN ORDER:\n" : "TOPLANTININ BÖLÜM NOTLARI, SIRAYLA:\n")
                + notes.enumerated().map { "--- \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n")
        }

        let user = header + "\n\n" + material
        let (text, finalStats) = try await OllamaClient.chatStream(
            model: model,
            system: english ? summaryPromptEN : summaryPromptTR,
            user: user,
            numCtx: await contextSize(forChars: user.count, model: model),
            onDelta: { partial in onPartial(splitTitle(partial).body) }
        )
        stats.promptTokens += finalStats.promptTokens
        stats.outputTokens += finalStats.outputTokens
        stats.seconds += finalStats.seconds

        let (title, body) = splitTitle(text)
        guard !body.isEmpty else {
            throw NSError(domain: "Dikte.Ozet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model boş yanıt verdi."])
        }
        return Result(title: title, body: body, stats: stats)
    }

    /// İlk "# Başlık" satırını gövdeden ayırır.
    static func splitTitle(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("# ") else { return (nil, trimmed) }
        let lines = trimmed.components(separatedBy: "\n")
        let title = String(lines[0].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, body)
    }

    // MARK: - Yardımcılar

    /// İstem + yanıt payına yetecek bağlam boyu. Model zaten yeterli bir bağlamla bellekteyse
    /// o boy kullanılır: farklı bir boy istemek Ollama'ya modeli baştan yükletir.
    private static func contextSize(forChars chars: Int, model: String) async -> Int {
        let needed = Int(Double(chars + 1_800) / charsPerToken) + outputReserveTokens
        if let loaded = await OllamaClient.loadedModels().first(where: { $0.name == model }),
           loaded.contextLength >= needed {
            return loaded.contextLength
        }
        return [8_192, 16_384, 32_768].first { $0 >= needed } ?? 32_768
    }

    /// Dökümü satır sınırlarından, her biri `maxChars`'ı aşmayan bölümlere ayırır.
    private static func split(_ transcript: String, maxChars: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for line in transcript.components(separatedBy: "\n") {
            if !current.isEmpty, current.count + line.count + 1 > maxChars {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - İstemler

    private static let summaryPromptTR = """
    Sen bir toplantı notu asistanısın. Sana bir görüşmenin konuşma dökümü (ya da bölüm bölüm çıkarılmış notları) verilecek.
    Dökümde "Ben" notu tutan kişidir, "Karşı taraf" görüşmedeki diğer kişi ya da kişilerdir.
    Döküm otomatik konuşma tanımayla üretildi: yanlış duyulmuş kelimeleri bağlamdan düzelt, ama dökümde geçmeyen hiçbir bilgi, isim, tarih ya da rakam ekleme. Emin olmadığın şeyi yazma.

    Yalnızca aşağıdaki Markdown biçiminde, Türkçe yaz; öncesine ya da sonrasına başka hiçbir şey ekleme:

    # <toplantıyı anlatan en fazla 8 kelimelik başlık>

    ## Özet
    <3-5 cümle: ne konuşuldu, nereye varıldı>

    ## Konuşulanlar
    - <ana konular madde madde; kimin ne dediği önemliyse belirt>

    ## Kararlar
    - <alınan kararlar; hiç yoksa tek madde: Karar alınmadı.>

    ## Yapılacaklar
    - [ ] <kim> — <ne yapacak> (<ne zaman, söylendiyse>)
    <yapılacak iş yoksa tek madde: Yapılacak iş çıkmadı.>

    ## Açık sorular
    - <cevapsız kalan sorular; yoksa bu bölümü hiç yazma>
    """

    private static let partPromptTR = """
    Sana uzun bir toplantı dökümünün bir bölümü verilecek. "Ben" notu tutan kişidir, "Karşı taraf" diğer kişi ya da kişilerdir.
    Bu bölümde konuşulan konuları, alınan kararları, üstlenilen işleri (kim, ne, ne zaman) ve cevapsız kalan soruları kısa maddelerle, eksiksiz çıkar.
    Dökümde geçmeyen bilgi ekleme. Yalnızca maddeleri yaz.
    """

    private static let summaryPromptEN = """
    You are a meeting notes assistant. You will get the transcript of a call (or notes taken part by part).
    In the transcript "Ben" is the person taking notes and "Karşı taraf" is the other participant or participants.
    The transcript comes from automatic speech recognition: fix misheard words from context, but never add a fact, name, date or number that is not in the transcript. Leave out anything you are unsure of.

    Write in English, in exactly this Markdown format, with nothing before or after it:

    # <a title of at most 8 words>

    ## Summary
    <3-5 sentences: what was discussed and where it landed>

    ## Discussion
    - <main topics as bullets; say who said what when it matters>

    ## Decisions
    - <decisions made; if none, a single bullet: No decisions were made.>

    ## Action items
    - [ ] <who> — <what> (<when, if stated>)
    <if there are none, a single bullet: No action items.>

    ## Open questions
    - <questions left unanswered; omit this section if there are none>
    """

    private static let partPromptEN = """
    You will get one part of a long meeting transcript. "Ben" is the person taking notes, "Karşı taraf" is the other participant or participants.
    List the topics discussed, decisions made, tasks taken on (who, what, when) and questions left unanswered in this part as short, complete bullets.
    Do not add anything that is not in the transcript. Write only the bullets.
    """
}
