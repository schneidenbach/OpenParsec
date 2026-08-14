import SwiftUI
import ParsecSDK
import Network

struct MainView: View {
	var controller: ContentView?

	@State private var page: Page = .hosts

	// Host page vars
	@State var hostCountStr: String = "0 hosts"
	@State var refreshTime: String = "Last refreshed at 1/1/1970 12:00 AM"

	@State var hosts: [IdentifiableHostInfo] = []

	// Friend page vars
	@State var friendCountStr: String = "0 friends"

	@State var userInfo: IdentifiableUserInfo?
	@State var friends: [IdentifiableUserInfo] = []

	// Global vars
	@State var showBaseAlert: Bool = false
	@State var baseAlertText: String = ""

	@State var showLogoutAlert: Bool = false

	@State var isConnecting: Bool = false
	@State var connectingToName: String = ""
	@State var pollTimer: Timer?

	@State var isRefreshing: Bool = false

	@State var inSettings: Bool = false
	@State private var profileEditorHost: IdentifiableHostInfo?
	@State private var showPeerConnect = false
	@State private var peerInput = ""
	@ObservedObject private var connectivity = ConnectivityMonitor.shared
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	var busy: Bool {
		isConnecting
	}

	init(_ controller: ContentView?) {
		self.controller = controller
	}

