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

## Keep recording while notes are generated

The floating bubble supports consecutive sessions:

- **+** submits the audio recorded so far and immediately begins the next segment. The microphone stays running while earlier notes transcribe, format, and paste.
- **✓** submits the current segment and stops listening. You can press **+** again, or use Fn / Option+D, to start another recording while notes finish.
- **×** cancels only the current, unsubmitted segment. Earlier submitted sessions continue processing.
- The waveform stays live during recording. The spinner count shows how many submitted sessions are waiting or processing.

For example, press **+** at minute 30 to generate notes for minutes 0–30 while recording minutes 30 onward. Press **+** as often as needed. Speech recognition, formatting, and delivery run in submission order to avoid overlapping model work and out-of-order notes. Each segment captures the selected app and text field when you press **+** or **✓**. Automatic delivery happens only if that same app and field are still selected when notes finish; Dictation never activates another app to paste. If you switch away, notes stay available through the clipboard or the session’s **Copy** button. Unsupported Accessibility fields get at most one process-targeted paste request, with no system-wide keystroke or AppleScript fallback.

The menu lists this app launch's sessions. Use **Copy** to retrieve any completed session's notes, **Retry** for a failed transcription, or the folder button to find that segment's WAV in Finder. Session audio uses unique files inside private `Dictation-<UUID>` folders in the macOS temporary directory. Splitting, retrying, and starting another recording do not overwrite those files. The app retains them, including failed or cancelled segments; macOS may eventually purge temporary files. Copy notes or save needed audio elsewhere before quitting. The session list and formatted notes are held in memory and are not restored after relaunch. Stop-engine and quit buttons are disabled while recording or submitted work is pending.

### Development checks

Run `bash scripts/test_sessions.sh` on a Mac. It tests session ordering/retry and sample-preserving audio handoff using generated PCM buffers, and verifies paste targeting with fake app/field identities. Tests do not access the microphone, clipboard, live backend, or user recordings. Build an isolated app with `bash scripts/package_app.sh OUTPUT_DIR VERSION arm64` (or `x86_64`). `UI/build_ui.sh` is the existing install-and-launch helper; use the packaging script for build-only verification.

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
1. **Cursor Focus is Required:** When you finish dictating and hit the checkmark, the app captures your selected app and text field. It inserts the notes only if that same destination is still selected when processing finishes. If you switch apps or fields, retrieve the notes with **Copy** in the menu and paste them where you want.
2. **Give it a Second:** The local Whisper engine and Apple Intelligence are fast, but they still have to think! Depending on how long you were speaking, you will see a green progress bar as it transcribes and formats. Just give it a brief moment to do its magic.
