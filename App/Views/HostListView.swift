import SwiftUI

/// Home: the PCs you've added and the ones answering on your network.
struct HostListView: View {
	@Environment(HostStore.self) private var store
	@State private var pairing: PCHost?
	@State private var showingAdd = false

	var body: some View {
		NavigationStack {
			List {
				if store.hosts.isEmpty && store.newHosts.isEmpty {
					ContentUnavailableView {
						Label("Looking for PCs", systemImage: "desktopcomputer")
					} description: {
						Text("Have Steam running on your PC, on the same network, with Remote Play turned on in Steam's settings.")
					} actions: {
						Button("Enter IP address") { showingAdd = true }
					}
				}
				if !store.hosts.isEmpty {
					Section {
						ForEach(store.hosts) { host in
							HostRow(name: host.name, address: host.address, status: store.status(of: host), paired: host.isPaired) {
								if !host.isPaired { pairing = host }
							}
							.swipeActions {
								Button("Remove", role: .destructive) { store.remove(host) }
							}
						}
					}
				}
				if !store.newHosts.isEmpty {
					Section("On your network") {
						ForEach(store.newHosts) { found in
							HostRow(name: found.name, address: found.address, status: found.isBusy ? .busy : .online, paired: false) {
								pairing = PCHost(found)
							}
						}
					}
				}
			}
			.navigationTitle("iPlayPC")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { showingAdd = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showingAdd) {
				AddHostView { host in
					showingAdd = false
					pairing = host
				}
			}
			.fullScreenCover(item: $pairing) { host in
				PairView(host: host)
			}
		}
		.onAppear { store.startDiscovery() }
	}
}

private struct HostRow: View {
	let name: String
	let address: String
	let status: HostStatus
	let paired: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 14) {
				Image(systemName: "desktopcomputer")
					.font(.title)
					.frame(width: 44)
				VStack(alignment: .leading, spacing: 3) {
					Text(name.isEmpty ? "PC" : name).font(.headline).foregroundStyle(.primary)
					Text(address).font(.caption).foregroundStyle(.secondary)
					statusLabel
				}
				Spacer()
				if !paired {
					Text("Pair").font(.callout).foregroundStyle(.tint)
				}
			}
			.padding(.vertical, 6)
		}
	}

	@ViewBuilder private var statusLabel: some View {
		switch status {
		case .online:
			Label(paired ? "Ready" : "Not paired", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
		case .busy:
			Label("In use", systemImage: "circle.fill").font(.caption).foregroundStyle(.orange)
		case .offline:
			Label("Not found", systemImage: "circle").font(.caption).foregroundStyle(.secondary)
		}
	}
}
