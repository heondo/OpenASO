import Foundation
import LocalAuthentication
import OSLog
import Security

enum KeychainReadFailure: Equatable, Sendable {
    case status(OSStatus)
    case unexpectedResultType

    var isTransient: Bool {
        switch self {
        case .status(let status):
            // These conditions can clear when the login Keychain becomes available or
            // user interaction is possible again; other statuses need explicit action.
            status == errSecInteractionNotAllowed || status == errSecNotAvailable
        case .unexpectedResultType:
            false
        }
    }
}

enum KeychainReadResult: Equatable, Sendable {
    case success(Data)
    case notFound
    case failure(KeychainReadFailure)
}

enum KeychainInteractionPolicy: Equatable, Sendable {
    case interactive
    case noninteractive
}

enum KeychainOperationError: Error, Equatable, Sendable {
    case status(OSStatus)
}

protocol KeychainService {
    func readData(service: String, account: String) -> KeychainReadResult
    func save(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String)
}

extension KeychainService {
    func data(service: String, account: String) -> Data? {
        guard case .success(let data) = readData(service: service, account: account) else {
            return nil
        }
        return data
    }
}

struct SystemKeychainService: KeychainService {
    typealias CopyMatching = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias Update = (CFDictionary, CFDictionary) -> OSStatus
    typealias Add = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias Delete = (CFDictionary) -> OSStatus
    typealias ReadFailureReporter = (KeychainReadFailure) -> Void

    private static let logger = Logger(subsystem: OpenASOLog.subsystem, category: "keychain")

    private let copyMatching: CopyMatching
    private let update: Update
    private let add: Add
    private let delete: Delete
    private let reportReadFailure: ReadFailureReporter
    private let interactionPolicy: KeychainInteractionPolicy

    init(
        interactionPolicy: KeychainInteractionPolicy = .interactive,
        copyMatching: @escaping CopyMatching = { query, result in
            SecItemCopyMatching(query, result)
        },
        update: @escaping Update = { query, attributes in
            SecItemUpdate(query, attributes)
        },
        add: @escaping Add = { query, result in
            SecItemAdd(query, result)
        },
        delete: @escaping Delete = { query in
            SecItemDelete(query)
        },
        reportReadFailure: @escaping ReadFailureReporter = { failure in
            SystemKeychainService.logReadFailure(failure)
        }
    ) {
        self.interactionPolicy = interactionPolicy
        self.copyMatching = copyMatching
        self.update = update
        self.add = add
        self.delete = delete
        self.reportReadFailure = reportReadFailure
    }

    func readData(service: String, account: String) -> KeychainReadResult {
        let protectedResult = readData(
            query: keychainQuery(
                service: service,
                account: account,
                usesDataProtectionKeychain: true
            )
        )
        guard protectedResult == .notFound else {
            reportFailureIfNeeded(protectedResult)
            return protectedResult
        }

        let legacyResult = readData(
            query: keychainQuery(
                service: service,
                account: account,
                usesDataProtectionKeychain: false
            )
        )
        // Delete the legacy source item only when the write verifiably reached the protected
        // store; a build without the application identifier entitlement leaves the item where
        // it is so credentials and sessions survive the next launch.
        if case .success(let data) = legacyResult,
           protectedKeychainWriteStatus(data, service: service, account: account) == errSecSuccess
        {
            _ = delete(keychainQuery(
                service: service,
                account: account,
                usesDataProtectionKeychain: false
            ) as CFDictionary)
        }
        reportFailureIfNeeded(legacyResult)
        return legacyResult
    }

    private func readData(query baseQuery: [String: Any]) -> KeychainReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        let result: KeychainReadResult

        switch status {
        case errSecSuccess:
            if let data = item as? Data {
                result = .success(data)
            } else {
                result = .failure(.unexpectedResultType)
            }
        case errSecItemNotFound:
            result = .notFound
        default:
            result = .failure(.status(status))
        }

