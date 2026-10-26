import SwiftUI
import Combine
import ParsecSDK
import Foundation
import AVFoundation
import UIKit

struct ParsecStatusBar: View {
	@Binding var showMenu: Bool
	@Binding var showDCAlert: Bool
	@Binding var DCAlertText: String
	@Binding var reconnectMessage: String?
	@State var parsecViewController: ParsecViewController?
	@State var wasDisconnected: Bool = true
	@State private var reconnectAttempts = 0
	@State private var nextReconnectAttempt = Date.distantPast
	@ObservedObject private var diagnostics = SessionDiagnostics.shared
	let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

	init(showMenu: Binding<Bool>, showDCAlert: Binding<Bool>, DCAlertText: Binding<String>, reconnectMessage: Binding<String?>, parsecViewController: ParsecViewController) {
		_showMenu = showMenu
		_showDCAlert = showDCAlert
		_DCAlertText = DCAlertText
		_reconnectMessage = reconnectMessage
		self.parsecViewController = parsecViewController
	}

	var body: some View {
		if showMenu {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					DiagnosticPill(
						title: "\(Int(diagnostics.networkLatency)) ms",
						systemImage: "network",
						severity: diagnostics.networkLatency > 80 ? .critical : diagnostics.networkLatency > 40 ? .warning : .healthy
					)
					DiagnosticPill(
						title: "\(diagnostics.bitrate.formatted(.number.precision(.fractionLength(1)))) Mbps",
						systemImage: "speedometer",
						severity: .healthy
					)
					DiagnosticPill(
						title: "\(diagnostics.codec) · \(diagnostics.resolution)",
						systemImage: "display",
						severity: .healthy
					)
					if !diagnostics.issues.isEmpty {
						DiagnosticPill(
							title: "\(diagnostics.issues.count) warning\(diagnostics.issues.count == 1 ? "" : "s")",
							systemImage: "exclamationmark.triangle.fill",
							severity: diagnostics.overallSeverity
						)
					}
				}
				.safeAreaPadding(.horizontal, 72)
				.padding(.vertical, 10)
			}
			.safeAreaPadding(.top, 8)
			.frame(maxHeight: .infinity, alignment: .top)
			.zIndex(1)
		}
		EmptyView()
			.onReceive(timer) { _ in
				poll()
			}
	}

	func poll() {
		if showDCAlert {
			return // no need to poll if we aren't connected anymore
		}

		var pcs = ParsecClientStatus()
		let status = CParsec.getStatusEx(&pcs)

		if status != PARSEC_OK {
			sessionLog.error("Session status \(status.rawValue) (app state \(UIApplication.shared.applicationState.rawValue), video paused \(StreamVideoPauser.shared.isVideoPaused))")
			if ParsecBackgroundManager.shared.isMarkedForReconnect {
				return
			}

			// PiP: connection died (screen lock killed GPU). Kill connection+audio once,
			// subsequent polls exit via isMarkedForReconnect above.
			var pipActive = false
			if #available(iOS 15.0, *) {
				pipActive = PictureInPictureManager.shared.isPiPActive
			}
			if pipActive {
				CParsec.disconnect()
				try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
				ParsecBackgroundManager.shared.connectionDidEnd()
				ParsecBackgroundManager.shared.markForReconnect()
				wasDisconnected = true
				return
			}

			if let peerID = SessionContext.shared.peerID, reconnectAttempts < 4 {
				guard ConnectivityMonitor.shared.isOnline else {
					reconnectMessage = "Waiting for a network connection…"
					return
				}
				guard Date() >= nextReconnectAttempt else { return }
				reconnectAttempts += 1
				reconnectMessage = "Reconnecting… attempt \(reconnectAttempts) of 4"
				CParsec.disconnect()
				_ = CParsec.connect(peerID)
				nextReconnectAttempt = Date().addingTimeInterval(pow(2, Double(reconnectAttempts - 1)))
				return
			}

			wasDisconnected = true
			reconnectMessage = nil
			DCAlertText = "Disconnected (code \(status.rawValue))"
			showDCAlert = true
			return
		}

		if reconnectAttempts > 0 {
			UINotificationFeedbackGenerator().notificationOccurred(.success)
		}
		reconnectAttempts = 0
		reconnectMessage = nil

		let decoder = String.fromBuffer(&pcs.decoder.0.name.0, length: 16)
		diagnostics.update(
			decode: Double(pcs.`self`.metrics.0.decodeLatency),
			encode: Double(pcs.`self`.metrics.0.encodeLatency),
			network: Double(pcs.`self`.metrics.0.networkLatency),
			bitrate: Double(pcs.`self`.metrics.0.bitrate),
			codec: pcs.decoder.0.h265 ? "HEVC" : "H.264",
			resolution: "\(pcs.decoder.0.width)×\(pcs.decoder.0.height)",
			chroma: pcs.decoder.0.color444 ? "4:4:4" : "4:2:0",
			decoder: decoder
		)
	}
}

