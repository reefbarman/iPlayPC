import Foundation
import IHSKit
import os
import UIKit

private let ihsLog = AppLog(subsystem: logSubsystem, category: "steam")

/// Steam Remote Play through IHSKit: discovery, PIN pairing and streams.
///
/// One IHSKit client serves the whole app. Its secret key is switched to the
/// PC's own key before streaming from that PC, so concurrent operations on
/// different PCs aren't supported (the UI never does that).
final class SteamBackend: StreamBackend {
	static let shared = SteamBackend()

	let kind = BackendKind.steam

	/// Keychain service for per-PC pairing keys
	private static let keyService = "dev.reefbarman.iplaypc.hosts"
	/// Keychain service for this phone's own identity
	private static let appService = "dev.reefbarman.iplaypc"
	/// Steam Remote Play's discovery port
	static let discoveryPort: UInt16 = 27036

	private let lock = NSLock()
	private var client: OpaquePointer?
	private var listeners: [UUID: AsyncStream<DiscoveredHost>.Continuation] = [:]
	private var pendingPair: CheckedContinuation<Data, Error>?
	private var pendingStream: CheckedContinuation<IHKStreamGrant, Error>?
	/// The latest discovery answer from each PC, by host id
	private var seen: [UInt64: IHKHost] = [:]

	private let deviceID: UInt64
	private let deviceName: String

	private init() {
		deviceID = Self.loadDeviceID()
		// Without a special entitlement iOS reports the model ("iPhone", "iPad"),
		// which is what Steam lists under paired devices
		deviceName = UIDevice.current.name
		ihk_set_log_callback({ _, level, tag, message in
			let text = "[\(tag.map { String(cString: $0) } ?? "")] \(message.map { String(cString: $0) } ?? "")"
			consoleLog(text)
			switch level {
			case IHK_LOG_FATAL, IHK_LOG_ERROR: ihsLog.error("\(text, privacy: .public)")
			case IHK_LOG_WARN: ihsLog.warning("\(text, privacy: .public)")
			case IHK_LOG_INFO: ihsLog.info("\(text, privacy: .public)")
			default: ihsLog.debug("\(text, privacy: .public)")
			}
		}, nil, mirrorsLogToConsole ? IHK_LOG_DEBUG : IHK_LOG_INFO)
	}

	// MARK: - Identity

	/// A random id for this phone, kept in the Keychain so the PC still knows
	/// it after a reinstall
	private static func loadDeviceID() -> UInt64 {
		if let data = Keychain.data(service: appService, account: "deviceID"), data.count == 8 {
			return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
		}
		var id = UInt64.random(in: 1 ... UInt64.max)
		Keychain.set(Data(bytes: &id, count: 8), service: appService, account: "deviceID")
		return id
	}

	private func pairingKey(for hostID: String) -> Data? {
		Keychain.data(service: Self.keyService, account: "steam.\(hostID)").flatMap { $0.count == 32 ? $0 : nil }
	}

	func hasPairing(_ host: PCHost) -> Bool { pairingKey(for: host.id) != nil }

	func forgetPairing(_ host: PCHost) {
		Keychain.remove(service: Self.keyService, account: "steam.\(host.id)")
	}

	// MARK: - Client

	/// The shared IHSKit client, created on first use
	private func ensureClient() -> OpaquePointer? {
		lock.lock()
		defer { lock.unlock() }
		if let client { return client }
		var callbacks = IHKClientCallbacks()
		callbacks.user = Unmanaged.passUnretained(self).toOpaque()
		callbacks.on_host = { user, host in
			guard let user, let host else { return }
			Unmanaged<SteamBackend>.fromOpaque(user).takeUnretainedValue().found(host.pointee)
		}
		callbacks.on_auth_progress = { _, _ in
			ihsLog.info("PC is showing the PIN dialog")
		}
		callbacks.on_auth_success = { user, _, key, _ in
			guard let user, let key else { return }
			let data = Data(bytes: key, count: 32)
			Unmanaged<SteamBackend>.fromOpaque(user).takeUnretainedValue().finishPairing(.success(data))
		}
		callbacks.on_auth_failed = { user, _, result in
			guard let user else { return }
			Unmanaged<SteamBackend>.fromOpaque(user).takeUnretainedValue().finishPairing(.failure(SteamBackend.pairingError(result)))
		}
		callbacks.on_stream_progress = { _, _ in
			ihsLog.info("PC is starting the stream")
		}
		callbacks.on_stream_success = { user, _, grant in
			guard let user, let grant else { return }
			Unmanaged<SteamBackend>.fromOpaque(user).takeUnretainedValue().finishStreamRequest(.success(grant.pointee))
		}
		callbacks.on_stream_failed = { user, _, result in
			guard let user else { return }
			ihsLog.error("Stream request failed: \(result.rawValue)")
			consoleLog("Stream request failed, result \(result.rawValue)")
			Unmanaged<SteamBackend>.fromOpaque(user).takeUnretainedValue().finishStreamRequest(.failure(SteamBackend.streamError(result)))
		}
		client = deviceName.withCString { name in
			ihk_client_create(deviceID, name, nil, &callbacks)
		}
		if client == nil { ihsLog.error("Couldn't create the Steam client") }
		return client
	}

