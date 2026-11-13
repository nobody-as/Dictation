import Cocoa
import ApplicationServices

final class QuickDictator {
    private struct Target: Equatable {
        let app: NSRunningApplication
        let element: AXUIElement

        static func == (lhs: Target, rhs: Target) -> Bool {
            lhs.app.processIdentifier == rhs.app.processIdentifier
                && lhs.app.launchDate == rhs.app.launchDate
                && CFEqual(lhs.element, rhs.element)
        }
    }

    private var target: Target?
    private var capturedSecureField = false

    /// Capture app/field identity only, never its text. A nonactivating bubble
    /// leaves the user's selected app frontmost. No previous-app fallback.
    func captureFocus() {
        let snapshot = focusedTarget()
        target = snapshot.target
        capturedSecureField = snapshot.secure
    }

    private func focusedTarget() -> (target: Target?, secure: Bool) {
        guard HotkeyManager.isAccessibilityGranted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated else { return (nil, false) }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString,
                                             &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (nil, false) }
        let element = focused as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == app.processIdentifier else { return (nil, false) }

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        let secure = (subrole as? String) == "AXSecureTextField"
        guard !secure else { return (nil, true) }
        // Recheck the selected app after the Accessibility calls complete.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return (nil, false) }
        return (Target(app: app, element: element), false)
    }

    func pasteDictationResult(_ text: String, completion: @escaping (PasteDeliveryResult) -> Void) {
        var clipboardVersion: Int?
        let delivery = PasteDelivery<Target>(
            currentTarget: { [weak self] in self?.focusedTarget().target },
            copyText: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else { return false }
                clipboardVersion = pasteboard.changeCount
                return true
            },
            insertText: { text, target in
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString,
                                                     &settable) == .success, settable.boolValue,
                      self.focusedTarget().target == target else { return false }
                return AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString,
                                                     text as CFTypeRef) == .success
            },
            requestPaste: { target in
                guard let clipboardVersion, NSPasteboard.general.changeCount == clipboardVersion,
                      self.focusedTarget().target == target,
                      let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return false }
                down.flags = .maskCommand
                up.flags = .maskCommand
                // Deliver a single Cmd+V to this process only. A system-wide
                // HID/AppleScript fallback could paste into another app.
                down.postToPid(target.app.processIdentifier)
                up.postToPid(target.app.processIdentifier)
                return true
            }
        )
        completion(delivery.deliver(text, to: target, secureField: capturedSecureField))
    }
}