private struct DiagnosticPill: View {
	let title: String
	let systemImage: String
	let severity: DiagnosticSeverity

	private var color: Color {
		switch severity {
		case .healthy: return .green
		case .notice: return .blue
		case .warning: return .orange
		case .critical: return .red
		}
	}

	var body: some View {
		Label(title, systemImage: systemImage)
			.font(.caption.weight(.semibold))
			.padding(.horizontal, 10)
			.padding(.vertical, 7)
			.background(.ultraThinMaterial, in: Capsule())
			.overlay(Capsule().stroke(color.opacity(0.55)))
			.foregroundStyle(.white)
	}
}

// CRITICAL: This class exists to PERSIST the ParsecViewController instance across SwiftUI view updates.
// Do not remove or change to a struct. If ParsecViewController is recreated, the keyboard responder chain breaks.
class ParsecSession: ObservableObject {
    let controller: ParsecViewController

    init() {
        self.controller = ParsecViewController()
    }
}

struct ParsecView: View {
	var controller: ContentView?

	@State var showDCAlert: Bool = false
	@State var DCAlertText: String = "Disconnected (reason unknown)"
	@State var metricInfo: String = "Loading..."
	@State private var reconnectMessage: String?

	@State var hideOverlay: Bool = false
	@State var showMenu: Bool = false
	@State private var showControlsSheet: Bool = false
	@State private var showGestureGuide: Bool = false
	@State private var showKeyboardPalette: Bool = false
	@State private var chromeHideWorkItem: DispatchWorkItem?
	@State private var adaptiveQualityWorkItem: DispatchWorkItem?
	@State private var adaptiveBaseResolution: CGSize?
	@State private var adaptiveBaseBitrate: Int?
	@AppStorage("didShowGestureGuideV2") private var didShowGestureGuide: Bool = false
	@AppStorage("cursorMode") private var cursorMode: CursorMode = .touchpad

	@State var showKeyboard: Bool = false
	@State var zoomEnabled: Bool = false

	@State var muted: Bool = false
	@State var preferH265: Bool = true
	@State var prefer444: Bool = false
	@State var constantFps = false

	@State var resolutions: [ParsecResolution]
	@State var bitrates: [Int]

    // Persist the VC across view updates using StateObject.
    // CRITICAL: Changing this to @State or a simple var will break the keyboard after menu interactions.
	@StateObject var session = ParsecSession()

    // Observer shared state for updates
    @ObservedObject var dataModel = DataManager.model

    // Computed property for convenience refactoring
    var parsecViewController: ParsecViewController {
        return session.controller
    }

	// @State var showDisplays: Bool = false

