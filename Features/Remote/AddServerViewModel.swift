import FlaccyCore
import FlaccyEngine
import Foundation

/// The Add Server form on iPhone and Mac: what the person typed, whether the connection test
/// passed, and the two things the form can do, Test and Add. The screens render it and call it.
@MainActor
final class AddServerViewModel {

    enum Kind: Int, CaseIterable {
        case password
        case apiKey

        var title: String {
            switch self {
            case .password: String(localized: "Password")
            case .apiKey: String(localized: "API Key")
            }
        }
    }

    enum TestState: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    var onChange: (() -> Void)?

    var address = "" { didSet { if address != oldValue { resetTest() } } }
    var username = "" { didSet { if username != oldValue { resetTest() } } }
    var password = "" { didSet { if password != oldValue { resetTest() } } }
    var apiKey = "" { didSet { if apiKey != oldValue { resetTest() } } }
    var name = "" { didSet { if name != oldValue { nameWasTyped = true } } }
    var kind: Kind = .password { didSet { if kind != oldValue { resetTest(); onChange?() } } }

    private(set) var testState: TestState = .idle
    private(set) var isAdding = false
    private var nameWasTyped = false

    /// Fills the form from a `flaccy://server` link: its address and key, signed in with the key.
    func apply(link: ServerLink) {
        kind = .apiKey
        address = link.address
        apiKey = link.apiKey
        if let linkName = link.name {
            name = linkName
        } else {
            nameWasTyped = false
            suggestName()
        }
        onChange?()
    }

    /// Gives the name field the server's host until the person types a name of their own.
    func suggestName() {
        guard !nameWasTyped else { return }
        let suggestion = RemoteServersViewModel.suggestedName(forAddress: address)
        guard suggestion != name else { return }
        name = suggestion
        nameWasTyped = false
        onChange?()
    }

    /// The sign-in the form describes, or the sentence that says what is missing.
    func authentication() -> Result<RemoteAuthentication, FormProblem> {
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.missingAddress) }
        switch kind {
        case .password:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty, !password.isEmpty else { return .failure(.missingPassword) }
            return .success(.password(username: user, password: password))
        case .apiKey:
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return .failure(.missingAPIKey) }
            return .success(.apiKey(key))
        }
    }

    struct FormProblem: Error, Equatable {
        let message: String

        static var missingAddress: FormProblem {
            FormProblem(message: String(localized: "Type the server\u{2019}s address, then try again."))
        }
        static var missingPassword: FormProblem {
            FormProblem(message: String(localized: "Type the username and the password, then try again."))
        }
        static var missingAPIKey: FormProblem {
            FormProblem(message: String(localized: "Type the API key, then try again."))
        }
    }

    func test(using model: RemoteServersViewModel) async {
        switch authentication() {
        case .failure(let problem):
            setTest(.failed(problem.message))
        case .success(let authentication):
            setTest(.testing)
            switch await model.test(address: address, authentication: authentication) {
            case .success(let summary): setTest(.passed(summary.text))
            case .failure(let failure): setTest(.failed(failure.errorDescription ?? ""))
            }
        }
    }

    /// Saves the server and starts its first sync. Returns the saved server, or nil after the
    /// reason has been put in `testState`.
    func add(using model: RemoteServersViewModel) async -> RemoteServerRecord? {
        guard !isAdding else { return nil }
        switch authentication() {
        case .failure(let problem):
            setTest(.failed(problem.message))
            return nil
        case .success(let authentication):
            isAdding = true
            setTest(.testing)
            defer { isAdding = false }
            let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            switch await model.add(address: address, name: typedName.isEmpty ? nil : typedName, authentication: authentication) {
            case .success(let record):
                return record
            case .failure(let failure):
                setTest(.failed(failure.errorDescription ?? ""))
                return nil
            }
        }
    }

    private func resetTest() {
        guard testState != .idle else { return }
        testState = .idle
        onChange?()
    }

    private func setTest(_ state: TestState) {
        testState = state
        onChange?()
    }
}
