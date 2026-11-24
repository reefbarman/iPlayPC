import Darwin
import Foundation

/// The phone's own Wi-Fi/Ethernet subnet, for sweeping it with unicast
/// discovery (iOS blocks broadcast without Apple's multicast entitlement).
enum LocalNetwork {
	/// Every address on the subnets the phone is on, skipping its own, the
	/// network and broadcast addresses. Subnets bigger than a /22 are cut down
	/// to the phone's own /24.
	static func sweepAddresses() -> [String] {
		var ifs: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&ifs) == 0, let first = ifs else { return [] }
		defer { freeifaddrs(ifs) }

		var result: [String] = []
		var seen = Set<UInt32>()
		for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let entry = pointer.pointee
			guard let addr = entry.ifa_addr, let netmask = entry.ifa_netmask,
				addr.pointee.sa_family == UInt8(AF_INET)
			else { continue }
			let flags = Int32(entry.ifa_flags)
			guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
			// Wi-Fi, Ethernet and personal hotspot only; skip cellular and VPN tunnels
			let name = String(cString: entry.ifa_name)
			guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

			let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
			var mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
			if mask < 0xFFFF_FC00 { mask = 0xFFFF_FF00 }
			let network = ip & mask
			let broadcast = network | ~mask
			guard broadcast > network + 1 else { continue }
			for candidate in (network + 1) ..< broadcast where candidate != ip && seen.insert(candidate).inserted {
				result.append(format(candidate))
			}
		}
		return result
	}

	static func format(_ ip: UInt32) -> String {
		"\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
	}

	/// A dotted IPv4 address, or nil
	static func normalizedIPv4(_ text: String) -> String? {
		var addr = in_addr()
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard inet_pton(AF_INET, trimmed, &addr) == 1 else { return nil }
		return format(UInt32(bigEndian: addr.s_addr))
	}
}
