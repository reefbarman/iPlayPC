import SwiftUI

/// Add a PC by picking one found on the network or entering its IP address.
struct AddHostView: View {
	/// Called with the PC to pair
	let onPick: (PCHost) -> Void
	@Environment(HostStore.self) private var store
	@Environment(\.dismiss) private var dismiss
	@State private var address = ""
	@State private var looking: String?
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					if store.newHosts.isEmpty {
						HStack(spacing: 10) {
							ProgressView()
							Text("Looking for PCs…").foregroundStyle(.secondary)
						}
					}
					ForEach(store.newHosts) { found in
						Button {
							onPick(PCHost(found))
						} label: {
							VStack(alignment: .leading, spacing: 2) {
								Text(found.name.isEmpty ? "PC" : found.name).foregroundStyle(.primary)
								Text(found.address).font(.caption).foregroundStyle(.secondary)
							}
						}
					}
				} header: {
					Text("On your network")
				} footer: {
					Text("The PC needs Steam running with Remote Play turned on, on the same network.")
				}

				Section {
					TextField("IP address, e.g. 192.168.1.50", text: $address)
						.keyboardType(.numbersAndPunctuation)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.onSubmit(lookUp)
					if looking != nil {
						HStack(spacing: 10) {
							ProgressView()
							Text("Waiting for the PC to answer…").foregroundStyle(.secondary)
						}
					} else {
						Button("Connect", action: lookUp)
							.disabled(LocalNetwork.normalizedIPv4(address) == nil)
					}
					if let error {
						Text(error).foregroundStyle(.red)
					}
				} header: {
					Text("Enter IP address")
				}
			}
			.navigationTitle("Add PC")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			}
		}
		.onChange(of: store.found) { _, _ in
			guard let looking, let found = store.answering(at: looking) else { return }
			self.looking = nil
			if let saved = store.host(id: found.id) {
				onPick(saved)
			} else {
				onPick(PCHost(found))
			}
		}
	}

	private func lookUp() {
		guard let ip = LocalNetwork.normalizedIPv4(address) else { return }
		error = nil
		looking = ip
		store.probe(ip)
		DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
			if looking == ip {
				looking = nil
				error = "No PC answered at \(ip). Check that Steam is running and Remote Play is on."
			}
		}
	}
}
