import SwiftUI

// Select the property-wrapper type even on SDKs that also export a State macro.
private typealias StoredState<Value> = SwiftUI.State<Value>

struct FloatingDictationView: View {
    @ObservedObject var appState: AppState
    @StoredState private var isHovering = false

    var body: some View {
        Group {
            if appState.isQuickDictating || appState.isTranscribing {
                HStack(spacing: 12) {
                    if appState.isQuickDictating {
                        Button(action: appState.cancelQuickDictation) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel current session; submitted sessions keep processing")
                        .accessibilityLabel("Cancel current dictation session")

                        HStack(spacing: 3) {
                            ForEach(0..<8, id: \.self) { i in
                                let baseScale = 0.5 + 0.5 * sin(Double(i) * 0.9 + 0.5)
                                let barHeight = max(4.0, CGFloat(appState.audioLevel) * 20.0 * CGFloat(baseScale) + 4.0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(appState.audioLevel > 0.05 ? Color.green : Color.white)
                                    .frame(width: 3, height: barHeight)
                                    .animation(.easeOut(duration: 0.08), value: appState.audioLevel)
                            }
                        }
                        .frame(width: 44, height: 20)
                        .accessibilityLabel("Recording session \(appState.sessions.count + 1)")

                        Button(action: appState.continueQuickDictation) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Generate notes so far and keep recording a new session")
                        .accessibilityLabel("Submit notes and start next session")

                        Button(action: appState.finishQuickDictation) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Finish recording and generate notes for this session")
                        .accessibilityLabel("Finish dictation")
                    } else {
                        Button(action: appState.startQuickDictation) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Start another recording while notes process")
                        .accessibilityLabel("Start next dictation session")
                    }

                    if appState.isTranscribing {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 16)
                            Text("\(appState.pendingSessionCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(.white)
                        }
                        .help("\(appState.pendingSessionCount) session(s) waiting or processing")
                        .accessibilityLabel("\(appState.pendingSessionCount) sessions processing")
                    }
                }
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.85))
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                )
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeInOut(duration: 0.22).delay(0.08)),
                    removal: .opacity.animation(.easeInOut(duration: 0.14))
                ))

            } else if let toast = appState.completionToast {
                // COMPLETION TOAST BADGE (Pasted! or Copied (⌘V))
                HStack(spacing: 6) {
                    Image(systemName: appState.hasAccessibility ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                        .foregroundColor(appState.hasAccessibility ? .green : .orange)
                    Text(toast)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.85))
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))

            } else {
                // IDLE / DEFAULT STATE: Shorter thin horizontal rectangle with rounded corners, no icons, better transparency
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        appState.startQuickDictation()
                    }
                }) {
                    RoundedRectangle(cornerRadius: 3.0, style: .continuous)
                        .fill(Color.black.opacity(isHovering ? 0.55 : 0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.0, style: .continuous)
                                .stroke(Color.white.opacity(isHovering ? 0.30 : 0.12), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
                        .frame(width: 42, height: 6)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeInOut(duration: 0.22).delay(0.08)),
                    removal: .opacity.animation(.easeInOut(duration: 0.14))
                ))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: appState.isQuickDictating)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { updateWindowFrame(size: geo.size, animate: false) }
                    .onChange(of: geo.size) { newSize in
                        updateWindowFrame(size: newSize, animate: true)
                    }
            }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hovering
            }
        }
    }

    private func updateWindowFrame(size: CGSize, animate: Bool = true) {
        if let window = NSApplication.shared.windows.first(where: { $0.title == "FloatingOverlay" }),
           let screen = NSScreen.main {
            let rect = screen.visibleFrame
            let newX = rect.midX - (size.width / 2)
            // Position down a teeny tiny bit more (14pt from bottom of visible frame)
            let newY = rect.minY + 14
            let targetFrame = NSRect(x: newX, y: newY, width: size.width, height: size.height)
            
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true
                    window.animator().setFrame(targetFrame, display: true)
                }
            } else {
                window.setFrame(targetFrame, display: true)
            }
        }
    }
}
