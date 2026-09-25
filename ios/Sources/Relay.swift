import Foundation

struct RelayAddress {
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
