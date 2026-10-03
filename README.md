# Dikte 🎙️

Wispr Flow tarzı, **tamamen offline** çalışan macOS dikte uygulaması.
Kısayol tuşuna basılı tut → konuş → bırak → metin, o an odaklı olduğun
uygulamaya (Terminal, VS Code, Safari, Notlar, Slack, WhatsApp…) yazılır.

- **STT:** WhisperKit (Apple Neural Engine, M2 Max'te çok hızlı)
- **Dil:** Türkçe varsayılan (otomatik algılama ve İngilizce seçeneği var)
- **Gizlilik:** Ses cihazdan asla çıkmaz. İnternet yalnızca ilk model indirmede gerekir.
- **Opsiyonel:** Yerel Ollama ile noktalama/dolgu kelime temizliği

## Gereksinimler

- Apple Silicon Mac (M2 Max ✅ — Neural Engine hızlandırması kullanılır)
- macOS 14 Sonoma veya üzeri
- Xcode Command Line Tools: `xcode-select --install`
- İlk model indirmesi için internet (~1.5 GB, medium model)

## Derleme

```bash
cd Dikte
./build.sh
cp -R build/Dikte.app /Applications/
```

Yalnızca hızlı test için: `swift build && .build/debug/Dikte`

### "Tanımlanamayan geliştirici" uyarısı

Uygulama notarize edilmediği için (kişisel kullanım) ilk açılışta macOS uyarı verir:

1. Finder'da `Dikte.app`'e **sağ tıkla > Aç**
2. Çıkan pencerede tekrar **Aç**'a bas
3. Bu işlem tek seferlik — sonrası normal açılır

Alternatif: `xattr -dr com.apple.quarantine /Applications/Dikte.app`

## İlk açılış — izinler

Onboarding ekranı seni adım adım yönlendirir:

| İzin | Neden | Nereden |
|---|---|---|
| Mikrofon | Ses yakalama | Otomatik istenir |
| Erişilebilirlik | Metni Cmd+V ile yapıştırma | Gizlilik ve Güvenlik > Erişilebilirlik |
| Giriş İzleme | Kısayolu her uygulamada dinleme | Gizlilik ve Güvenlik > Giriş İzleme |

> ⚠️ İzin verdikten sonra macOS bazen uygulamanın yeniden başlatılmasını ister.
> Yeniden derlersen (binary değişirse) Erişilebilirlik iznini kaldırıp tekrar
> vermen gerekebilir — bu yüzden build.sh ad-hoc imza atar.

## Kullanım

1. İlk açılışta **medium** Whisper modeli otomatik iner (menü çubuğunda % ilerleme görünür)
2. Model hazır olunca herhangi bir metin alanına tıkla
3. **Sağ Option (⌥)** tuşuna basılı tut, konuş, bırak
4. Metin imlecin olduğu yere yazılır ✨

Kısayol, model boyutu ve dil **menü çubuğu > Ayarlar**'dan değiştirilebilir.

### Model seçimi (Türkçe için)

| Model | Boyut | Türkçe doğruluk | M2 Max hızı |
|---|---|---|---|
| small | ~500 MB | orta | çok hızlı |
| **medium** (varsayılan) | ~1.5 GB | iyi | hızlı |
| large-v3 | ~3 GB | en iyi | yeterince hızlı |

M2 Max'te large-v3 bile rahat çalışır; en iyi Türkçe sonuç için onu seçebilirsin.
`tiny`/`base` bilinçli olarak sunulmadı — Türkçe için yetersiz.

## Opsiyonel: Ollama ile temizleme

```bash
brew install ollama
ollama serve
ollama pull qwen2.5
```

Sonra Ayarlar'dan "Ollama ile transkripti düzelt"i aç. Ollama kapalıysa
uygulama sessizce ham transkripti kullanır, hata vermez.

## Sorun giderme

- **Loglar:** `~/Library/Logs/Dikte/dikte.log`
- **Kısayol çalışmıyor:** Giriş İzleme iznini kontrol et; uygulamayı yeniden başlat
- **Metin yapışmıyor:** Erişilebilirlik iznini kaldırıp yeniden ver
- **Model indirme takıldı:** `~/Documents/huggingface` klasörünü silip tekrar dene
- **Derleme hatası (WhisperKit API):** Paket aktif geliştiriliyor; `Package.swift`
  içinde `branch: "main"` yerine son sürüm tag'ini sabitlemeyi dene

## Mimari

```
Sources/Dikte/
  App/            main.swift, AppDelegate (orkestrasyon), AppSettings
  AudioEngine/    AVAudioEngine → 16kHz mono Float32 PCM
  Hotkey/         NSEvent global monitor, push-to-talk (flagsChanged)
  Transcription/  WhisperKit — indirme, offline yükleme, transcribe
  TextInjection/  NSPasteboard + CGEvent Cmd+V (Türkçe karakter güvenli)
  LLMCleanup/     Ollama HTTP (localhost:11434), sessiz fallback
  UI/             Ayarlar (SwiftUI), floating kayıt paneli, onboarding
  Support/        Dosya loglama
```

Türkçe karakterler (ğ, ş, ı, ö, ü, ç) için karakter karakter klavye
simülasyonu yerine **pano + Cmd+V** yöntemi kullanılır; işlem sonrası
eski pano içeriği geri yüklenir.