	var body: some View {
		ZStack {
			appNavigation
			.disabled(busy)
			.onAppear(perform: initView)

			if isConnecting {
				connectingOverlay
					.transition(.opacity.combined(with: .scale(scale: 0.96)))
			}
		}
		.sheet(isPresented: $inSettings) {
			SettingsView(visible: $inSettings)
		}
		.sheet(item: $profileEditorHost) { host in
			HostProfileEditor(host: host)
		}
		.sheet(isPresented: $showPeerConnect) {
			PeerConnectView(peerInput: $peerInput) {
				connectToPeerInput()
			}
			.presentationDetents([.medium])
		}
		.confirmationDialog("Sign out of OpenParsec?", isPresented: $showLogoutAlert, titleVisibility: .visible) {
			Button("Sign Out", role: .destructive, action: logout)
			Button("Cancel", role: .cancel) {}
		}
		.alert("Something went wrong", isPresented: $showBaseAlert) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(baseAlertText)
		}
		.onOpenURL(perform: handleIncomingURL)
		.onReceive(SessionContext.shared.$pendingConnectionURL.compactMap { $0 }) { url in
			SessionContext.shared.pendingConnectionURL = nil
			handleIncomingURL(url)
		}
		.onChange(of: connectivity.isOnline) { _, online in
			if online {
				refreshHosts()
			}
		}
	}

	@ViewBuilder
	private var appNavigation: some View {
		if horizontalSizeClass == .regular {
			NavigationSplitView {
				List {
					Button {
						page = .hosts
					} label: {
						Label("Computers", systemImage: "desktopcomputer")
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.listRowBackground(page == .hosts ? Color.accentColor.opacity(0.16) : Color.clear)

					Button {
						page = .friends
					} label: {
						Label("People", systemImage: "person.2.fill")
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.listRowBackground(page == .friends ? Color.accentColor.opacity(0.16) : Color.clear)
				}
				.buttonStyle(.plain)
				.navigationTitle("OpenParsec")
			} detail: {
				NavigationStack {
					Group {
						if page == .hosts {
							hostsContent
						} else {
							peopleContent
						}
					}
					.navigationTitle(page == .hosts ? "Computers" : "People")
					.toolbar { mainToolbar }
				}
			}
		} else {
			TabView(selection: $page) {
				NavigationStack {
					hostsContent
						.navigationTitle("Computers")
						.toolbar { mainToolbar }
				}
				.tabItem {
					Label("Computers", systemImage: "desktopcomputer")
				}
				.tag(Page.hosts)

				NavigationStack {
					peopleContent
						.navigationTitle("People")
						.toolbar { mainToolbar }
				}
				.tabItem {
					Label("People", systemImage: "person.2.fill")
				}
				.tag(Page.friends)
			}
		}
	}

	@ToolbarContentBuilder
	private var mainToolbar: some ToolbarContent {
		ToolbarItem(placement: .topBarLeading) {
			Menu {
				if let userInfo {
					Label("\(userInfo.username)#\(userInfo.id)", systemImage: "person.crop.circle")
				}
				Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
					showLogoutAlert = true
				}
			} label: {
				Image(systemName: "person.crop.circle")
			}
			.accessibilityLabel("Account")
		}

		ToolbarItemGroup(placement: .topBarTrailing) {
			if isRefreshing {
				ProgressView()
			} else if page == .hosts {
				Button(action: refreshHosts) {
					Image(systemName: "arrow.clockwise")
				}
				.accessibilityLabel("Refresh computers")
			}

			Button {
				showPeerConnect = true
			} label: {
				Image(systemName: "plus")
			}
			.accessibilityLabel("Connect with peer ID or link")

			Button {
				inSettings = true
			} label: {
				Image(systemName: "gearshape")
			}
			.accessibilityLabel("Settings")
		}
	}

	@ViewBuilder
	private var hostsContent: some View {
		if !connectivity.isOnline {
			ContentUnavailableView {
				Label("You’re Offline", systemImage: "wifi.slash")
			} description: {
				Text("OpenParsec will refresh automatically when the connection returns.")
			}
		} else
		if hosts.isEmpty && !isRefreshing {
			ContentUnavailableView {
				Label("No Computers", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
			} description: {
				Text("Make sure Parsec is running on a host, then refresh.")
			} actions: {
				Button("Refresh", action: refreshHosts)
					.buttonStyle(.borderedProminent)
			}
		} else {
			ScrollView {
				LazyVGrid(
					columns: [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 16)],
					spacing: 16
				) {
					ForEach(hosts) { host in
						Button {
							connectTo(host)
						} label: {
							ComputerCard(host: host)
						}
						.buttonStyle(PressableCardButtonStyle())
						.accessibilityHint("Connects to \(host.hostname)")
						.contextMenu {
							Menu("Use Preset", systemImage: "dial.medium") {
								ForEach(HostProfileKind.allCases) { kind in
									Button {
										HostProfileStore.set(.preset(kind), for: host.id)
									} label: {
										Label(kind.label, systemImage: kind.systemImage)
									}
								}
							}
							Button {
								profileEditorHost = host
							} label: {
								Label("Connection Profile", systemImage: "slider.horizontal.3")
							}
							Button {
								UIPasteboard.general.string = host.id
							} label: {
								Label("Copy Peer ID", systemImage: "doc.on.doc")
							}
						}
					}
				}
				.padding(.horizontal, 16)
				.padding(.top, 8)

				Text(refreshTime)
					.font(.footnote)
					.foregroundStyle(.tertiary)
					.padding(.vertical, 12)
			}
			.refreshable {
				refreshHosts()
			}
		}
	}

	@ViewBuilder
	private var peopleContent: some View {
		List {
			if let userInfo {
				Section("You") {
					PersonRow(user: userInfo)
				}
			}

			if friends.isEmpty {
				Section {
					ContentUnavailableView(
						"No Friends Yet",
						systemImage: "person.2.slash",
						description: Text("Friends from your Parsec account will appear here.")
					)
					.listRowBackground(Color.clear)
				}
			} else {
				Section("Friends") {
					ForEach(friends) { friend in
						PersonRow(user: friend)
					}
				}
			}

			Section {
				Link(destination: URL(string: "https://parsec.app/account")!) {
					Label("Manage Friends & Invitations", systemImage: "person.badge.plus")
				}
			}
		}
		.listStyle(.insetGrouped)
		.refreshable {
			refreshSelf()
			refreshFriends()
		}
	}

	private var connectingOverlay: some View {
		ZStack {
			Color.black.opacity(0.45)
				.ignoresSafeArea()

			VStack(spacing: 18) {
				ProgressView()
					.controlSize(.large)

				VStack(spacing: 5) {
					Text("Connecting")
						.font(.headline)
					Text(connectingToName)
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}

				Button("Cancel", role: .cancel, action: cancelConnection)
					.buttonStyle(.bordered)
			}
			.padding(28)
			.frame(maxWidth: 320)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
			.shadow(color: .black.opacity(0.25), radius: 30, y: 16)
		}
	}

	func initView() {
		refreshHosts()
		refreshSelf()
		refreshFriends()

		ParsecBackgroundManager.shared.onShouldReconnect = { peerId in
			if let host = hosts.first(where: { $0.id == peerId }) {
				connectTo(host)
			} else {
				refreshHosts()
			}
		}
	}

	func refreshHosts() {
		withAnimation {
			isRefreshing = true

			let clinfo = NetworkHandler.clinfo
			if clinfo == nil {
				isRefreshing = false
				baseAlertText = "Error gathering hosts: Invalid session"
				showBaseAlert = true
				return
			}

			let apiURL = URL(string: "https://kessel-api.parsec.app/v2/hosts?mode=desktop&public=false")!

			var request = URLRequest(url: apiURL)
			request.httpMethod = "GET"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.setValue("Bearer \(clinfo!.session_id)", forHTTPHeaderField: "Authorization")
			request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")

			let task = URLSession.shared.dataTask(with: request) { (data, response, _) in
				DispatchQueue.main.async {
					if let data = data {
						guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return }
						let decoder = JSONDecoder()

						if statusCode == 200 { // 200 OK
							guard let info: HostInfoList = try? decoder.decode(HostInfoList.self, from: data) else { return }
							hosts.removeAll()
							if let datas = info.data {
								datas.forEach { h in
									hosts.append(IdentifiableHostInfo(id: h.peer_id, hostname: h.name, user: h.user, connections: h.players))
								}
							}

							var grammar: String = "hosts"
							if hosts.count == 1 {
								grammar = "host"
							}

							hostCountStr = "\(hosts.count) \(grammar)"

							let formatter = DateFormatter()
							formatter.dateFormat = "M/d/yyyy h:mm a"
							refreshTime = "Last refreshed at \(formatter.string(from: Date()))"
						} else if statusCode == 403 { // 403 Forbidden
							guard let info: ErrorInfo = try? decoder.decode(ErrorInfo.self, from: data) else { return }

							baseAlertText = "Error gathering hosts: \(info.error)"
							showBaseAlert = true
						}
					}

					isRefreshing = false
				}
			}
			task.resume()
		}
	}

	func refreshSelf() {
		withAnimation {
			let clinfo = NetworkHandler.clinfo
			if clinfo == nil {
				return
			}

			let apiURL = URL(string: "https://kessel-api.parsec.app/me")!

			var request = URLRequest(url: apiURL)
			request.httpMethod = "GET"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.setValue("Bearer \(clinfo!.session_id)", forHTTPHeaderField: "Authorization")
			request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")

			let task = URLSession.shared.dataTask(with: request) { (data, response, _) in
				DispatchQueue.main.async {
					if let data = data {
						guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return }
						let decoder = JSONDecoder()

						if statusCode == 200 { // 200 OK
							guard let selfInfo = try? decoder.decode(SelfInfo.self, from: data) else { return }
							userInfo = IdentifiableUserInfo(id: selfInfo.data.id, username: selfInfo.data.name)
						} else {
							guard let info: ErrorInfo = try? decoder.decode(ErrorInfo.self, from: data) else { return }

							baseAlertText = "Error gathering user info: \(info.error)"
							showBaseAlert = true
						}
					}
				}
			}
			task.resume()
		}
	}

	func refreshFriends() {
		withAnimation {
			let clinfo = NetworkHandler.clinfo
			if clinfo == nil {
				return
			}

			let apiURL = URL(string: "https://kessel-api.parsec.app/friendships")!

			var request = URLRequest(url: apiURL)
			request.httpMethod = "GET"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.setValue("Bearer \(clinfo!.session_id)", forHTTPHeaderField: "Authorization")
			request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")

			let task = URLSession.shared.dataTask(with: request) { (data, response, _) in
				DispatchQueue.main.async {
					if let data = data {
						guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return }
						let decoder = JSONDecoder()

						print("/friendships: \(statusCode)")
						print(String(data: data, encoding: .utf8)!)

						if statusCode == 200 { // 200 OK
							guard let info: FriendInfoList = try? decoder.decode(FriendInfoList.self, from: data) else { return }
							friends.removeAll()
							if let datas = info.data {
								datas.forEach { f in
									friends.append(IdentifiableUserInfo(id: f.user_id, username: f.user_name))
								}
							}

							var grammar: String = "friends"
							if friends.count == 1 {
								grammar = "friend"
							}

							friendCountStr = "\(friends.count) \(grammar)"
						} else {
							guard let info: ErrorInfo = try? decoder.decode(ErrorInfo.self, from: data) else { return }

							baseAlertText = "Error gathering friends: \(info.error)"
							showBaseAlert = true
						}
					}

					isRefreshing = false
				}
			}
			task.resume()
		}
	}

	func connectTo(_ who: IdentifiableHostInfo) {
		let profile = HostProfileStore.profile(for: who.id)
		profile.apply()
		SessionContext.shared.peerID = who.id
		SessionContext.shared.hostName = who.hostname
		CParsec.initialize()
		connectingToName = who.hostname
		withAnimation { isConnecting = true }

		var status = CParsec.connect(who.id)

		// Polling status
		pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
			status = CParsec.getStatus()

			if status == PARSEC_CONNECTING { return } // wait

			withAnimation { isConnecting = false }

			if status == PARSEC_OK {
				if let c = controller {
					c.setView(.parsec)
				}
			} else {
				baseAlertText = "Error connecting to host (code \(status.rawValue))"
				showBaseAlert = true
			}

			timer.invalidate()
		}
	}

	private func connectToPeerInput() {
		guard let peerID = parsedPeerID(from: peerInput) else {
			baseAlertText = "Enter a valid Parsec peer ID or share link."
			showBaseAlert = true
			return
		}
		showPeerConnect = false
		let host = hosts.first(where: { $0.id == peerID })
			?? IdentifiableHostInfo(
				id: peerID,
				hostname: "Peer \(peerID.prefix(8))",
				user: UserInfo(id: 0, name: "Shared computer", warp: false, team_id: ""),
				connections: 0
			)
		connectTo(host)
	}

	private func handleIncomingURL(_ url: URL) {
		peerInput = url.absoluteString
		connectToPeerInput()
	}

	private func parsedPeerID(from input: String) -> String? {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if let url = URL(string: trimmed), url.scheme != nil {
			let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
				.queryItems?
				.first(where: { ["peer_id", "peer", "id"].contains($0.name.lowercased()) })?
				.value
			if let query, !query.isEmpty { return query }
			let component = url.pathComponents.last
			if let component, component != "/" && !component.isEmpty { return component }
			if url.scheme == "openparsec", let host = url.host, host != "connect" { return host }
			return nil
		}
		return trimmed.replacingOccurrences(of: "#", with: "")
	}

	func cancelConnection() {
		withAnimation { isConnecting = false }

		CParsec.disconnect()

		pollTimer?.invalidate()
	}

	func logout() {
		removeFromKeychain(key: GLBDataModel.shared.SessionKeyChainKey)
		NetworkHandler.clinfo = nil
		if let c = controller {
			c.setView(.login)
		}
	}

	func removeFromKeychain(key: String) {
		let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
		let status = SecItemDelete(query as CFDictionary)
		if status == errSecSuccess {
			print("Successfully removed data from keychain.")
		}
	}
}

