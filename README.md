# Dikte 🎙️

Wispr Flow tarzı, **tamamen yerel** çalışan macOS dikte ve toplantı notu uygulaması.

- **Dikte:** kısayol tuşuna basılı tut → konuş → bırak → metin, o an odaklı olduğun
  uygulamaya (Terminal, VS Code, Safari, Notlar, Slack, WhatsApp…) yazılır.
- **Toplantı:** mikrofonunu ve Mac'te çalan sesi birlikte dinler; kim ne dediyse
  "Ben" / "Karşı taraf" diye ayırıp canlı yazıya döker, bitince özetini çıkarır.

- **STT:** WhisperKit (Apple Neural Engine, M2 Max'te çok hızlı)
- **Dil:** Türkçe varsayılan (otomatik algılama ve İngilizce seçeneği var)
- **Gizlilik:** Ses cihazdan asla çıkmaz. İnternet yalnızca ilk model indirmede gerekir.
- **Opsiyonel:** Yerel Ollama ile noktalama/dolgu kelime temizliği

## Gereksinimler

- Apple Silicon Mac (M2 Max ✅ — Neural Engine hızlandırması kullanılır)
- macOS 14.4 veya üzeri (sistem sesi yakalama için)
- Xcode Command Line Tools: `xcode-select --install`
- İlk model indirmesi için internet (~1,6 GB, Large v3 Turbo)
- Toplantı özeti için yerel Ollama (`localhost:11434`)

## Derleme

```bash
./build.sh            # build/Dikte.app
./build.sh install    # derle + /Applications/Dikte.app
```

Betik, anahtar zincirinde **Apple Development** kimliği varsa onunla imzalar; yoksa
ad-hoc imzaya düşer. Fark önemli: macOS izinleri (mikrofon, sistem sesi,
erişilebilirlik) imza kimliğine bağlar; ad-hoc imza her derlemede değiştiği için
izinler düşer, geliştirici kimliğiyle yerinde kalır.

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
| Sistem sesi kaydı | Toplantıda karşı tarafın sesi | İlk toplantıda otomatik istenir (Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı) |

> ⚠️ İzin verdikten sonra macOS bazen uygulamanın yeniden başlatılmasını ister.
> Yeniden derlersen (binary değişirse) Erişilebilirlik iznini kaldırıp tekrar
> vermen gerekebilir — bu yüzden build.sh ad-hoc imza atar.

## Kullanım

1. İlk açılışta **Large v3 Turbo** Whisper modeli otomatik iner (menü çubuğunda % ilerleme görünür);
   ardından Core ML modeli bu Mac'e göre bir kez derler, bu ilk seferde birkaç dakika sürer
2. Model hazır olunca herhangi bir metin alanına tıkla
3. **Sağ Option (⌥)** tuşuna basılı tut, konuş, bırak
4. Metin imlecin olduğu yere yazılır ✨

Kısayol, model boyutu ve dil **menü çubuğu > Ayarlar**'dan değiştirilebilir.

### Model seçimi (Türkçe için)

| Model | Boyut | Türkçe doğruluk | M2 Max hızı |
|---|---|---|---|
| small | ~500 MB | orta | çok hızlı |
| medium | ~1,5 GB | iyi | hızlı |
| **large-v3-turbo** (varsayılan) | ~1,6 GB | large'a yakın | hızlı |
| large-v3 | ~3 GB | en iyi | yeterince hızlı |

`tiny`/`base` bilinçli olarak sunulmadı — Türkçe için yetersiz.

Modeller varsayılan olarak `~/Library/Application Support/Dikte/Modeller` altına iner;
klasör Ayarlar'dan değiştirilebilir (`defaults write com.urluc.dikte modelFolder <yol>`).
Klasör harici diskteyse ve disk takılı değilse uygulama modeli iç diske indirmez, hata gösterir.

## Toplantı kipi

Menü çubuğu → **Toplantıyı başlat** (ya da Toplantılar penceresindeki düğme).

- **İki kanal:** mikrofon = "Ben", Mac'te çalan ses = "Karşı taraf". Ses işletim
  sisteminin çıkışından alındığı için tarayıcı, Teams, Slack, Zoom fark etmez.
- **Canlı döküm:** her kanal kendi içinde konuşma parçalarına bölünür (konuşan 0,7 sn
  durunca parça kapanır), parçalar sırayla Whisper'dan geçer ve zaman sırasına göre dizilir.
- **Özet:** "Bitir ve özetle" deyince döküm yerel Ollama modeline gider; başlık, özet,
  konuşulanlar, kararlar, yapılacaklar çıkar. Ollama kapalıysa döküm yine kaydedilir.
- **Bellek:** toplantı başlarken Ollama'daki büyük model bellekten çıkarılır (Ayarlar'dan
  kapatılabilir), özet için sonda yeniden yüklenir. 32 GB'ta Whisper ile 27B'lik model
  aynı anda rahat durmuyor.
