import Foundation

/// Opsiyonel: Yerel Ollama ile transkript temizleme.
/// Ollama kapalıysa veya hata olursa sessizce ham transkript kullanılır.
enum OllamaCleanup {
    private static let endpoint = URL(string: "http://localhost:11434/api/generate")!

    static func cleanup(_ transcript: String, model: String) async -> String {
        let prompt = """
        Aşağıdaki konuşma transkriptini düzelt. Kurallar:
        - Noktalama işaretlerini ekle.
        - Dolgu kelimelerini ("ııı", "eee", gereksiz "yani", "şey" gibi) temizle.
        - Cümle yapısını akıcı hale getir.
        - Anlamı ASLA değiştirme, hiçbir bilgi ekleme veya çıkarma.
        - SADECE düzeltilmiş metni döndür, başka hiçbir şey yazma.

        Transkript:
        \(transcript)
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            // Düşünme kipi açık kalırsa Qwen zaman aşımına kadar bekletiyor
            "think": false
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return transcript }
        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let cleaned = json["response"] as? String,
                  !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                Log.write("Ollama yanıtı geçersiz, ham transkript kullanılıyor.")
                return transcript
            }
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.write("Ollama'ya ulaşılamadı (\(error.localizedDescription)), ham transkript kullanılıyor.")
            return transcript
        }
    }
}
