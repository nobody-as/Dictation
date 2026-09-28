import SwiftUI
import IOKit.pwr_mgt

@main
struct DictationApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(appState: appState)
        } label: {
            Image(systemName: appState.isBackendRunning ? "mic.fill" : "mic")
                .symbolRenderingMode(.palette)
                .foregroundStyle(appState.isBackendRunning ? Color.green : Color.primary)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var connectionState = "Fn tap/hold or ⌥D to dictate"
    @Published var batteryWarning = false
    @Published var audioLevel: Float = 0
    @Published var isQuickDictating = false
    @Published var isTranscribing = false
    @Published var isBackendRunning = false
    @Published var engineStatusText = "Checking Dictation Engine…"
    @Published var hasAccessibility = HotkeyManager.isAccessibilityGranted()
    @Published var hasMicrophone = QuickAudioRecorder.hasMicrophonePermission
    @Published var completionToast: String? = nil

    private var floatingPanel: NSPanel?
    private let audioRecorder = QuickAudioRecorder()
    private let dictator = QuickDictator()
    private let noteFormatter = ContextualNoteFormatter()
    private let hotkeyManager = HotkeyManager()
    private var timer: Timer?
    private var healthTimer: Timer?
    private var meterTimer: Timer?
    private var powerAssertionID: IOPMAssertionID = 0
    private var backendProcess: Process?
    private var isStartingBackend = false
    private var isStoppingBackend = false
    private var recordingStartedByHold = false
    private var failedHealthProbes = 0

    init() {
        DispatchQueue.main.async {
            self.setupPersistentFloatingPill()
            self.configureHotkey()
            self.hotkeyManager.startMonitoring()
            self.beginBackendMonitoring()
            self.startBackgroundTasks()
            self.checkPermissions()
        }
    }

    func checkPermissions() {
        hasAccessibility = HotkeyManager.isAccessibilityGranted()
        hasMicrophone = QuickAudioRecorder.hasMicrophonePermission
    }

    func requestAccessibility() {
        HotkeyManager.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkPermissions()
        }
    }

    func requestMicrophoneAccess() {
        QuickAudioRecorder.requestMicrophonePermission { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                self?.checkPermissions()
            }
        }
    }

    private func configureHotkey() {
        // Fn Hold-to-Talk or Tap-to-Toggle
        hotkeyManager.onFnDown = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.isTranscribing else { return }
                if !self.isQuickDictating {
                    self.recordingStartedByHold = true
                    self.startQuickDictation()
                }
            }
        }

        hotkeyManager.onFnUp = { [weak self] duration in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isQuickDictating, !self.isTranscribing else { return }

                if self.recordingStartedByHold {
                    if duration >= 0.40 {
                        // User held Fn to talk and released -> finish!
                        self.finishQuickDictation()
                    } else {
                        // User tapped Fn to start toggle recording -> stay recording!
                        self.recordingStartedByHold = false
                    }
                } else {
                    // Recording was already active -> tap or release finishes!
                    self.finishQuickDictation()
                }
            }
        }

        // Carbon global hotkey (Option + D): Toggle dictation on/off system-wide
        hotkeyManager.onToggleHotkey = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.toggleQuickDictation()
            }
        }
    }

    // MARK: - Backend lifecycle

    func startBackgroundTasks() {
        guard !isStartingBackend else { return }
        isStoppingBackend = false
        isStartingBackend = true
        engineStatusText = "Starting Dictation Engine…"

        probeBackend { [weak self] isHealthy, state, detail in
            guard let self else { return }
            if isHealthy {
                self.applyHealthyBackendState(state: state, detail: detail)
                self.isStartingBackend = false
                return
            }
            self.launchBackendProcess()
        }
    }

    private func launchBackendProcess() {
        guard let resourcePath = Bundle.main.resourcePath else {
            backendLaunchFailed("App Resources not found")
            return
        }
        let workDir = "\(resourcePath)/Backend"
        #if arch(x86_64)
        let script = "\(workDir)/server_intel.py"
        #else
        let script = "\(workDir)/server.py"
        #endif

        guard FileManager.default.fileExists(atPath: script) else {
            backendLaunchFailed("Backend server.py is missing in bundle")
            return
        }

        let process = Process()
        let installedPython = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacLocalDictation/venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: installedPython.path) {
            process.executableURL = installedPython
            process.arguments = [script]
        } else {
            // Keep source builds usable with an existing Python installation.
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "python3 \"\(script)\""]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)

        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(existingPath)"
        process.environment = env

        // Redirect backend logs to ~/Library/Logs/MacLocalDictation/backend.log
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacLocalDictation")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("backend.log")
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        if let fileHandle = try? FileHandle(forWritingTo: logFile) {
            fileHandle.seekToEndOfFile()
            process.standardOutput = fileHandle
            process.standardError = fileHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                print("Backend exited with code \(process.terminationStatus)")
                self.backendProcess = nil
                if !self.isStoppingBackend {
                    self.probeAndPublishBackendState()
                }
            }
        }

        do {
            try process.run()
            backendProcess = process
            print("✅ Backend launched (PID \(process.processIdentifier))")
            pollBackendReady(retries: 60)
        } catch {
            backendLaunchFailed("Could not launch backend: \(error.localizedDescription)")
        }
    }

    private func backendLaunchFailed(_ message: String) {
        isStartingBackend = false
        isBackendRunning = false
        engineStatusText = message
        print("❌ \(message)")
    }

    private func beginBackendMonitoring() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.probeAndPublishBackendState()
        }
    }

    private func pollBackendReady(retries: Int) {
        probeBackend { [weak self] isHealthy, state, detail in
            guard let self else { return }
            if isHealthy {
                self.applyHealthyBackendState(state: state, detail: detail)
                self.isStartingBackend = false
            } else if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.pollBackendReady(retries: retries - 1)
                }
            } else {
                self.backendLaunchFailed("Engine did not become ready")
            }
        }
    }

    private func probeAndPublishBackendState() {
        guard !isStoppingBackend else { return }
        checkPermissions()
        probeBackend { [weak self] isHealthy, state, detail in
            guard let self else { return }
            if isHealthy {
                self.failedHealthProbes = 0
                self.applyHealthyBackendState(state: state, detail: detail)
            } else if !self.isStartingBackend {
                self.failedHealthProbes += 1
                if self.failedHealthProbes >= 3 {
                    self.isBackendRunning = false
                    self.engineStatusText = "Engine Stopped"
                }
            }
        }
    }

    private func probeBackend(completion: @escaping (Bool, String, String) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:8080/health") else {
            completion(false, "", "")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            var state = "ready"
            var detail = "Dictation Engine ready"
            if let data,
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                state = payload["engine"] as? String ?? state
                detail = payload["detail"] as? String ?? detail
            }
            DispatchQueue.main.async {
                completion(statusCode == 200, state, detail)
            }
        }.resume()
    }

    private func applyHealthyBackendState(state: String, detail: String) {
        isBackendRunning = true
        if !isTranscribing {
            engineStatusText = state == "transcribing" ? "Transcribing…" : (detail.isEmpty ? "Engine Ready" : detail)
        }
    }

    func stopBackgroundTasks() {
        isStartingBackend = false
        isStoppingBackend = true
        backendProcess?.terminate()
        backendProcess = nil

        if let url = URL(string: "http://127.0.0.1:8080/shutdown") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 1
            URLSession.shared.dataTask(with: request).resume()
        }

        isBackendRunning = false
        engineStatusText = "Engine Stopped"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.isStoppingBackend = false
        }
        print("Backend Python server stopped.")
    }

    // MARK: - Quick dictation

    private func setupPersistentFloatingPill() {
        if floatingPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 150, height: 40),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.title = "FloatingOverlay"
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.isMovableByWindowBackground = false
            
            // The window frame is now dynamically controlled by FloatingDictationView to ensure it remains centered when expanding.
            let hostingView = NSHostingView(rootView: FloatingDictationView(appState: self))
            panel.contentView = hostingView

            if let screen = NSScreen.main {
                let rect = screen.visibleFrame
                // Position center-low on the screen
                panel.setFrameOrigin(NSPoint(x: rect.midX - 75, y: rect.minY + 14))
            }
            floatingPanel = panel
        }
        floatingPanel?.orderFrontRegardless()
    }

    func toggleQuickDictation() {
        if isQuickDictating {
            finishQuickDictation()
        } else {
            startQuickDictation()
        }
    }

    func startQuickDictation() {
        guard !isQuickDictating, !isTranscribing else { return }

        // Check microphone permission
        if !QuickAudioRecorder.hasMicrophonePermission {
            engineStatusText = "Microphone permission needed"
            requestMicrophoneAccess()
            return
        }

        // Check accessibility permission (prompt if missing so auto-paste will work)
        if !HotkeyManager.isAccessibilityGranted() {
            print("⚠️ Accessibility permission not enabled; requesting permission")
            HotkeyManager.requestAccessibilityPermission()
        }

        if !isBackendRunning {
            startBackgroundTasks()
        }

        dictator.captureFocus()
        guard audioRecorder.startRecording() else {
            engineStatusText = "Microphone unavailable"
            return
        }
        isQuickDictating = true
        preventSleep()
        setupPersistentFloatingPill()

        // Live audio level metering for visual feedback
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.audioLevel = self.audioRecorder.currentAudioLevel()
        }
    }

    func finishQuickDictation() {
        guard isQuickDictating, !isTranscribing else { return }
        isTranscribing = true
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0
        engineStatusText = "Transcribing speech…"

        audioRecorder.stopRecording { [weak self] data in
            guard let self, let audioData = data, !audioData.isEmpty else {
                DispatchQueue.main.async {
                    self?.allowSleep()
                    self?.isTranscribing = false
                    self?.isQuickDictating = false
                    self?.engineStatusText = "Audio recording empty"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        if self?.isQuickDictating == false && self?.isTranscribing == false {
                            self?.engineStatusText = "Engine Ready"
                        }
                    }
                }
                return
            }
            self.transcribeAudio(audioData: audioData)
        }
    }

    private func transcribeAudio(audioData: Data) {
        guard let url = URL(string: "http://127.0.0.1:8080/transcribe") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue("\(audioData.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = audioData
        request.timeoutInterval = .infinity

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, (200..<300).contains(statusCode), let data else {
                    self.allowSleep()
                    self.isTranscribing = false
                    self.isQuickDictating = false
                    self.engineStatusText = "Transcription failed"
                    print("❌ Transcription request failed: \(error?.localizedDescription ?? "HTTP \(statusCode)")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        if self?.isQuickDictating == false && self?.isTranscribing == false {
                            self?.engineStatusText = "Engine Ready"
                        }
                    }
                    return
                }

                guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = payload["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.allowSleep()
                    self.isTranscribing = false
                    self.isQuickDictating = false
                    self.engineStatusText = "No speech detected"
                    print("ℹ️ No speech was detected")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        if self?.isQuickDictating == false && self?.isTranscribing == false {
                            self?.engineStatusText = "Engine Ready"
                        }
                    }
                    return
                }

                self.engineStatusText = "Formatting notes…"
                self.noteFormatter.format(text) { [weak self] formattedText in
                    guard let self else { return }
                    self.dictator.pasteDictationResult(formattedText) { [weak self] inserted in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.allowSleep()
                            self.isTranscribing = false
                            self.isQuickDictating = false
                            if inserted {
                                NSSound(named: "Glass")?.play()
                                self.engineStatusText = "Notes pasted!"
                                self.completionToast = "Pasted!"
                            } else {
                                self.engineStatusText = "Copied to clipboard (⌘V)"
                                self.completionToast = "Copied (⌘V)"
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                self.completionToast = nil
                                if !self.isQuickDictating && !self.isTranscribing {
                                    self.engineStatusText = "Engine Ready"
                                }
                            }
                        }
                    }
                }
            }
        }.resume()
    }

    func cancelQuickDictation() {
        isQuickDictating = false
        isTranscribing = false
        meterTimer?.invalidate()
        meterTimer = nil
        audioLevel = 0
        allowSleep()
        audioRecorder.stopRecording { _ in }
        engineStatusText = "Engine Ready"
        print("Cancelled Quick Dictation.")
    }

    // MARK: - Sleep management

    private func preventSleep() {
        let reason = "Active Dictation Recording" as CFString
        _ = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &powerAssertionID
        )
    }

    private func allowSleep() {
        if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = 0
        }
    }

    deinit {
        healthTimer?.invalidate()
        meterTimer?.invalidate()
        timer?.invalidate()
        allowSleep()
    }
}