        return result
    }

    private func reportFailureIfNeeded(_ result: KeychainReadResult) {
        if case .failure(let failure) = result {
            reportReadFailure(failure)
        }
    }

    func save(_ data: Data, service: String, account: String) throws {
        let status = protectedKeychainWriteStatus(data, service: service, account: account)
        if status == errSecSuccess {
            return
        }
        if Self.shouldUseLegacyWriteFallback(for: status) {
            try saveToLegacyKeychain(data, service: service, account: account)
            return
        }
        throw KeychainOperationError.status(status)
    }

    /// Writes to the Data Protection Keychain only, without any fallback, and returns the
    /// terminal OSStatus so callers can distinguish a protected-store write from one that
    /// would need the legacy Keychain.
    private func protectedKeychainWriteStatus(_ data: Data, service: String, account: String) -> OSStatus {
        let query = keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: true
        )
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = update(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else {
            return status
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return add(addQuery as CFDictionary, nil)
    }

    /// Builds signed without the application identifier entitlement cannot use the Data
    /// Protection Keychain at all — SecItemAdd/SecItemUpdate fail with errSecMissingEntitlement.
    /// This includes the distributed Developer ID release, whose entitlements are empty, so
    /// every credential save ("Couldn't save to Keychain") fails for end users. Fall back to
    /// the encrypted macOS login Keychain that `readData` already reads from and migrates back
    /// to the protected store when a properly entitled build runs later.
    nonisolated static func shouldUseLegacyWriteFallback(for status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
    }

    private func saveToLegacyKeychain(_ data: Data, service: String, account: String) throws {
        let query = keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: false
        )
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = update(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainOperationError.status(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainOperationError.status(addStatus)
        }
    }

    func delete(service: String, account: String) {
        _ = delete(keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: true
        ) as CFDictionary)
        _ = delete(keychainQuery(
            service: service,
            account: account,
            usesDataProtectionKeychain: false
        ) as CFDictionary)
    }

    private func keychainQuery(
        service: String,
        account: String,
        usesDataProtectionKeychain: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if interactionPolicy == .noninteractive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        return query
    }

    private static func logReadFailure(_ failure: KeychainReadFailure) {
        switch failure {
        case .status(let status):
            let description = SecCopyErrorMessageString(status, nil).map { String($0) } ?? "unknown error"
            if failure.isTransient {
                logger.warning(
                    "Keychain read temporarily unavailable status=\(status, privacy: .public) description=\(description, privacy: .public)"
                )
            } else {
                logger.error(
                    "Keychain read failed status=\(status, privacy: .public) description=\(description, privacy: .public)"
                )
            }
        case .unexpectedResultType:
            logger.error("Keychain read returned an unexpected result type")
        }
    }
}

final class InMemoryKeychainService: KeychainService {
    private var storage: [Key: Data] = [:]

    func readData(service: String, account: String) -> KeychainReadResult {
        guard let data = storage[Key(service: service, account: account)] else {
            return .notFound
        }
        return .success(data)
    }

    func save(_ data: Data, service: String, account: String) throws {
        storage[Key(service: service, account: account)] = data
    }

    func delete(service: String, account: String) {
        storage.removeValue(forKey: Key(service: service, account: account))
    }

    private struct Key: Hashable {
        var service: String
        var account: String
    }
}

struct KeychainItemPresenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func contains(service: String, account: String) -> Bool {
        defaults.bool(forKey: defaultsKey(service: service, account: account))
    }

    func markPresent(service: String, account: String) {
        defaults.set(true, forKey: defaultsKey(service: service, account: account))
    }

    func markAbsent(service: String, account: String) {
        defaults.removeObject(forKey: defaultsKey(service: service, account: account))
    }

    private func defaultsKey(service: String, account: String) -> String {
        "keychain.containsItem.\(service).\(account)"
    }
}
