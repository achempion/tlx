import Core
import Foundation
import Security

private let keychainItem: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "tlx",
    kSecAttrAccount as String: "key",
    kSecUseDataProtectionKeychain as String: true,
]

struct Identity: Equatable {
    let privateKeyPEM: String
    let privateKey: Data
    let publicKey: String

    init(privateKeyPEM: String) throws {
        var error: NSError?
        guard let keyPair = CoreParseKey(privateKeyPEM, &error), let privateKey = keyPair.privateKey else {
            throw error ?? NSError(domain: "Core", code: 0)
        }
        self.privateKeyPEM = privateKeyPEM
        self.privateKey = privateKey
        self.publicKey = keyPair.publicKey
    }

    static func load() -> Identity? {
        var query = keychainItem
        query[kSecReturnData as String] = true
        var found: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &found)
        guard let data = found as? Data, let privateKeyPEM = String(data: data, encoding: .utf8) else {
            return nil
        }
        return try? Identity(privateKeyPEM: privateKeyPEM)
    }

    func save() throws {
        let value = Data(privateKeyPEM.utf8)
        let status = SecItemUpdate(keychainItem as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var item = keychainItem
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }
}