- **Kayıt yeri:** `~/Library/Application Support/Dikte/Toplantilar/<tarih>/` altında
  `toplanti.json`, `Döküm.md`, `Özet.md`. Ses kaydı saklanmaz.

Bilinen sınırlar:

- Karşı tarafta birden çok kişi varsa hepsi "Karşı taraf" olarak yazılır (kişi kişi
  ayrım yok).
- Hoparlör kullanırken mikrofon karşı tarafın sesini de duyar. Aynı anda sistem sesinden
  gelen konuşmayla büyük ölçüde aynı kelimeleri taşıyan mikrofon satırı "yankı" sayılıp
  atılır; iki taraf aynı anda konuşursa bu ayrım bozulabilir. Kulaklık en temiz sonucu verir.
- Toplantı sürerken bas-konuş dikte kapalıdır (mikrofon ve model toplantıya ayrılır).
- Görüşmeyi kaydetmeden önce karşı tarafa haber ver.

## Opsiyonel: Ollama ile temizleme

Ayarlar'daki Ollama modeli (varsayılan `qwen3.8:27b-mlx`) hem toplantı özetinde hem
dikte düzeltmesinde kullanılır. Dikte düzeltmesi için Ayarlar'dan "Dikte metnini modelle
düzelt"i aç. Ollama kapalıysa
uygulama sessizce ham transkripti kullanır, hata vermez.

## Sorun giderme

- **Loglar:** `~/Library/Logs/Dikte/dikte.log`
- **Kısayol çalışmıyor:** Giriş İzleme iznini kontrol et; uygulamayı yeniden başlat
- **Metin yapışmıyor:** Erişilebilirlik iznini kaldırıp yeniden ver
- **Model indirme takıldı:** model klasöründeki `models/argmaxinc` klasörünü silip tekrar dene
- **Toplantıda karşı taraf yazılmıyor:** Gizlilik ve Güvenlik > Ekran ve Sistem Sesi Kaydı >
  "Yalnızca Sistem Sesi Kaydı" altında Dikte açık mı bak
- **Mikrofon izni sorusu hiç çıkmıyor:** `tccutil reset Microphone com.urluc.dikte`, sonra
  uygulamayı yeniden aç
- **Derleme hatası (WhisperKit API):** Paket aktif geliştiriliyor; `Package.swift`
  içinde `branch: "main"` yerine son sürüm tag'ini sabitlemeyi dene

## Mimari

```
Sources/Dikte/
  App/            DikteMain, AppDelegate (orkestrasyon), AppSettings
  AudioEngine/    mikrofon (AVAudioEngine) + sistem sesi (Core Audio process tap)
                  → 16 kHz mono Float32
  Hotkey/         NSEvent global monitor, push-to-talk (flagsChanged)
  Transcription/  WhisperKit — indirme, offline yükleme, transcribe; uydurma süzgeci
  Meeting/        bölütleyici (VAD), kanal hattı, oturum, yankı süzgeci, depo, özet
  TextInjection/  NSPasteboard + CGEvent Cmd+V (Türkçe karakter güvenli)
  LLMCleanup/     Ollama HTTP (localhost:11434): dikte düzeltme + sohbet istemcisi
  UI/             Ayarlar, toplantı penceresi, floating kayıt paneli, onboarding
  Support/        Dosya loglama, bellek ölçümü, test kancası
Tools/            make-icon.swift (uygulama ikonu)
```

## Test kancası

Toplantı hattı ses aygıtı ve izin gerektirmeden, dosyadan beslenerek uçtan uca
çalıştırılabilir (ayrıntı: `Sources/Dikte/Support/TestHarness.swift`):

```bash
DIKTE_TEST_CIKTI=/tmp/dikte-test \
DIKTE_TEST_SISTEM=karsi.wav DIKTE_TEST_MIK=ben.wav \
DIKTE_TEST_OZET=1 DIKTE_TEST_PENCERE=1 \
build/Dikte.app/Contents/MacOS/Dikte
```

Sonuç `sonuc.json` (satırlar, süreler, bellek) ve `pencere-*.png` olarak yazılır.

Türkçe karakterler (ğ, ş, ı, ö, ü, ç) için karakter karakter klavye
simülasyonu yerine **pano + Cmd+V** yöntemi kullanılır; işlem sonrası
eski pano içeriği geri yüklenir.
