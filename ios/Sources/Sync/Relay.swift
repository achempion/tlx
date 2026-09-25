import Foundation

struct RelayAddress: Equatable {
    var host: String
    var port: Int

    static func load() -> RelayAddress? {
        guard let host = UserDefaults.standard.string(forKey: "relay_host") else {
            return nil
        }
        let port = UserDefaults.standard.integer(forKey: "relay_port")
        return RelayAddress(host: host, port: port == 0 ? 2222 : port)
    }

    func save() {
        UserDefaults.standard.set(host, forKey: "relay_host")
        UserDefaults.standard.set(port, forKey: "relay_port")
    }
}

struct Relay {
    let ssh: SSH

    init(address: RelayAddress, identity: Identity) {
        ssh = SSH(host: address.host, port: address.port, privateKey: identity.privateKey)
    }

    func check() async throws {
        _ = try await ssh.run("")
    }

    func get(after sequence: Int) async throws -> [(sequence: Int, blob: Data)] {
        let output = try await ssh.run("get \(sequence)")
        guard output.exitStatus == 0 else {
            throw RelayError.refused(String(decoding: output.stderr, as: UTF8.self))
        }

        var blobs: [(sequence: Int, blob: Data)] = []
        var offset = 0
        while offset < output.stdout.count {
            guard let newline = output.stdout[offset...].firstIndex(of: UInt8(ascii: "\n")) else {
                throw RelayError.malformedOutput
            }
            let header = String(decoding: output.stdout[offset..<newline], as: UTF8.self).split(separator: " ")
            guard header.count == 2, let sequence = Int(header[0]), let size = Int(header[1]),
                  size >= 0, size <= output.stdout.count - newline - 1 else {
                throw RelayError.malformedOutput
            }
            blobs.append((sequence, Data(output.stdout[(newline + 1)..<(newline + 1 + size)])))
            offset = newline + 1 + size
        }
        return blobs
    }

    struct PutResult {
        var accepted = false
        var rejectedPublicKeys: [String] = []
        var error: String?
    }

    func put(recipientPublicKeys: [String], blob: Data) async throws -> PutResult {
        let output = try await ssh.run("put " + recipientPublicKeys.joined(separator: " "), stdin: blob)
        switch output.exitStatus {
        case 0:
            return PutResult(accepted: true)
        case 67:
            let rejected = String(decoding: output.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            return PutResult(rejectedPublicKeys: rejected.map(String.init))
        default:
            let message = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return PutResult(error: message.isEmpty ? "exit \(output.exitStatus)" : message)
        }
    }
}

enum RelayError: LocalizedError {
    case refused(String)
    case malformedOutput

    var errorDescription: String? {
        switch self {
        case .refused(let message): return message
        case .malformedOutput: return "unexpected relay output"
        }
    }
}
