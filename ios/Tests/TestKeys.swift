import CryptoKit
import Foundation

func testPublicKey(_ seed: UInt8) -> String {
    let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    let wire = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + key.publicKey.rawRepresentation
    return wire.base64EncodedString()
}