	// MARK: - Discovery

	func discover(sweep addresses: @escaping () -> [String]) -> AsyncStream<DiscoveredHost> {
		AsyncStream { continuation in
			let id = UUID()
			lock.withLock { listeners[id] = continuation }
			let task = Task.detached(priority: .utility) { [weak self] in
				var firstSweep = true
				while !Task.isCancelled {
					guard let self, let client = self.ensureClient() else { return }
					let targets = addresses()
					for (index, address) in targets.enumerated() {
						if Task.isCancelled { return }
						var sent = ihk_client_discover(client, address)
						// The client opens its socket on its own thread; wait for it on the first sweep
						var waits = 0
						while !sent, firstSweep, waits < 20 {
							try? await Task.sleep(for: .milliseconds(50))
							sent = ihk_client_discover(client, address)
							waits += 1
						}
						firstSweep = false
						if index % 64 == 63 {
							// Don't overrun the socket's send buffer
							try? await Task.sleep(for: .milliseconds(2))
						}
					}
					try? await Task.sleep(for: .seconds(3))
				}
			}
			continuation.onTermination = { [weak self] _ in
				task.cancel()
				self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
			}
		}
	}

	private func found(_ host: IHKHost) {
		var host = host
		let found = DiscoveredHost(
			backend: .steam,
			id: String(host.host_id),
			name: cString(&host.name),
			address: cString(&host.address),
			isBusy: host.games_running
		)
		guard host.host_id != 0, !found.address.isEmpty else { return }
		let targets = lock.withLock { () -> [AsyncStream<DiscoveredHost>.Continuation] in
			seen[host.host_id] = host
			return Array(listeners.values)
		}
		for continuation in targets { continuation.yield(found) }
	}

	// MARK: - Pairing

