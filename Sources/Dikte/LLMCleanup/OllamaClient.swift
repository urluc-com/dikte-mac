import Foundation

/// Yerel Ollama (localhost:11434) ile konuşan ince istemci: akan sohbet yanıtı,
/// bellekteki modellerin listesi ve boşaltılması.
enum OllamaClient {
    static let base = URL(string: "http://localhost:11434")!

    struct LoadedModel {
        let name: String
        let size: Int64
        /// Modelin o an yüklü olduğu bağlam boyu (token)
        let contextLength: Int
    }

    struct ChatStats {
        var promptTokens = 0
        var outputTokens = 0
        var seconds: Double = 0
    }

    /// Ollama'nın o an bellekte tuttuğu modeller. Ollama kapalıysa boş döner.
    static func loadedModels() async -> [LoadedModel] {
        var request = URLRequest(url: base.appendingPathComponent("api/ps"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            return LoadedModel(
                name: name,
                size: (model["size"] as? NSNumber)?.int64Value ?? 0,
                contextLength: (model["context_length"] as? NSNumber)?.intValue ?? 0
            )
        }
    }

    /// Modeli bellekten çıkarır (keep_alive: 0). Süren bir istek varsa Ollama onu bitirip öyle
    /// boşaltır; sonraki istek modeli yeniden yükler.
    static func unload(model: String) async {
        var request = URLRequest(url: base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Belleği toplantıya açmak için büyük modelleri (4 GB üstü) boşaltır.
    static func unloadLargeModels() async {
        for model in await loadedModels() where model.size > 4_000_000_000 {
            Log.write(String(format: "Ollama modeli bellekten çıkarılıyor: %@ (%.1f GB)",
                             model.name, Double(model.size) / 1e9))
            await unload(model: model.name)
        }
    }

    /// Akan sohbet yanıtı. `onDelta` her yeni metin parçasıyla çağrılır.
    static func chatStream(
        model: String,
        system: String,
        user: String,
        numCtx: Int,
        temperature: Double = 0.2,
        onDelta: @MainActor (String) -> Void
    ) async throws -> (text: String, stats: ChatStats) {
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Model yüklemesi ve uzun dökümün okunması ilk parçayı dakikalarca geciktirebilir
        request.timeoutInterval = 900
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            // Qwen düşünme kipinde dakikalarca bekletiyor; özet için gerek yok
            "think": false,
            // keep_alive bilerek verilmiyor: modelin bellekte kalma süresi Ollama'nın kendi
            // ayarında kalsın (başka işler GPU'nun boşalmasını bekliyor olabilir)
            "options": ["temperature": temperature, "num_ctx": numCtx],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw failure("Ollama yanıt vermedi.")
        }
        guard http.statusCode == 200 else {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            let message = (try? JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any])?["error"] as? String
            throw failure("Ollama hatası (\(http.statusCode)): \(message ?? detail)")
        }

        var text = ""
        var stats = ChatStats()
        for try await line in bytes.lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = json["error"] as? String { throw failure("Ollama hatası: \(error)") }
            if let delta = (json["message"] as? [String: Any])?["content"] as? String, !delta.isEmpty {
                text += delta
                await onDelta(text)
            }
            if json["done"] as? Bool == true {
                stats.promptTokens = json["prompt_eval_count"] as? Int ?? 0
                stats.outputTokens = json["eval_count"] as? Int ?? 0
            }
        }
        stats.seconds = Date().timeIntervalSince(started)
        return (text, stats)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Dikte.Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