	init(_ controller: ContentView?) {
		self.controller = controller

		let save = SettingsHandler.saveSessionSettings
		// SessionAudio chose this when connecting (muted if other audio was playing).
		_muted = State(initialValue: SessionAudio.isMuted)
		_zoomEnabled = State(initialValue: true)
		_constantFps = State(initialValue: save ? SettingsHandler.savedConstantFps : false)
		_prefer444 = State(initialValue: SettingsHandler.prefer444)
		_resolutions = State(initialValue: ParsecResolution.resolutions)
		_bitrates = State(initialValue: ParsecResolution.bitrates)

    }

    // We need to set up the callback somewhere safer than init.
    // 'onAppear' is a good place, or inside the init of ParsecSession if possible (but it doesn't have access to binding).
    // Let's use onAppear/post.

	var body: some View {
		ZStack {
			UIViewControllerWrapper(self.parsecViewController)
				.zIndex(1)
				.prefersPersistentSystemOverlaysHidden()

			ParsecStatusBar(showMenu: $showMenu, showDCAlert: $showDCAlert, DCAlertText: $DCAlertText, reconnectMessage: $reconnectMessage, parsecViewController: parsecViewController)
			sessionChrome
				.zIndex(2)

			if let reconnectMessage {
				Label(reconnectMessage, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
					.font(.subheadline.weight(.semibold))
					.padding(.horizontal, 16)
					.padding(.vertical, 12)
					.background(.regularMaterial, in: Capsule())
					.foregroundStyle(.white)
					.zIndex(3)
					.transition(.scale.combined(with: .opacity))
			}
		}
		.statusBarHidden(SettingsHandler.hideStatusBar)
		.alert(isPresented: $showDCAlert) {
			Alert(title: Text(DCAlertText), dismissButton: .default(Text("Close"), action: {disconnect()}))
		}
		.onAppear(perform: post)
		.sheet(isPresented: $showControlsSheet) {
			sessionControls
				.presentationDetents([.medium, .large])
				.presentationDragIndicator(.visible)
		}
		.sheet(isPresented: $showGestureGuide, onDismiss: {
			didShowGestureGuide = true
		}) {
			GestureGuideView {
				didShowGestureGuide = true
				showGestureGuide = false
			}
			.presentationDetents([.large])
			.presentationDragIndicator(.visible)
		}
		.sheet(isPresented: $showKeyboardPalette) {
			SpecialKeyPalette {
				showKeyboardPalette = false
			}
			.presentationDetents([.medium, .large])
			.presentationDragIndicator(.visible)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ParsecBackgroundDisconnect"))) { _ in
			if #available(iOS 15.0, *) {
				if PictureInPictureManager.shared.isPiPActive {
					return
				}
			}
			disconnect(isBackgroundDisconnect: true)
		}
		.onReceive(NotificationCenter.default.publisher(for: .parsecCycleDisplay)) { notification in
			let direction = notification.userInfo?["direction"] as? Int ?? 1
			cycleDisplay(direction: direction)
		}
		.edgesIgnoringSafeArea(.all)
	}

