# Vaani for iPhone

Vaani is a Gujarati-first dictation app with a system-wide keyboard. Choose Gujarati, Gujlish, Hindi, Hinglish, or English in the app, then enable **Vaani Keyboard** in Settings > General > Keyboard > Keyboards. Select it in any supported text field, tap its microphone, speak, then tap Done to insert the text at the cursor.

Open `Vaani-iOS.xcodeproj` in Xcode, choose your iPhone as the run destination, select your Apple Development team under Signing & Capabilities, and run. Add a Sarvam API key under Settings before transcribing.

The keyboard needs **Allow Full Access** (for Sarvam networking/shared settings) and microphone permission. iOS may refuse third-party keyboards in secure, banking, phone-number, or other restricted fields.
