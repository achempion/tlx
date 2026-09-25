import Core
import Foundation
import Security

private let keychainItem: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "tlx",
    kSecAttrAccount as String: "key",
]

struct Identity {
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
        SecItemDelete(keychainItem as CFDictionary)
        var item = keychainItem
        item[kSecValueData as String] = Data(privateKeyPEM.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