	private var sessionChrome: some View {
		GeometryReader { proxy in
			VStack {
				HStack(alignment: .top, spacing: 10) {
					VStack(spacing: 8) {
						Button(action: toggleSessionChrome) {
							Image(systemName: showMenu ? "xmark" : "circle.grid.2x2.fill")
								.font(.system(size: 18, weight: .semibold))
								.frame(width: 44, height: 44)
								.contentShape(Circle())
						}
						.buttonStyle(.plain)
						.background(.ultraThinMaterial, in: Circle())
						.opacity(hideOverlay && !showMenu ? 0.22 : 1)

						if SettingsHandler.showKeyboardButton {
							SessionControlButton(
								systemImage: "keyboard",
								label: "Keyboard",
								isActive: showKeyboard,
								action: toggleKeyboard
							)
							.background(.ultraThinMaterial, in: Circle())
						}
					}

					if showMenu {
						HStack(spacing: 4) {
							SessionControlButton(
								systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
								label: muted ? "Unmute" : "Mute",
								isActive: muted,
								action: {
									toggleMute()
									scheduleChromeHide()
								}
							)

							SessionControlButton(
								systemImage: "ellipsis",
								label: "More controls",
								action: {
									chromeHideWorkItem?.cancel()
									showControlsSheet = true
								}
							)
						}
						.background(.ultraThinMaterial, in: Capsule())
						.transition(.move(edge: .leading).combined(with: .opacity))
					}

					Spacer()
				}

				Spacer()

				if showMenu {
					Button {
						chromeHideWorkItem?.cancel()
						showGestureGuide = true
					} label: {
						Label(
							cursorMode == .touchpad ? "Trackpad · Hold and drag to grab" : "Direct touch · Drag to grab",
							systemImage: cursorMode == .touchpad ? "hand.point.up.left.fill" : "hand.draw.fill"
						)
						.font(.caption.weight(.medium))
						.padding(.horizontal, 14)
						.padding(.vertical, 9)
					}
					.buttonStyle(.plain)
					.background(.ultraThinMaterial, in: Capsule())
					.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.padding(.leading, max(12, proxy.safeAreaInsets.leading + 8))
			.padding(.trailing, max(12, proxy.safeAreaInsets.trailing + 8))
			.padding(.top, max(8, proxy.safeAreaInsets.top + 8))
			.padding(.bottom, max(12, proxy.safeAreaInsets.bottom + 8))
			.foregroundStyle(.white)
		}
	}

	private var sessionControls: some View {
		NavigationStack {
			Form {
				Section("Controls") {
					Picker("Pointer", selection: $cursorMode) {
						Text("Trackpad").tag(CursorMode.touchpad)
						Text("Direct touch").tag(CursorMode.direct)
					}
					.pickerStyle(.segmented)

					Button {
						showControlsSheet = false
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
							showGestureGuide = true
						}
					} label: {
						Label("Gesture Guide", systemImage: "hand.tap")
					}

					Button {
						resetZoom()
					} label: {
						Label("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left")
					}
				}

				Section("Keyboard & Clipboard") {
					Button {
						showControlsSheet = false
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
							showKeyboardPalette = true
						}
					} label: {
						Label("Special Keys", systemImage: "command")
					}

					Button {
						guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
						CParsec.sendText(text)
						UINotificationFeedbackGenerator().notificationOccurred(.success)
					} label: {
						Label("Paste iPhone Clipboard", systemImage: "doc.on.clipboard")
					}

					Button {
						let modifier: UInt32 = SettingsHandler.swapCommandControl ? 224 : 227
						CParsec.sendChord(modifiers: [modifier], key: 6)
					} label: {
						Label("Copy Selection on Host", systemImage: "doc.on.doc")
					}
				}

				Section("Audio & Video") {
					Toggle(
						"Sound",
						isOn: Binding(
							get: { !muted },
							set: { _ in toggleMute() }
						)
					)

					Picker("Resolution", selection: Binding(
						get: { SettingsHandler.resolution },
						set: { changeResolution(res: $0) }
					)) {
						ForEach(resolutions, id: \.self) { resolution in
							Text(resolution.desc).tag(resolution)
						}
					}

					Picker("Bitrate", selection: Binding(
						get: { dataModel.bitrate },
						set: { changeBitRate(bitrate: $0) }
					)) {
						ForEach(bitrates, id: \.self) { bitrate in
							Text(bitrate == 0 ? "Automatic" : "\(bitrate) Mbps").tag(bitrate)
						}
					}

					Toggle(
						"Constant frame rate",
						isOn: Binding(
							get: { constantFps },
							set: { _ in toggleConstantFps() }
						)
					)

					Toggle("Prefer 4:4:4 color", isOn: Binding(
						get: { prefer444 },
						set: { value in
							prefer444 = value
							SettingsHandler.prefer444 = value
							CParsec.applyConfig()
						}
					))
				}

				if dataModel.displayConfigs.count > 1 {
					Section("Display") {
						Picker("Active display", selection: Binding(
							get: { dataModel.output },
							set: { changeDisplay(displayId: $0) }
						)) {
							Text("Automatic").tag("none")
							ForEach(dataModel.displayConfigs, id: \.self) { config in
								Text(config.name).tag(config.id)
							}
						}
					}
				}

				Section("Connection Health") {
					SessionHealthView()
				}

				Section {
					Button {
						showControlsSheet = false
						disableOverlay()
					} label: {
						Label("Hide Controls", systemImage: "eye.slash")
					}

					Button(role: .destructive) {
						showControlsSheet = false
						disconnect()
					} label: {
						Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
					}
				}
			}
			.navigationTitle("Session")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") { showControlsSheet = false }
						.fontWeight(.semibold)
				}
			}
		}
	}

	private func toggleSessionChrome() {
		withAnimation(.snappy(duration: 0.28)) {
			showMenu.toggle()
			hideOverlay = false
		}
		if showMenu {
			getHostUserData()
			scheduleChromeHide()
		} else {
			chromeHideWorkItem?.cancel()
		}
	}

	private func scheduleChromeHide() {
		chromeHideWorkItem?.cancel()
		let workItem = DispatchWorkItem {
			withAnimation(.easeOut(duration: 0.25)) {
				showMenu = false
			}
		}
		chromeHideWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: workItem)
	}

	func post() {
		ParsecBackgroundManager.shared.onShouldDisconnect = {
			NotificationCenter.default.post(name: NSNotification.Name("ParsecBackgroundDisconnect"), object: nil)
		}
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.onPiPStopped = { [self] in
				if UIApplication.shared.applicationState != .active {
					// Synchronous — DispatchQueue.main.async may never execute if iOS suspends the app
					CParsec.disconnect()
					try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
					ParsecBackgroundManager.shared.markForReconnect()
					DispatchQueue.main.async {
						self.disconnect(isBackgroundDisconnect: true)
					}
				} else {
					if ParsecBackgroundManager.shared.isReconnecting {
						return
					}
					// Check actual Parsec status — timers don't reliably fire in background
					var pcs = ParsecClientStatus()
					let currentStatus = CParsec.getStatusEx(&pcs)
					if currentStatus != PARSEC_OK || ParsecBackgroundManager.shared.isMarkedForReconnect {
						CParsec.disconnect()
						try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
						ParsecBackgroundManager.shared.markForReconnect()
						DispatchQueue.main.async {
							self.disconnect(isBackgroundDisconnect: true)
						}
					}
				}
			}
			PictureInPictureManager.shared.onPiPStartFailed = { [self] in
				if UIApplication.shared.applicationState != .active {
					ParsecBackgroundManager.shared.markForReconnect()
					DispatchQueue.main.async {
						self.disconnect(isBackgroundDisconnect: true)
					}
				}
			}
		}

		CParsec.applyConfig()
		SessionAudio.setMuted(muted)
		StreamVideoPauser.shared.start()
		zoomEnabled = true
		parsecViewController.setZoomEnabled(true)

		if SettingsHandler.saveSessionSettings {
			DataManager.model.constantFps = constantFps
		}

		let screenSize: CGSize = self.parsecViewController.view.frame.size
		let sessionScreen = self.parsecViewController.view.window?.screen ?? UIScreen.main
		let scaleFactor = sessionScreen.nativeScale
		ParsecResolution.updateClientResolution(width: Int(screenSize.width * scaleFactor), height: Int(screenSize.height * scaleFactor))

		getHostUserData()

		hideOverlay = SettingsHandler.noOverlay

        parsecViewController.onKeyboardVisibilityChanged = { visible in
            showKeyboard = visible
        }
		parsecViewController.onZoomScaleChanged = { scale in
			scheduleAdaptiveQuality(for: scale)
		}

		parsecViewController.setKeyboardVisible(showKeyboard)

		if !didShowGestureGuide {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
				showGestureGuide = true
			}
		}
	}

	func disableOverlay() {
		hideOverlay = true
		showMenu = false
	}

	func toggleMute() {
		muted.toggle()
		SessionAudio.setMuted(muted)
		if SettingsHandler.saveSessionSettings { SettingsHandler.savedMuted = muted }
	}

		/*func genDisplaySheet() -> ActionSheet
	{
		let len:Int = 16
		var outputs = [ParsecOutput?](repeating:nil, count:len)
		ParsecGetOutputs(&outputs, UInt32(len))
		print("Listing \(outputs.count) displays")

		func getDeviceName(_ output:ParsecOutput) -> String
		{
			return withUnsafePointer(to:output.device)
			{
				$0.withMemoryRebound(to: UInt8.self, capacity:MemoryLayout.size(ofValue:$0))
				{
					String(cString:$0)
				}
			}
		}

		let buttons = outputs.enumerated().map
		{ i, output in
			Alert.Button.default(Text("\(i) - \(getDeviceName(output))"), action:{print("Selected device \(i)")})
		}
		return ActionSheet(title: Text("Select a Display:"), buttons:buttons + [Alert.Button.cancel()])
	}*/

	func disconnect(isBackgroundDisconnect: Bool = false) {
		if !isBackgroundDisconnect {
			ParsecBackgroundManager.shared.disableAutoReconnect()
		}

		StreamVideoPauser.shared.stop()
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.teardown()
		}

		CParsec.disconnect()
		self.parsecViewController.glkView.cleanUp()

		parsecViewController.scrollView.zoomScale = 1.0
		parsecViewController.scrollView.contentOffset = .zero

		if let c = controller {
			c.setView(.main)
		}
	}

	func changeResolution(res: ParsecResolution) {
        SettingsHandler.resolution = res
		DispatchQueue.main.async {
			DataManager.model.resolutionX = res.width
			DataManager.model.resolutionY = res.height
			CParsec.updateHostVideoConfig()
		}
	}

	func changeBitRate(bitrate: Int) {
		SettingsHandler.bitrate = bitrate

		DispatchQueue.main.async {
			DataManager.model.bitrate = bitrate
			CParsec.updateHostVideoConfig()
		}
	}

	func toggleConstantFps() {
		DispatchQueue.main.async {
			DataManager.model.constantFps.toggle()
			constantFps = DataManager.model.constantFps
			CParsec.updateHostVideoConfig()
			if SettingsHandler.saveSessionSettings { SettingsHandler.savedConstantFps = constantFps }
		}
	}

	func toggleKeyboard() {
		DispatchQueue.main.async {
			showKeyboard.toggle()
			parsecViewController.setKeyboardVisible(showKeyboard)
		}
	}

	func resetZoom() {
		DispatchQueue.main.async {
			zoomEnabled = true
			parsecViewController.setZoomEnabled(true)
			parsecViewController.scrollView.setZoomScale(1, animated: true)
			if SettingsHandler.saveSessionSettings { SettingsHandler.savedZoomEnabled = true }
		}
	}

	func scheduleAdaptiveQuality(for zoomScale: CGFloat) {
		adaptiveQualityWorkItem?.cancel()

		if adaptiveBaseResolution == nil {
			let currentWidth = Int(CParsec.hostWidth)
			let currentHeight = Int(CParsec.hostHeight)
			if currentWidth > 0, currentHeight > 0 {
				adaptiveBaseResolution = CGSize(width: currentWidth, height: currentHeight)
			} else if dataModel.resolutionX > 0, dataModel.resolutionY > 0 {
				adaptiveBaseResolution = CGSize(width: dataModel.resolutionX, height: dataModel.resolutionY)
			}
			adaptiveBaseBitrate = dataModel.bitrate
		}

		guard let baseline = adaptiveBaseResolution else { return }
		let baselineBitrate = adaptiveBaseBitrate ?? dataModel.bitrate
		let settledScale = min(max(zoomScale, 1), 3)

		let workItem = DispatchWorkItem {
			let targetWidth: Int
			let targetHeight: Int
			let targetBitrate: Int

			if settledScale <= 1.05 {
				targetWidth = Int(baseline.width)
				targetHeight = Int(baseline.height)
				targetBitrate = baselineBitrate
			} else {
				let maxWidth = max(Int(baseline.width), 3840)
				let scaledWidth = min(Int(baseline.width * settledScale), maxWidth)
				let aspect = baseline.width / max(baseline.height, 1)
				targetWidth = scaledWidth - (scaledWidth % 2)
				let scaledHeight = Int(CGFloat(targetWidth) / aspect)
				targetHeight = scaledHeight - (scaledHeight % 2)
				targetBitrate = min(50, max(baselineBitrate, 20 + Int((settledScale - 1) * 15)))
			}

			guard abs(DataManager.model.resolutionX - targetWidth) > 32
					|| abs(DataManager.model.resolutionY - targetHeight) > 32
					|| DataManager.model.bitrate != targetBitrate else { return }

			DataManager.model.resolutionX = targetWidth
			DataManager.model.resolutionY = targetHeight
			DataManager.model.bitrate = targetBitrate
			CParsec.updateHostVideoConfig()
		}
		adaptiveQualityWorkItem = workItem
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
	}

	func changeDisplay(displayId: String) {
		DispatchQueue.main.async {
			DataManager.model.output = displayId
			CParsec.updateHostVideoConfig()
		}
	}

	func cycleDisplay(direction: Int) {
		let displays = dataModel.displayConfigs
		guard displays.count > 1 else { return }
		let current = displays.firstIndex(where: { $0.id == dataModel.output }) ?? 0
		let next = (current + direction + displays.count) % displays.count
		changeDisplay(displayId: displays[next].id)
	}

	func getHostUserData() {
		let data = "".data(using: .utf8)!
		CParsec.sendUserData(type: .getVideoConfig, message: data)
		CParsec.sendUserData(type: .getAdapterInfo, message: data)
	}

}

