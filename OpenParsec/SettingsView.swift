import SwiftUI

struct SettingsView: View {
	@Binding var visible: Bool

	@AppStorage("resolution") var resolution: ParsecResolution = .client
	@AppStorage("bitrate") var bitrate: Int = 0
	@AppStorage("decoder") var decoder: DecoderPref = .h264
	@AppStorage("cursorMode") var cursorMode: CursorMode = .touchpad
	@AppStorage("cursorScale") var cursorScale: Double = 0.5
	@AppStorage("mouseSensitivity") var mouseSensitivity: Double = 1.0
	@AppStorage("pointerAcceleration") var pointerAcceleration: PointerAcceleration = .adaptive
	@AppStorage("dragLock") var dragLock: Bool = false
	@AppStorage("doubleTapToDrag") var doubleTapToDrag: Bool = true
	@AppStorage("naturalScrolling") var naturalScrolling: Bool = true
	@AppStorage("swapCommandControl") var swapCommandControl: Bool = true
	@AppStorage("noOverlay") var noOverlay: Bool = false
	@AppStorage("hideStatusBar") var hideStatusBar: Bool = true
	@AppStorage("rightClickPosition") var rightClickPosition: RightClickPosition = .firstFinger
	@AppStorage("preferredFramesPerSecond") var preferredFramesPerSecond: Int = 60 // 0 = use device max (ProMotion)
	@AppStorage("decoderCompatibility") var decoderCompatibility: Bool = false // Enable for stutter issues on some devices
	@AppStorage("prefer444") var prefer444: Bool = false
	@AppStorage("showKeyboardButton") var showKeyboardButton: Bool = true
	@AppStorage("saveSessionSettings") var saveSessionSettings: Bool = true

	let resolutionChoices: [Choice<ParsecResolution>]

	init(visible: Binding<Bool>) {
		_visible = visible
		var tmp: [Choice<ParsecResolution>] = []
		for res in ParsecResolution.resolutions {
			tmp.append(Choice(res.desc, res))
		}
		resolutionChoices = tmp
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Picker("Pointer style", selection: $cursorMode) {
						Text("Trackpad").tag(CursorMode.touchpad)
						Text("Direct touch").tag(CursorMode.direct)
					}
					.pickerStyle(.segmented)

					Picker("Right-click location", selection: $rightClickPosition) {
						Text("First finger").tag(RightClickPosition.firstFinger)
						Text("Middle").tag(RightClickPosition.middle)
						Text("Second finger").tag(RightClickPosition.secondFinger)
					}

					SliderSetting(
						title: "Pointer size",
						systemImage: "cursorarrow",
						value: $cursorScale,
						range: 0.1...4
					)

					Picker("Pointer acceleration", selection: $pointerAcceleration) {
						ForEach(PointerAcceleration.allCases) { acceleration in
							Text(acceleration.label).tag(acceleration)
						}
					}

					Toggle("Double-tap to drag", isOn: $doubleTapToDrag)
					Toggle("Drag lock", isOn: $dragLock)
					Toggle("Natural scrolling", isOn: $naturalScrolling)

					SliderSetting(
						title: "Pointer speed",
						systemImage: "cursorarrow.motionlines",
						value: $mouseSensitivity,
						range: 0.1...4
					)
				} header: {
					Label("Controls", systemImage: "hand.draw")
				} footer: {
					Text("At 1×, scroll with two fingers. When zoomed, two fingers pan the view and three fingers scroll the remote computer.")
				}

				Section {
					LabeledContent("Renderer", value: "OpenGL ES · Stable")

					Picker("Default resolution", selection: $resolution) {
						ForEach(resolutionChoices.indices, id: \.self) { index in
							Text(resolutionChoices[index].label).tag(resolutionChoices[index].value)
						}
					}

					Picker("Decoder", selection: $decoder) {
						Text("H.264").tag(DecoderPref.h264)
						Text("Prefer H.265").tag(DecoderPref.h265)
					}

					Picker("Frame rate", selection: $preferredFramesPerSecond) {
						Text("Automatic").tag(0)
						Text("120 FPS").tag(120)
						Text("60 FPS").tag(60)
						Text("30 FPS").tag(30)
					}

					Toggle("Compatibility mode", isOn: $decoderCompatibility)
					Toggle("Prefer 4:4:4 color", isOn: $prefer444)
				} header: {
					Label("Streaming", systemImage: "display")
				} footer: {
					Text("Try compatibility mode if video stutters or fails to decode.")
				}

				Section {
					Toggle("Hide controls by default", isOn: $noOverlay)
					Toggle("Hide the status bar", isOn: $hideStatusBar)
					Toggle("Show keyboard shortcut", isOn: $showKeyboardButton)
					Toggle("Remember session controls", isOn: $saveSessionSettings)
					Toggle("Swap Command and Control", isOn: $swapCommandControl)
				} header: {
					Label("Session", systemImage: "slider.horizontal.3")
				}

				Section {
					LabeledContent("Version", value: getVersionInfo())
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done", action: saveAndExit)
						.fontWeight(.semibold)
				}
			}
		}
		.preferredColorScheme(appScheme)
	}

	func saveAndExit() {
		visible = false
	}

	func getVersionInfo() -> String {
		return "Version \(Bundle.main.infoDictionary!["CFBundleShortVersionString"] ?? "Unknown versino")-\(Bundle.main.infoDictionary!["GitCommitInfo"] ?? "Unknown commit")"
	}
}

private struct SliderSetting: View {
	let title: String
	let systemImage: String
	@Binding var value: Double
	let range: ClosedRange<Double>

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label(title, systemImage: systemImage)
				Spacer()
				Text(value.formatted(.number.precision(.fractionLength(1))))
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
			Slider(value: $value, in: range, step: 0.1)
		}
		.padding(.vertical, 4)
	}
}

struct SettingsView_Previews: PreviewProvider {
	@State static var value: Bool = true

	static var previews: some View {
		SettingsView(visible: $value)
	}
}
