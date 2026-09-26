import Foundation

/// One tiny authenticated request per service, so a typo shows up during
/// setup and not in the middle of the first call. Runs only when the user
/// presses Check key, or opens a Claude path with a key already saved.
enum ProviderKeyCheck {
    enum Service {
        case claude, deepgram

        var name: String { self == .claude ? "Anthropic" : "Deepgram" }
        /// nil = the default (Claude) Keychain slot.
        var keychainAccount: String? { self == .claude ? nil : TranscriptionBackend.deepgram.keychainAccount }
    }

    enum Outcome: Equatable { case works, rejected, unreachable }

    static func request(_ service: Service, key: String) -> URLRequest {
        var request: URLRequest
        switch service {
        case .claude:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .deepgram:
            request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        return request
    }

    /// 2xx works. 400/401/403: the service read the key and said no.
    /// Anything else (429, 5xx, no answer) says nothing about the key.
    static func classify(status: Int?) -> Outcome {
        guard let status else { return .unreachable }
        switch status {
        case 200..<300: return .works
        case 400, 401, 403: return .rejected
        default: return .unreachable
        }
    }

    static func check(_ service: Service, key: String) async -> Outcome {
        let response = try? await URLSession.shared.data(for: request(service, key: key)).1
        return classify(status: (response as? HTTPURLResponse)?.statusCode)
    }

    static func message(_ outcome: Outcome?, _ service: Service) -> String? {
        switch outcome {
        case .works?: "Key works"
        case .rejected?: "That key didn't work. Check it and try again."
        case .unreachable?: "Couldn't reach \(service.name). Check your internet."
        case nil: nil
        }
    }
}