private struct SessionControlButton: View {
	let systemImage: String
	let label: String
	var isActive: Bool = false
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: 17, weight: .semibold))
				.frame(width: 44, height: 44)
				.contentShape(Circle())
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(isActive ? Color.accentColor : .white)
		}
		.buttonStyle(.plain)
		.accessibilityLabel(label)
	}
}

private struct SessionHealthView: View {
	@ObservedObject private var diagnostics = SessionDiagnostics.shared

	var body: some View {
		if diagnostics.issues.isEmpty {
			Label("Connection looks healthy", systemImage: "checkmark.circle.fill")
				.foregroundStyle(.green)
		} else {
			ForEach(diagnostics.issues) { issue in
				HStack(alignment: .top, spacing: 12) {
					Image(systemName: issue.systemImage)
						.foregroundStyle(issue.severity >= .critical ? .red : .orange)
						.frame(width: 24)
					VStack(alignment: .leading, spacing: 3) {
						Text(issue.title)
							.font(.body.weight(.medium))
						Text(issue.detail)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
		}

		LabeledContent("Decode", value: "\(diagnostics.decodeLatency.formatted(.number.precision(.fractionLength(1)))) ms")
		LabeledContent("Host encode", value: "\(diagnostics.encodeLatency.formatted(.number.precision(.fractionLength(1)))) ms")
		LabeledContent("Color", value: diagnostics.chroma)
		LabeledContent("Decoder", value: diagnostics.decoder)
	}
}

private struct SpecialKeyPalette: View {
	let onDone: () -> Void

	private let keys: [(String, String, [UInt32], UInt32)] = [
		("Ctrl–Alt–Delete", "lock.rotation", [224, 226], 76),
		("Alt–Tab", "rectangle.2.swap", [226], 43),
		("Task Manager", "gauge.with.dots.needle.50percent", [224, 225], 41),
		("Escape", "escape", [], 41),
		("Windows", "command", [], 227),
		("Print Screen", "camera.viewfinder", [], 70)
	]

	var body: some View {
		NavigationStack {
			List {
				Section {
					ForEach(keys, id: \.0) { item in
						Button {
							CParsec.sendChord(modifiers: item.2, key: item.3)
							UIImpactFeedbackGenerator(style: .light).impactOccurred()
						} label: {
							Label(item.0, systemImage: item.1)
						}
					}
				} header: {
					Text("Send to Host")
				}

				Section("Sticky Modifiers") {
					HStack {
						StickyModifierButton(title: "Ctrl", keyCode: 224)
						StickyModifierButton(title: "Alt", keyCode: 226)
						StickyModifierButton(title: "Shift", keyCode: 225)
						StickyModifierButton(title: "Win", keyCode: 227)
					}
					.buttonStyle(.bordered)
				}
			}
			.navigationTitle("Special Keys")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done", action: onDone)
				}
			}
		}
	}
}

private struct StickyModifierButton: View {
	let title: String
	let keyCode: UInt32
	@State private var active = false

