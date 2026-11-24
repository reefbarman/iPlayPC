import Foundation
import Security

/// Small generic-password Keychain wrapper. Items stay on this device
/// (no iCloud sync) and are readable after the first unlock, so a stream can
/// start from the background.
enum Keychain {
	static func data(service: String, account: String) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var result: AnyObject?
		guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
		return result as? Data
	}

	@discardableResult
	static func set(_ data: Data, service: String, account: String) -> Bool {
		let match: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		let attributes: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		]
		let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
		if status == errSecSuccess { return true }
		guard status == errSecItemNotFound else {
			log.error("Keychain update failed: \(status)")
			return false
		}
		let add = match.merging(attributes) { $1 }
		let added = SecItemAdd(add as CFDictionary, nil)
		if added != errSecSuccess { log.error("Keychain add failed: \(added)") }
		return added == errSecSuccess
	}

	static func remove(service: String, account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
		]
		SecItemDelete(query as CFDictionary)
	}
}
