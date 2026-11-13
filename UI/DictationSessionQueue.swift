import Foundation

/// Main-thread coordinator. Recording has its own lifetime; note generation
/// and delivery are serialized so results cannot overtake each other.
final class DictationSessionQueue<Destination> {
    enum State: Equatable {
        case queued, transcribing, formatting, delivering, completed, noSpeech
        case failed(String)

        var isPending: Bool {
            switch self {
            case .queued, .transcribing, .formatting, .delivering: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .queued: return "Waiting"
            case .transcribing: return "Transcribing"
            case .formatting: return "Formatting notes"
            case .delivering: return "Delivering notes"
            case .completed: return "Notes ready"
            case .noSpeech: return "No speech detected"
            case .failed: return "Failed — audio retained"
            }
        }
    }

    final class Session: Identifiable {
        let id = UUID()
        let number: Int
        let audioURL: URL
        let destination: Destination
        fileprivate(set) var state: State = .queued
        fileprivate(set) var notes: String?

        init(number: Int, audioURL: URL, destination: Destination) {
            self.number = number
            self.audioURL = audioURL
            self.destination = destination
        }
    }

    typealias Processor = (Session, @escaping (State) -> Void,
                          @escaping (Result<String, Error>) -> Void) -> Void
    var process: Processor?
    var onChange: (() -> Void)?
    private(set) var sessions: [Session] = []
    private var pending: [Session] = []
    private var activeAttempt: UUID?

    var pendingCount: Int { sessions.filter { $0.state.isPending }.count }

    func enqueue(audioURL: URL, destination: Destination) {
        let session = Session(number: sessions.count + 1, audioURL: audioURL, destination: destination)
        sessions.append(session)
        pending.append(session)
        onChange?()
        startNext()
    }

    func retry(_ session: Session) {
        guard sessions.contains(where: { $0 === session }),
              case .failed = session.state else { return }
        session.state = .queued
        pending.append(session)
        onChange?()
        startNext()
    }

    private func startNext() {
        guard activeAttempt == nil, !pending.isEmpty, let process else { return }
        let session = pending.removeFirst()
        let attempt = UUID()
        activeAttempt = attempt
        session.state = .transcribing
        onChange?()
        process(session, { [weak self] state in
            guard let self, self.activeAttempt == attempt else { return }
            session.state = state
            self.onChange?()
        }, { [weak self] result in
            guard let self, self.activeAttempt == attempt else { return }
            switch result {
            case .success(let text):
                session.notes = text.isEmpty ? nil : text
                session.state = text.isEmpty ? .noSpeech : .completed
            case .failure(let error):
                session.state = .failed(error.localizedDescription)
            }
            self.activeAttempt = nil
            self.onChange?()
            self.startNext()
        })
    }
}