private struct ComputerCard: View {
	let host: IdentifiableHostInfo
	private var profile: HostProfile { HostProfileStore.profile(for: host.id) }

	var body: some View {
		HStack(spacing: 16) {
			ZStack {
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.fill(Color.accentColor.gradient)
				Image(systemName: "desktopcomputer")
					.font(.system(size: 28, weight: .semibold))
					.foregroundStyle(.white)
			}
			.frame(width: 64, height: 64)

			VStack(alignment: .leading, spacing: 5) {
				Text(host.hostname)
					.font(.headline)
					.foregroundStyle(.primary)
					.lineLimit(1)

				Text("\(host.user.name)#\(host.user.id)")
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)

				HStack(spacing: 6) {
					Circle()
						.fill(host.connections > 0 ? Color.orange : Color.green)
						.frame(width: 7, height: 7)
					Text(host.connections > 0 ? "\(host.connections) connected" : "Ready")
						.font(.caption)
						.foregroundStyle(.secondary)

					Text("·")
						.foregroundStyle(.tertiary)
					Label(profile.kind.label, systemImage: profile.kind.systemImage)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			Spacer(minLength: 8)

			Image(systemName: "play.fill")
				.font(.headline)
				.foregroundStyle(.white)
				.padding(12)
				.background(Color.accentColor, in: Circle())
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.stroke(.white.opacity(0.08))
		}
	}
}

private struct PersonRow: View {
	let user: IdentifiableUserInfo