	func pair(_ host: PCHost, progress: @escaping @MainActor (PairingStep) -> Void) async throws {
		guard let client = ensureClient() else { throw BackendError("Couldn't start networking. Try again.") }
		let pin = String(format: "%04d", Int.random(in: 0 ..< 10000))
		var target = ihkHost(for: host)
		let key: Data = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let busy = lock.withLock { () -> Bool in
					if pendingPair != nil { return true }
					pendingPair = continuation
					return false
				}
				if busy {
					continuation.resume(throwing: BackendError("Already pairing. Try again in a moment."))
					return
				}
				if Task.isCancelled {
					finishPairing(.failure(CancellationError()))
					return
				}
				guard ihk_client_authorize(client, &target, pin) else {
					finishPairing(.failure(BackendError("Couldn't start pairing. Try again.")))
					return
				}
				Task { @MainActor in progress(.showPIN(pin)) }
			}
		} onCancel: {
			ihk_client_cancel_authorization(client)
			self.finishPairing(.failure(CancellationError()))
		}
		Keychain.set(key, service: Self.keyService, account: "steam.\(host.id)")
		await progress(.paired)
	}

	/// Resumes the pairing waiter once, whichever of success, failure or cancel comes first
	private func finishPairing(_ result: Result<Data, Error>) {
		let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
			defer { pendingPair = nil }
			return pendingPair
		}
		continuation?.resume(with: result)
	}

	private static func pairingError(_ result: IHKAuthResult) -> Error {
		switch result {
		case IHK_AUTH_CANCELED: CancellationError()
		case IHK_AUTH_DENIED: BackendError("The PC declined pairing.")
		case IHK_AUTH_NOT_LOGGED_IN: BackendError("Steam on the PC isn't signed in.")
		case IHK_AUTH_OFFLINE: BackendError("Steam on the PC is offline.")
		case IHK_AUTH_BUSY, IHK_AUTH_IN_PROGRESS: BackendError("The PC is busy pairing. Try again in a moment.")
		case IHK_AUTH_TIMED_OUT: BackendError("The PIN wasn't entered in time.")
		default: BackendError("Pairing didn't work. Check the PIN and try again.")
		}
	}

	// MARK: - Streaming

	func connect(_ host: PCHost, config: StreamConfig) async throws -> StreamConnection {
		guard let client = ensureClient() else { throw BackendError("Couldn't start networking. Try again.") }
		guard let key = pairingKey(for: host.id) else {
			throw BackendError("Pair with this PC first.", needsPairing: true)
		}
		key.withUnsafeBytes { ihk_client_set_secret_key(client, $0.bindMemory(to: UInt8.self).baseAddress) }
		var target = ihkHost(for: host)
		var request = IHKStreamRequest()
		request.max_width = Int32(clamping: config.width)
		request.max_height = Int32(clamping: config.height)
		request.audio_channels = 2
		request.streaming_interface = IHK_INTERFACE_BIG_PICTURE

		let grant: IHKStreamGrant = try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let busy = lock.withLock { () -> Bool in
					if pendingStream != nil { return true }
					pendingStream = continuation
					return false
				}
				if busy {
					continuation.resume(throwing: BackendError("Already connecting. Try again in a moment."))
					return
				}
				if Task.isCancelled {
					finishStreamRequest(.failure(CancellationError()))
					return
				}
				guard ihk_client_request_stream(client, &target, &request) else {
					finishStreamRequest(.failure(BackendError("Couldn't reach the PC. Try again.")))
					return
				}
			}
		} onCancel: {
			self.finishStreamRequest(.failure(CancellationError()))
		}
		ihsLog.notice("Stream granted at \(cString(&target.address), privacy: .public)")
		// EOSType: macOS is -102 to -1, Windows 0 and up, Linux below -102
		let macHost = (-102 ... -1).contains(target.os_type)
		return SteamConnection(deviceID: deviceID, deviceName: deviceName, secretKey: key, grant: grant, config: config,
			macHost: macHost)
	}

	/// Resumes the stream request waiter once
	private func finishStreamRequest(_ result: Result<IHKStreamGrant, Error>) {
		let continuation = lock.withLock { () -> CheckedContinuation<IHKStreamGrant, Error>? in
			defer { pendingStream = nil }
			return pendingStream
		}
		continuation?.resume(with: result)
	}

	private static func streamError(_ result: IHKStreamResult) -> Error {
		switch result {
		case IHK_STREAM_CANCELED: CancellationError()
		case IHK_STREAM_UNAUTHORIZED, IHK_STREAM_PIN_REQUIRED:
			BackendError("This PC doesn't know this phone any more. Pair again.", needsPairing: true)
		case IHK_STREAM_SCREEN_LOCKED: BackendError("Unlock the PC, then try again.")
		case IHK_STREAM_BUSY, IHK_STREAM_IN_PROGRESS: BackendError("The PC is already streaming. Try again in a moment.")
		case IHK_STREAM_DRIVERS_NOT_INSTALLED: BackendError("Steam on the PC needs its streaming drivers installed.")
		case IHK_STREAM_DISABLED: BackendError("Remote Play is turned off in Steam on the PC.")
		case IHK_STREAM_BROADCASTING_ACTIVE: BackendError("Steam is broadcasting on the PC. Stop it and try again.")
		case IHK_STREAM_VR_ACTIVE: BackendError("SteamVR is running on the PC. Close it and try again.")
		case IHK_STREAM_TRANSPORT_UNAVAILABLE: BackendError("Couldn't reach the PC. Try again.")
		case IHK_STREAM_TIMEOUT: BackendError("The PC didn't answer. Check it's awake and Steam is running.")
		default: BackendError("The PC couldn't start the stream. Try again.")
		}
	}

	// MARK: - Helpers

	private func ihkHost(for host: PCHost) -> IHKHost {
		// Prefer what the PC itself last told us (instance id, OS, current address)
		if let id = UInt64(host.id), let found = lock.withLock({ seen[id] }) {
			return found
		}
		var target = IHKHost()
		target.host_id = UInt64(host.id) ?? 0
		setCString(&target.address, host.address)
		setCString(&target.name, host.name)
		target.port = Self.discoveryPort
		target.universe = 1
		return target
	}
}

/// Reads a fixed-size C char array (imported as a tuple) as a string
func cString<T>(_ value: inout T) -> String {
	withUnsafeBytes(of: &value) { raw in
		let bytes = raw.bindMemory(to: UInt8.self)
		let end = bytes.firstIndex(of: 0) ?? bytes.count
		return String(decoding: bytes[..<end], as: UTF8.self)
	}
}

/// Writes a string into a fixed-size C char array, truncated and NUL-terminated
func setCString<T>(_ value: inout T, _ string: String) {
	withUnsafeMutableBytes(of: &value) { raw in
		raw.initializeMemory(as: UInt8.self, repeating: 0)
		let utf8 = Array(string.utf8.prefix(raw.count - 1))
		raw.copyBytes(from: utf8)
	}
}
