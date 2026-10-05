import Foundation

/// Whisper sessizlik ya da gürültü aldığında altyazı künyesi gibi kalıp cümleler uydurur
/// (Türkçede tipik olarak "Altyazı M.K."). Bu süzgeç o bilinen kalıpları yakalar.
enum HallucinationFilter {
    private static let prefixes = [
        "altyazı", "alt yazı", "altyazi",
        "izlediğiniz için teşekkür",
        "abone olmayı unutmayın",
        "bir sonraki videoda görüşmek üzere",
        "thanks for watching", "thank you for watching",
        "subtitles by", "subtitled by",
        "www."
    ]

    static func isHallucination(_ text: String) -> Bool {
        if isNonSpeechTag(text) { return true }
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    /// Metin yalnız noktalama, müzik işareti ya da "[Müzik]" gibi köşeli/yuvarlak parantezli
    /// bir etiketten mi ibaret?
    static func isNonSpeechTag(_ text: String) -> Bool {
        let stripped = text
            .replacingOccurrences(of: #"[\[\(][^\]\)]*[\]\)]"#, with: "", options: .regularExpression)
        return !stripped.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })
    }
}