	var body: some View {
		HStack(spacing: 12) {
			URLImage(
				url: URL(string: "https://parsecusercontent.com/cors-resize-image/w=48,h=48,fit=crop,background=white,q=90,f=jpeg/avatars/\(user.id)/avatar"),
				output: {
					$0
						.resizable()
						.scaledToFill()
						.frame(width: 44, height: 44)
						.clipShape(Circle())
				},
				placeholder: {
					Image(systemName: "person.crop.circle.fill")
						.resizable()
						.foregroundStyle(.secondary)
						.frame(width: 44, height: 44)
				}
			)

			VStack(alignment: .leading, spacing: 2) {
				Text(user.username)
					.font(.body.weight(.medium))
				Text("#\(user.id)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 2)
	}
}

private struct PressableCardButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.98 : 1)
			.opacity(configuration.isPressed ? 0.88 : 1)
			.animation(.easeOut(duration: 0.12), value: configuration.isPressed)
	}
}

private struct PeerConnectView: View {
	@Binding var peerInput: String
	let connect: () -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("Peer ID or Parsec share link", text: $peerInput)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.submitLabel(.go)
						.onSubmit(connect)
				} footer: {
					Text("Paste a peer ID, OpenParsec link, or Parsec share link.")
				}
			}
			.navigationTitle("Connect")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Connect", action: connect)
						.fontWeight(.semibold)
						.disabled(peerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				}
			}
		}
	}
}

