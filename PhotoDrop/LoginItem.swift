import ServiceManagement

enum LoginItem {
    enum Status: Sendable {
        case enabled
        case disabled
        case needsApproval
        case unavailable
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    static func register() -> String? {
        errorText { try SMAppService.mainApp.register() }
    }

    static func unregister() -> String? {
        errorText { try SMAppService.mainApp.unregister() }
    }

    private static func errorText(_ change: () throws -> Void) -> String? {
        do {
            try change()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