	var body: some View {
		Button(title) {
			active.toggle()
			CParsec.sendKeyboardMessage(keyCode: keyCode, pressed: active)
		}
		.tint(active ? .accentColor : .secondary)
	}
}

private struct GestureGuideView: View {
	let onDone: () -> Void

	private let gestures: [(String, String, String)] = [
		("hand.tap.fill", "Click", "Tap once. Tap twice to double-click."),
		("hand.draw.fill", "Drag", "Trackpad: hold until it grabs, or tap and then touch again, and drag. Direct touch: drag the item."),
		("hand.raised.fingers.spread.fill", "Right-click", "Tap with two fingers."),
		("arrow.up.and.down", "Scroll", "Drag with two fingers, zoomed in or not."),
		("arrow.up.left.and.down.right.magnifyingglass", "Zoom", "Pinch to zoom. The view follows the pointer; drag with three fingers to pan it."),
		("keyboard.fill", "Keyboard", "Tap the keyboard button or tap with three fingers.")
	]

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					VStack(alignment: .leading, spacing: 8) {
						Text("Control your computer")
							.font(.largeTitle.bold())
						Text("OpenParsec behaves like a trackpad by default.")
							.font(.body)
							.foregroundStyle(.secondary)
					}

					ForEach(gestures, id: \.1) { gesture in
						HStack(alignment: .top, spacing: 16) {
							Image(systemName: gesture.0)
								.font(.system(size: 23, weight: .semibold))
								.foregroundStyle(Color.accentColor)
								.frame(width: 48, height: 48)
								.background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

							VStack(alignment: .leading, spacing: 4) {
								Text(gesture.1)
									.font(.headline)
								Text(gesture.2)
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
							.padding(.top, 3)
						}
					}

					Button(action: onDone) {
						Text("Got It")
							.fontWeight(.semibold)
							.frame(maxWidth: .infinity)
							.frame(height: 50)
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
					.padding(.top, 4)
				}
				.padding(24)
				.frame(maxWidth: 560)
				.frame(maxWidth: .infinity)
			}
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Close", action: onDone)
				}
			}
		}
	}
}

// from https://github.com/utmapp/UTM/blob/117e3a962f2f46f7d847632d65fa7a85a2bb0cfa/Platform/iOS/VMWindowView.swift#L314
private extension View {
	func prefersPersistentSystemOverlaysHidden() -> some View {
		if #available(iOS 16, *) {
			return self.persistentSystemOverlays(.hidden)
		} else {
			return self
		}
	}
}
