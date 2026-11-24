import Foundation

// The app only talks to a PC through these types. Everything protocol-specific
// lives under App/Backend/<Backend>/ (today Steam Remote Play; Moonlight later),
// so the player, renderer and screens never change when a backend is added.

enum BackendKind: String, Codable, Hashable {
	case steam
}

/// A PC that answered discovery.
struct DiscoveredHost: Hashable, Identifiable {
	var backend: BackendKind
	/// Stable per PC (Steam: the host's client id), so it survives IP changes
	var id: String
	var name: String
	var address: String
	/// Something is already running or streaming on it
	var isBusy: Bool
	var seen: Date = .now
}

/// Per-PC settings. Video overrides arrive with the player (see build plan step 3).
struct HostSettings: Codable, Hashable {
	init() {}

	/// Missing keys keep their defaults, so adding a setting doesn't reset the others
	init(from decoder: Decoder) throws {}
}

/// A PC the player has added. Saved by HostStore; secrets live in the Keychain.
struct PCHost: Codable, Identifiable, Hashable {
	var id: String
	var backend: BackendKind
	var name: String
	var address: String
	/// For Wake-on-LAN, entered by the player
	var macAddress: String?
	var isPaired: Bool
	var settings = HostSettings()

	init(id: String, backend: BackendKind, name: String, address: String, macAddress: String? = nil, isPaired: Bool = false) {
		self.id = id
		self.backend = backend
		self.name = name
		self.address = address
		self.macAddress = macAddress
		self.isPaired = isPaired
	}

	init(_ found: DiscoveredHost) {
		self.init(id: found.id, backend: found.backend, name: found.name, address: found.address)
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		backend = (try? c.decode(BackendKind.self, forKey: .backend)) ?? .steam
		name = try c.decodeIfPresent(String.self, forKey: .name) ?? "PC"
		address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
		macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
		isPaired = try c.decodeIfPresent(Bool.self, forKey: .isPaired) ?? false
		settings = (try? c.decodeIfPresent(HostSettings.self, forKey: .settings)) ?? HostSettings()
	}
}

enum PairingStep: Equatable {
	/// Show this PIN; the player types it into Steam on the PC
	case showPIN(String)
	case paired
}

/// A failure with short, player-facing text
struct BackendError: LocalizedError, Equatable {
	var message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

protocol StreamBackend: AnyObject {
	var kind: BackendKind { get }

	/// Sends discovery to each address every few seconds until the stream is cancelled.
	/// Hosts arrive as they answer, with repeats.
	func discover(sweep addresses: @escaping () -> [String]) -> AsyncStream<DiscoveredHost>

	/// Pairs with the PC. Throws BackendError with a player-facing reason, or CancellationError.
	func pair(_ host: PCHost, progress: @escaping @MainActor (PairingStep) -> Void) async throws

	/// Whether this phone still holds the PC's pairing key
	func hasPairing(_ host: PCHost) -> Bool

	/// Forgets the PC's pairing key
	func forgetPairing(_ host: PCHost)
}
