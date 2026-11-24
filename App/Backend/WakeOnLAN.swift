import Darwin
import Foundation

/// Wakes a sleeping PC with a standard magic packet (6 × FF, then the MAC 16 times).
/// Not tied to a backend: Steam and Moonlight hosts wake the same way.
///
/// iOS only lets apps with Apple's multicast entitlement send broadcasts, so the packet
/// goes straight to the PC's last IP address. That reaches it while the phone or router
/// still remembers the PC's network card, or the card answers for itself while asleep
/// (most do). The subnet broadcast is tried as well in case iOS allows it.
enum WakeOnLAN {
	/// Sends the packet to UDP 9 and 7 at `address` and its subnet broadcast.
	/// Returns false if the MAC address is unusable or nothing could be sent.
	@discardableResult
	static func wake(mac: String, address: String) -> Bool {
		guard let packet = magicPacket(mac) else { return false }
		var targets = [address]
		if let broadcast = LocalNetwork.broadcastAddress(for: address) { targets.append(broadcast) }

		let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard fd >= 0 else { return false }
		defer { close(fd) }
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

		var sent = false
		for target in targets {
			for port: UInt16 in [9, 7] {
				var addr = sockaddr_in()
				addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
				addr.sin_family = sa_family_t(AF_INET)
				addr.sin_port = port.bigEndian
				guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { continue }
				let result = packet.withUnsafeBytes { bytes in
					withUnsafePointer(to: &addr) {
						$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
							sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
						}
					}
				}
				if result == packet.count { sent = true }
			}
		}
		return sent
	}

	static func magicPacket(_ mac: String) -> Data? {
		guard let normalized = LocalNetwork.normalizedMAC(mac) else { return nil }
		let bytes = normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }
		guard bytes.count == 6 else { return nil }
		var packet = Data(repeating: 0xFF, count: 6)
		for _ in 0 ..< 16 { packet.append(contentsOf: bytes) }
		return packet
	}
}
