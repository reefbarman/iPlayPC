import SwiftUI

/// Version, source link and licences. iPlayPC is AGPL-3.0, so every build links to
/// the exact source it was built from (the release tag, or main for local builds).
enum AppInfo {
	private static let info = Bundle.main.infoDictionary

	static var version: String {
		let short = info?["CFBundleShortVersionString"] as? String ?? "?"
		let build = info?["CFBundleVersion"] as? String ?? "?"
		return "\(short) (\(build))"
	}

	static let repository = URL(string: "https://github.com/reefbarman/iPlayPC")!

	static var sourceURL: URL {
		let ref = (info?["IPlayPCSourceRef"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "main"
		return repository.appending(path: "tree/\(ref)")
	}
}

/// Something bundled into iPlayPC, with its licence text in Resources/Licenses
struct OpenSourceComponent: Identifiable {
	let name: String
	let license: String
	let notice: String
	let url: URL
	/// File name (without .txt) in App/Resources/Licenses, written by scripts/update-licenses.sh
	let file: String
	var id: String { name }

	static let all: [OpenSourceComponent] = [
		.init(
			name: "iPlayPC", license: "AGPL-3.0-only",
			notice: "Copyright reefbarman and iPlayPC contributors.",
			url: AppInfo.repository, file: "iPlayPC"),
		.init(
			name: "ihslib", license: "LGPL-3.0-or-later",
			notice: "Copyright Mariotaku and the ihslib contributors. iPlayPC streams with ihslib's Steam Remote Play library.",
			url: URL(string: "https://github.com/scaronni/ihslib")!, file: "ihslib"),
		.init(
			name: "Steam-Link-PS5", license: "GPL-3.0-or-later",
			notice: "Copyright jmelovich and the Steam-Link-PS5 contributors. iPlayPC applies its ihslib patches.",
			url: URL(string: "https://github.com/jmelovich/Steam-Link-PS5")!, file: "Steam-Link-PS5"),
		.init(
			name: "Mbed TLS", license: "Apache-2.0",
			notice: "Copyright The Mbed TLS Contributors. iPlayPC uses Mbed TLS under the Apache License 2.0.",
			url: URL(string: "https://github.com/Mbed-TLS/mbedtls")!, file: "MbedTLS"),
		.init(
			name: "Opus", license: "BSD-3-Clause",
			notice: "Copyright Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla and Amazon.",
			url: URL(string: "https://opus-codec.org")!, file: "Opus"),
		.init(
			name: "protobuf-c", license: "BSD-2-Clause",
			notice: "Copyright Dave Benson and the protobuf-c authors.",
			url: URL(string: "https://github.com/protobuf-c/protobuf-c")!, file: "protobuf-c"),
	]
}

/// Settings › About
struct AboutSection: View {
	var body: some View {
		Section {
			LabeledContent("Version", value: AppInfo.version)
			Link(destination: AppInfo.sourceURL) {
				Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
			}
			NavigationLink { LicensesView() } label: {
				Label("Licences", systemImage: "doc.text")
			}
		} header: {
			Text("About")
		} footer: {
			Text("iPlayPC is free software under the GNU Affero General Public License v3. You can get its source, change it and share it under the same licence. Not affiliated with or endorsed by Valve Corporation. Steam is a trademark of Valve Corporation.")
		}
	}
}

struct LicensesView: View {
	var body: some View {
		List(OpenSourceComponent.all) { component in
			NavigationLink { LicenseTextView(component: component) } label: {
				VStack(alignment: .leading) {
					Text(component.name)
					Text(component.license).font(.caption).foregroundStyle(.secondary)
				}
			}
		}
		.navigationTitle("Licences")
		.navigationBarTitleDisplayMode(.inline)
	}
}

private struct LicenseTextView: View {
	let component: OpenSourceComponent

	private var text: String {
		Bundle.main.url(forResource: component.file, withExtension: "txt")
			.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			?? "The licence text is missing from this build. See \(component.url.absoluteString)."
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text(component.notice)
				Link(component.url.absoluteString, destination: component.url)
				Divider()
				Text(text)
					.font(.footnote.monospaced())
					.textSelection(.enabled)
			}
			.padding()
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.navigationTitle(component.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}
