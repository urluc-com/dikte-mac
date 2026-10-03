# Build "Dikte" — a fully offline, system-wide dictation app for macOS (Apple Silicon)

Build a complete, compilable Swift Package Manager project (no Xcode project) for a Wispr Flow–style push-to-talk dictation app. Target: macOS 14+, arm64 (M2 Max), `swift build` only. Deliver ALL files: Package.swift, all sources, Resources/Info.plist, build.sh, README.md.

## Architecture

- Menu bar–only app (`LSUIElement=true`, `NSApp.setActivationPolicy(.accessory)`)
- STT: **WhisperKit** — dependency URL is `https://github.com/argmaxinc/argmax-oss-swift` (branch: `main`), product name `WhisperKit`. Do NOT use the old `argmaxinc/WhisperKit` URL.
- Push-to-talk: hold a modifier key → record; release → transcribe → paste into the frontmost app
- Optional cleanup via local Ollama (`http://localhost:11434/api/generate`), silent fallback to raw transcript on any error
- Everything on-device; internet needed only for the first model download

## CRITICAL: Swift concurrency rules (these caused real compile errors — follow exactly)

1. Mark `AppDelegate` as `@MainActor`. Any `@MainActor` class (e.g. an `ObservableObject` transcription service) referenced from a non-annotated AppDelegate fails to compile with "call to main actor-isolated initializer in a synchronous nonisolated context".
2. Do NOT use a `main.swift` file with top-level code — top-level code is NOT treated as MainActor-isolated by the current toolchain and `AppDelegate()` construction fails. Instead use:
   ```swift
   @main
   struct DikteMain {
       @MainActor
       static func main() {
           let app = NSApplication.shared
           let delegate = AppDelegate()
           app.delegate = delegate
           app.setActivationPolicy(.accessory)
           app.run()
       }
   }
   ```
3. Every callback closure that crosses into MainActor state (hotkey press/release handlers, audio level handler, Combine `.sink`) must wrap its body in `Task { @MainActor in ... }`. Do not rely on `DispatchQueue.main.async` to satisfy the compiler.

## Modules

**AudioEngine** — `AVAudioEngine` input tap; convert to 16 kHz mono Float32 PCM with `AVAudioConverter` (Whisper's expected format). Expose `startRecording()`, `stopRecording() -> [Float]`, and an RMS level callback (0–1) for UI animation. Guard sample buffer with a lock.

**Hotkey** — `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents` for `.flagsChanged`. Options selectable in settings: Right Option (keyCode 61, check `.option` flag), Fn (`.function` flag), Right Command (keyCode 54). Track pressed-state transitions to fire press/release exactly once. Input Monitoring permission: check with `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`, request with `IOHIDRequestAccess`.

**Transcription** — `@MainActor ObservableObject` with state enum: idle / downloading(Double) / loading / ready / failed(String).
- Download with `WhisperKit.download(variant:useBackgroundSession:progressCallback:)` (it reuses the Hugging Face cache, so it works offline once downloaded), then init with `WhisperKitConfig(modelFolder: folder.path)`.
- Models: multilingual only — `openai_whisper-small`, `openai_whisper-medium` (default), `openai_whisper-large-v3`. Never offer tiny/base or any `-en` variant (useless for Turkish).
- `DecodingOptions`: `task = .transcribe`, `language = "tr"` by default, `nil` when user selects auto-detect.
- Show download percentage in the menu bar item title.

**TextInjection** — Copy transcript to `NSPasteboard`, simulate Cmd+V via `CGEvent` (virtualKey 9, `.maskCommand`, post to `.cghidEventTap`), then restore the user's previous pasteboard contents (save ALL types/data of existing items, restore after ~0.35 s). Never simulate per-character typing — it breaks Turkish characters (ğ, ş, ı, ö, ü, ç). Check `AXIsProcessTrustedWithOptions` and deep-link to the Accessibility pane if missing.

**LLMCleanup (optional, off by default)** — POST to Ollama with `stream:false`, prompt: fix punctuation, remove filler words, never change meaning, return ONLY the corrected text. Configurable model name (default `qwen2.5`). Timeout ~20 s. On ANY failure return the raw transcript silently.

**UI** — SwiftUI Settings window (hotkey picker, model picker with live download state row, language picker, launch-at-login via `SMAppService.mainApp`, Ollama toggle + model field). During recording show a small borderless non-activating `NSPanel` (`.statusBar` level, ignores mouse, all Spaces) near the bottom of the screen with red bars animated by the audio level. Menu: status line, last-transcript preview (click to copy), Settings, Quit.

## CRITICAL: Permission handling (these caused real runtime failures — follow exactly)

1. **Never gate the microphone permission request solely behind a one-time onboarding screen.** In `beginRecording()`, if mic status is `.notDetermined`, call `AVCaptureDevice.requestAccess(for: .audio)` right there and retry. If `.denied`, show an alert deep-linking to System Settings. (Real failure: user reset permissions with `tccutil`, onboarding never reappeared, app just said "no permission" forever with no way to re-request.)
2. Onboarding (first launch): three steps with live-refreshing status — Microphone (request in-app), Accessibility (`AXIsProcessTrustedWithOptions` with prompt + open settings pane), Input Monitoring (`IOHIDRequestAccess`). Poll statuses every ~1.5 s so returning from System Settings updates the checkmarks. Persist `onboardingDone` in UserDefaults, and add a "Redo permission setup…" menu item that clears the flag and reopens onboarding.
3. **build.sh MUST ad-hoc codesign the bundle** (`codesign --force --deep --sign -`). Unsigned binaries lose TCC permissions (especially Accessibility) on every rebuild.
4. README troubleshooting must include: `tccutil reset Microphone <bundle-id>` + relaunch to re-trigger the prompt; Gatekeeper bypass via right-click > Open or `xattr -dr com.apple.quarantine`.

## CRITICAL: Whisper silence hallucination

When Whisper receives silence/near-silence, it hallucinates subtitle-credit strings (in Turkish typically "Altyazı M.K." or channel-name credits). Mitigate:
- Discard recordings shorter than ~0.4 s (< 6,400 samples at 16 kHz).
- Compute overall RMS of the captured buffer; if below a small threshold (near-silence), skip transcription entirely.
- After transcription, drop results that match known hallucination patterns (strings starting with "Altyazı", "Alt yazı", or consisting only of punctuation/whitespace).

## Packaging

- `Resources/Info.plist`: LSUIElement, `NSMicrophoneUsageDescription` (Turkish string), bundle id, min system version 14.0.
- `build.sh`: `swift build -c release --arch arm64`, assemble `build/Dikte.app` (Contents/MacOS + Info.plist), ad-hoc codesign, print install command.
- Logs to `~/Library/Logs/Dikte/dikte.log` with timestamps (recording start/stop with sample counts, model state changes, warnings). All user-facing text in Turkish.

Generate the complete project now, every file in full — no placeholders, no "rest is similar" omissions.