private struct HostProfileEditor: View {
	let host: IdentifiableHostInfo
	@Environment(\.dismiss) private var dismiss
	@State private var profile: HostProfile

	init(host: IdentifiableHostInfo) {
		self.host = host
		_profile = State(initialValue: HostProfileStore.profile(for: host.id))
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Picker("Preset", selection: Binding(
						get: { profile.kind },
						set: { profile = .preset($0) }
					)) {
						ForEach(HostProfileKind.allCases) { kind in
							Label(kind.label, systemImage: kind.systemImage).tag(kind)
						}
					}
				} header: {
					Text(host.hostname)
				} footer: {
					Text("This profile is applied automatically whenever you connect to this computer.")
				}

				Section("Quality") {
					Picker("Resolution", selection: $profile.resolution) {
						ForEach(ParsecResolution.allCases, id: \.self) { resolution in
							Text(resolution.desc).tag(resolution)
						}
					}
					Picker("Codec", selection: $profile.decoder) {
						Text("H.264").tag(DecoderPref.h264)
						Text("Prefer HEVC").tag(DecoderPref.h265)
					}
					Picker("Frame rate", selection: $profile.frameRate) {
						Text("Automatic / ProMotion").tag(0)
						Text("120 FPS").tag(120)
						Text("60 FPS").tag(60)
						Text("30 FPS").tag(30)
					}
					Picker("Bitrate", selection: $profile.bitrate) {
						Text("Automatic").tag(0)
						ForEach(ParsecResolution.bitrates, id: \.self) { value in
							Text("\(value) Mbps").tag(value)
						}
					}
					Toggle("Constant frame rate", isOn: $profile.constantFPS)
					Toggle("Prefer 4:4:4 color", isOn: $profile.color444)
				}
			}
			.navigationTitle("Connection Profile")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") {
						HostProfileStore.set(profile, for: host.id)
						dismiss()
					}
					.fontWeight(.semibold)
				}
			}
		}
	}
}

struct MainView_Previews: PreviewProvider {
	static var previews: some View {
		MainView(nil)
	}
}

struct IdentifiableHostInfo: Identifiable {
	var id: String // Peer ID
	var hostname: String // Computer's Display Name
	var user: UserInfo // User Data
	var connections: Int // User's Connected To This Host
}

struct IdentifiableUserInfo: Identifiable {
	var id: Int // User ID
	var username: String // User Display Name
}

private enum Page: Hashable {
	case hosts
	case friends
}
