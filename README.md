# Mac Local Dictation 🎙️

⚠️ **MAC ONLY:** This application runs on Apple Silicon and Intel Macs with macOS 13 or later. It does not run on Windows or Linux.

A completely local dictation tool for macOS powered by **Whisper**. It runs right from your menu bar and uses global keyboard shortcuts so you can transcribe audio anywhere, anytime.

## Install

Open Terminal on your Mac and run:

```bash
set -o pipefail; curl -fsSL https://raw.githubusercontent.com/nobody-as/Dictation/master/install.sh | bash
```

The installer chooses the build for your Mac's processor, downloads the prebuilt app, verifies its checksum and signature, installs it in `/Applications` (or `~/Applications` when system Applications is not writable), prepares a private Python environment for the speech engine, and opens the app. You do not need Xcode, a source checkout, or Homebrew. You need internet access for installation and the first speech-model download; dictation then runs locally. Grant microphone and accessibility access when macOS asks.

The release is built automatically from a version tag. Maintainers can run `bash scripts/package_app.sh OUTPUT_DIR VERSION arm64` (or `x86_64`) on a Mac to create an app bundle without installing it.

## The Story Behind It
I originally built this out of a bit of frustration. I was using a tool called Wispr Flow to transcribe my thoughts, but I quickly hit their limit and was prompted to pay for a subscription. Looking at how it worked, I thought: *"I can probably just build my own version of this for free."* So, I did.

I designed it specifically for note-taking. When you're sitting in a lecture, you should be able to just *listen* to the professor and only jot down the most critical points that naturally come to you. Meanwhile, this app quietly transcribes the entire talk in the background. It gives you a fantastic base transcript that gets automatically formatted into beautiful, readable notes.

## Features
- **100% Free & Local:** Runs locally on your Mac using Whisper—no subscriptions or internet required after setup.
- **Global Shortcuts:** Seamlessly start and stop dictation without leaving the app you are currently typing in.

## 🧠 How the AI Note Formatting Works
This app uses local speech recognition on both Mac processor families:
1. **Speech-to-Text:** Apple Silicon Macs use `Whisper Large v3 Turbo` through Apple's **MLX** framework. Intel Macs use the smaller Whisper model through **faster-whisper** on the CPU, so transcription may take longer and accuracy may differ.
2. **Smart Note Formatting:** On compatible Macs with macOS 26 or later, the frontend uses **Apple Intelligence** (via the native macOS `FoundationModels` API). After transcribing, the app uses a strict prompt to instruct the on-device language model to:
   - Fix all grammatical errors and conversational filler.
   - Separate topics into short paragraphs.
   - Insert Markdown headings (`###`) and bullet points (`•`) for organization.
   - Extract explicitly mentioned takeaways (labeled as `"KEY POINT:"`).
   - Run a strict *fidelity check* to ensure the AI doesn't hallucinate or drop important facts.

### macOS Compatibility & Fallback Mechanism
While the smart formatting requires a compatible Apple Intelligence Mac with **macOS 26.0+**, the app itself runs on **Apple Silicon and Intel Macs with macOS 13.0 or later**.
If you are running an older version of macOS (or if the AI model isn't available), the app won't crash. It seamlessly falls back to a built-in `basicCleanup` function that capitalizes sentences, fixes raw spacing, and adds proper punctuation. You just won't get the advanced Markdown formatting.

## ⚠️ Quick Usage Notes
Because this app runs locally and pastes directly into your workflow, there are two important things to keep in mind:
1. **Cursor Focus is Required:** When you finish dictating and hit the checkmark, the app will automatically type the transcribed text into your currently active window. Make sure you have actually clicked inside a document, note, or text field before confirming!
2. **Give it a Second:** The local Whisper engine and Apple Intelligence are fast, but they still have to think! Depending on how long you were speaking, you will see a green progress bar as it transcribes and formats. Just give it a brief moment to do its magic.
