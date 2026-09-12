#if canImport(Network)
import Network
#endif
import Darwin

enum LatchNetwork {
    struct Address: Hashable, Sendable {
        let interface: String
        let ip: String

        var isLoopback: Bool {
            ip.hasPrefix("127.") || ip == "::1"
        }

        /// Tailscale / CGNAT carrier-grade range 100.64.0.0/10.
        var isTailscale: Bool {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            return parts[0] == 100 && (64...127).contains(parts[1])
        }

        var label: String {
            if isTailscale { return "Tailscale" }
            if interface.hasPrefix("en") { return "Wi‑Fi / Ethernet" }
            return interface
        }
    }

    static func ipv4Addresses() -> [Address] {
        var addresses: [Address] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t
            if sa.pointee.sa_family == UInt8(AF_INET) {
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
            } else {
                length = socklen_t(sa.pointee.sa_len)
            }
            let result = getnameinfo(
                sa,
                length,
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            let name = String(cString: current.pointee.ifa_name)
            addresses.append(Address(interface: name, ip: ip))
        }

        return addresses.sorted { lhs, rhs in
            if lhs.isTailscale != rhs.isTailscale { return lhs.isTailscale && !rhs.isTailscale }
            return lhs.ip < rhs.ip
        }
    }

    /// Prefer Tailscale, then the first non-loopback IPv4.
    static func preferredRemoteHost() -> String? {
        let all = ipv4Addresses()
        return all.first(where: \.isTailscale)?.ip ?? all.first?.ip
    }

#if canImport(Network)
    static func endpoint(host: String, port: UInt16 = UnlockService.tcpPort) -> NWEndpoint? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return NWEndpoint.hostPort(host: NWEndpoint.Host(trimmed), port: nwPort)
    }
#endif
}
