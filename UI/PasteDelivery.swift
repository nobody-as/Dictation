import Foundation

enum PasteDeliveryResult: Equatable {
    case inserted, pasteRequested, copied, retained

    var message: String {
        switch self {
        case .inserted: return "Pasted!"
        case .pasteRequested: return "Paste sent"
        case .copied: return "Copied (⌘V)"
        case .retained: return "Notes ready in menu"
        }
    }
}

/// A delivery attempt never activates an application or chooses a replacement
/// target. Recheck focus before each insertion; send at most one paste request.
struct PasteDelivery<Target: Equatable> {
    var currentTarget: () -> Target?
    var copyText: (String) -> Bool
    var insertText: (String, Target) -> Bool
    var requestPaste: (Target) -> Bool

    func deliver(_ text: String, to captured: Target?, secureField: Bool = false) -> PasteDeliveryResult {
        guard !text.isEmpty else { return .retained }
        guard !secureField else { return .retained }
        let copied = copyText(text)
        let fallback: PasteDeliveryResult = copied ? .copied : .retained
        guard let captured, currentTarget() == captured else { return fallback }
        if insertText(text, captured) { return .inserted }
        // AX calls can take time. The user may select another app or field while
        // an insertion fails; do not send a keystroke to that new destination.
        guard copied, currentTarget() == captured else { return fallback }
        return requestPaste(captured) ? .pasteRequested : fallback
    }
}
