import Foundation
import LocalAuthentication
import Security

/// Sign-in details kept in the Keychain behind Face ID (or Touch ID), one set
/// per employer server. Reading them always asks for the face first, and a
/// change to the enrolled faces throws them away.
enum FaceIDLogin {
    struct Saved {
        let email: String
        let password: String
    }

    private static let service = "com.zodyking.yardlink.signin"

    /// "Face ID", "Touch ID" or "Optic ID", or nil where the phone has none
    /// set up.
    static var biometryName: String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return nil }
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case LABiometryType.none: return nil
        default: return "Face ID"
        }
    }

    static var symbol: String { biometryName == "Touch ID" ? "touchid" : "faceid" }

    /// Whether details are saved for this server. Does not ask for the face.
    static func isSaved(for server: URL?) -> Bool {
        guard let account = account(server) else { return false }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func save(_ saved: Saved, for server: URL?) -> Bool {
        guard let account = account(server),
              let data = try? JSONEncoder().encode([saved.email, saved.password]),
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
        else { return false }
        forget(for: server)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Ask for the face and answer the saved details, or nil if the person
    /// cancelled or nothing is saved.
    static func read(for server: URL?) async -> Saved? {
        guard let account = account(server) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Saved? in
            let context = LAContext()
            context.localizedReason = "Sign in to Yard Link"
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let parts = try? JSONDecoder().decode([String].self, from: data),
                  parts.count == 2
            else { return nil }
            return Saved(email: parts[0], password: parts[1])
        }.value
    }

    static func forget(for server: URL?) {
        guard let account = account(server) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func account(_ server: URL?) -> String? {
        guard let server else { return nil }
        return server.absoluteString.lowercased()
    }
}
