import Foundation
import Observation

/// Whether a PC is answering discovery right now
enum HostStatus: Equatable {
	case online
	/// Answering, but something is already running or streaming on it
	case busy
	case offline
}

/// The PCs the player has added (saved in UserDefaults; pairing keys are in the
/// Keychain) plus the ones answering discovery on the local network.
@Observable
final class HostStore {
	private(set) var hosts: [PCHost] {
		didSet { save() }
	}
	/// Answers from the network, by host id
	private(set) var found: [String: DiscoveredHost] = [:]

	@ObservationIgnored private let backend: StreamBackend
	@ObservationIgnored private let key = "hosts"
	@ObservationIgnored private var discoveryTask: Task<Void, Never>?
	@ObservationIgnored private var pruneTimer: Timer?
	/// Addresses swept besides the subnet: saved PCs and manual entries
	@ObservationIgnored private let extraAddresses = LockedSet()

	/// How long a PC counts as online after its last answer
	private static let onlineWindow: TimeInterval = 10

	init(backend: StreamBackend = SteamBackend.shared) {
		self.backend = backend
		var saved: [PCHost] = []
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode([PCHost].self, from: data)
		{
			saved = decoded
		}
		// The Keychain is the truth for pairing (it survives reinstalls, UserDefaults doesn't)
		for index in saved.indices {
			saved[index].isPaired = backend.hasPairing(saved[index])
		}
		hosts = saved
		extraAddresses.replace(with: saved.map(\.address))
	}

	// MARK: - Discovery

	var isDiscovering: Bool { discoveryTask != nil }

	func startDiscovery() {
		guard discoveryTask == nil else { return }
		let extra = extraAddresses
		let stream = backend.discover {
			var addresses = LocalNetwork.sweepAddresses()
			let known = Set(addresses)
			addresses.append(contentsOf: extra.values.filter { !known.contains($0) })
			return addresses
		}
		discoveryTask = Task { @MainActor [weak self] in
			for await host in stream {
				self?.record(host)
			}
		}
		pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			self?.prune()
		}
	}

	func stopDiscovery() {
		discoveryTask?.cancel()
		discoveryTask = nil
		pruneTimer?.invalidate()
		pruneTimer = nil
	}

	/// Sweeps this address too (a PC entered by IP, perhaps on another subnet)
	func probe(_ address: String) {
		extraAddresses.insert(address)
		startDiscovery()
	}

	private func record(_ host: DiscoveredHost) {
		if found[host.id] == nil {
			log.info("Found \(host.backend.rawValue, privacy: .public) PC \(host.name, privacy: .public) at \(host.address, privacy: .public) (busy: \(host.isBusy))")
		}
		found[host.id] = host
		// Follow a saved PC to its new IP if DHCP moved it
		if let index = hosts.firstIndex(where: { $0.id == host.id }), hosts[index].address != host.address {
			hosts[index].address = host.address
			extraAddresses.insert(host.address)
		}
	}

	private func prune() {
		let cutoff = Date.now.addingTimeInterval(-Self.onlineWindow)
		let stale = found.values.filter { $0.seen < cutoff }.map(\.id)
		for id in stale { found[id] = nil }
	}

	// MARK: - Hosts

	func status(of host: PCHost) -> HostStatus {
		guard let answer = found[host.id] else { return .offline }
		return answer.isBusy ? .busy : .online
	}

	/// PCs answering on the network that haven't been added yet
	var newHosts: [DiscoveredHost] {
		let saved = Set(hosts.map(\.id))
		return found.values.filter { !saved.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	/// The PC answering from this address, if any
	func answering(at address: String) -> DiscoveredHost? {
		found.values.first { $0.address == address }
	}

	func host(id: String) -> PCHost? { hosts.first { $0.id == id } }

	@discardableResult
	func add(_ found: DiscoveredHost) -> PCHost {
		if let existing = host(id: found.id) { return existing }
		let host = PCHost(found)
		hosts.append(host)
		extraAddresses.insert(host.address)
		return host
	}

	func update(_ host: PCHost) {
		guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
		hosts[index] = host
		extraAddresses.insert(host.address)
	}

	/// Removes the PC and its pairing key
	func remove(_ host: PCHost) {
		backend.forgetPairing(host)
		hosts.removeAll { $0.id == host.id }
	}

	// MARK: - Pairing

	/// Pairs with the PC, adding it if it's new
	@MainActor
	func pair(_ host: PCHost, progress: @escaping @MainActor (PairingStep) -> Void) async throws {
		try await backend.pair(host, progress: progress)
		var paired = self.host(id: host.id) ?? host
		paired.isPaired = true
		if self.host(id: host.id) == nil {
			hosts.append(paired)
		} else {
			update(paired)
		}
	}

	/// The PC forgot this phone: drop the key so the list offers pairing again
	func markUnpaired(_ host: PCHost) {
		backend.forgetPairing(host)
		guard var saved = self.host(id: host.id) else { return }
		saved.isPaired = false
		update(saved)
	}

	// MARK: - Streaming

	/// Streams from the PC through its backend
	@MainActor
	func makeSession(for host: PCHost, settings: StreamSettings) -> StreamSession {
		StreamSession(host: self.host(id: host.id) ?? host, backend: backend, settings: settings)
	}

	private func save() {
		if let data = try? JSONEncoder().encode(hosts) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}

/// A thread-safe set of strings, read by the discovery sweep off the main thread
final class LockedSet: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [String] = []

	var values: [String] { lock.withLock { storage } }

	func insert(_ value: String) {
		lock.withLock { if !storage.contains(value) { storage.append(value) } }
	}

	func replace(with values: [String]) {
		lock.withLock { storage = Array(NSOrderedSet(array: values)) as? [String] ?? values }
	}
}
