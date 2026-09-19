# Vaani

A private, native macOS push-to-talk typing assistant for Gujarati and English.

## Run locally

Open [GujType.xcodeproj](GujType.xcodeproj) in Xcode and run the `GujType` scheme. This is the supported way to test permissions because it builds a macOS `.app` bundle with the required microphone usage description.

`swift build` remains useful for compile checks, but `swift run` is not a supported permission-flow test because SwiftPM runs a bare executable rather than the app bundle.

For a compile-only check:

```sh
swift run
```

On first run, click the menu-bar icon and choose **Allow Microphone** and **Allow Accessibility**. macOS opens System Settings for Accessibility; enable GujType there, return to the app, then use **Control + 0** (hold 0 and release it when finished). Accessibility is needed for global shortcuts and insertion into the currently focused app.

## Add the local transcription engine

`WhisperTranscriber` invokes a local `whisper.cpp` installation. Install `whisper-cpp` so `whisper-cli` is available at `/opt/homebrew/bin/whisper-cli`, then place a multilingual `ggml-small.bin` or (preferably) `ggml-medium.bin` model in `~/Library/Application Support/GujType/models/`. The app automatically prefers medium when both are present. The recorded CAF is converted locally to 16 kHz WAV and only local processes handle the audio.

The app target already includes `NSMicrophoneUsageDescription` in `Sources/GujType/Info.plist`.

## Optional Sarvam transcription

Settings now offers **Sarvam Saaras** as an optional provider. Save a Sarvam API key in the macOS Keychain, select the provider, and choose the desired format:

- Gujarati sends `gu-IN` with `transcribe` mode.
- Gujlish sends `gu-IN` with Saaras v4 `translit` mode, so the service returns Latin-script Gujarati directly.
- Hindi sends `hi-IN` with `transcribe` mode.
- Hinglish sends `hi-IN` with Saaras v4 `translit` mode, so the service returns Latin-script Hindi directly.
- English fallback sends `en-IN` with `transcribe` mode.

This mode uploads the completed recording (not live microphone audio) to Sarvam. Local mode remains the default and does not upload audio.
English fallback always uses local Whisper, even if Sarvam is selected, so English dictation does not consume Sarvam credits.

## Personal dictionary

Settings includes a local personal dictionary for names, companies, and recurring jargon. When Sarvam is selected, GujType sends its built-in product terms plus up to 42 custom entries as Saaras v4 keyterms (the API maximum is 50 total). In local mode the dictionary remains stored on the Mac but cannot bias the installed offline engines yet.
