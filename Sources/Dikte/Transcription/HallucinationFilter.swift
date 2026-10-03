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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Yalnız noktalama, müzik işareti ya da "[Müzik]" gibi köşeli/yuvarlak parantezli etiket
        let stripped = trimmed
            .replacingOccurrences(of: #"[\[\(][^\]\)]*[\]\)]"#, with: "", options: .regularExpression)
        if !stripped.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            return true
        }
        let lowered = trimmed.lowercased(with: Locale(identifier: "tr_TR"))
        return prefixes.contains { lowered.hasPrefix($0) }
    }
}
