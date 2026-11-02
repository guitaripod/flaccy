import Foundation
import Network

/// Watches for the local network Wi-Fi Transfer needs and reports this device's IPv4 address on it, or nil while the
/// device has none. Wi-Fi comes first; wired Ethernet (a USB adapter, or the Mac under the simulator) also counts. The
/// interface comes from the system's path, never an assumed name such as `en0`, which is not always Wi-Fi (TN3179).
/// Updates arrive on the main actor.
@MainActor
final class WiFiAddressMonitor {

    private let monitor = NWPathMonitor()
    private let onChange: @MainActor (String?) -> Void
    private var current: String??

    init(onChange: @escaping @MainActor (String?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let address = Self.localAddress(on: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publish(address) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "cc.midgarcorp.flaccy.wifi-address"))
    }

    func stop() {
        monitor.cancel()
    }

    private func publish(_ address: String?) {
        guard current != .some(address) else { return }
        current = .some(address)
        onChange(address)
    }

    nonisolated static func localAddress(on path: NWPath) -> String? {
        guard path.status == .satisfied else { return nil }
        let local = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
        let ordered = local.filter { $0.type == .wifi } + local.filter { $0.type == .wiredEthernet }
        return ordered.lazy.compactMap { ipv4Address(ofInterfaceNamed: $0.name) }.first
    }

    /// The first IPv4 address of the interface called `name`, as dotted decimal.
    nonisolated static func ipv4Address(ofInterfaceNamed name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == name
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            return String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        return nil
    }
}
