import Darwin
import Foundation

/// Bytes in and out of a network interface, from the kernel's routing socket
/// listing (`NET_RT_IFLIST2`, 64-bit counters), for tunnels the system does
/// not keep connection statistics for.
public enum InterfaceStatistics {
    public static func traffic(interface name: String) -> Traffic? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        var offset = 0
        return buffer.withUnsafeBytes { raw -> Traffic? in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { return nil }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(message.ifm_index) == index {
                        return Traffic(bytesIn: message.ifm_data.ifi_ibytes, bytesOut: message.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
            return nil
        }
    }

    /// The interface that carries an IPv4 or IPv6 address.
    public static func interface(withAddress address: String) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = sa.pointee.sa_family == UInt8(AF_INET) ? socklen_t(MemoryLayout<sockaddr_in>.size) : sa.pointee.sa_family == UInt8(AF_INET6) ? socklen_t(MemoryLayout<sockaddr_in6>.size) : 0
            guard length > 0, getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text == address || text.split(separator: "%").first.map(String.init) == address {
                return String(cString: entry.pointee.ifa_name)
            }
        }
        return nil
    }

    /// Whether an interface exists and is up.
    public static func isUp(interface name: String) -> Bool {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return false }
        defer { freeifaddrs(pointer) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            if String(cString: entry.pointee.ifa_name) == name, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 {
                return true
            }
            current = entry.pointee.ifa_next
        }
        return false
    }
}
