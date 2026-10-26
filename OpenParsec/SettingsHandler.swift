import Foundation
import SwiftUI

struct SettingsHandler {
	@AppStorage("renderer") public static var renderer: RendererType = .opengl
	@AppStorage("resolution") public static var resolution: ParsecResolution = .client
	/// With Client Resolution, re-match the host when the stream's screen changes
	/// size (folding or unfolding, rotating). May rearrange windows on the host.
	@AppStorage("followScreenChanges") public static var followScreenChanges: Bool = true
	@AppStorage("bitrate") public static var bitrate: Int = 0
	@AppStorage("decoder") public static var decoder: DecoderPref = .h264
	@AppStorage("cursorMode") public static var cursorMode: CursorMode = .touchpad
	@AppStorage("cursorScale") public static var cursorScale: Double = 0.5
	@AppStorage("mouseSensitivity") public static var mouseSensitivity: Double = 1.0
	@AppStorage("pointerAcceleration") public static var pointerAcceleration: PointerAcceleration = .adaptive
	@AppStorage("dragLock") public static var dragLock: Bool = false
	@AppStorage("doubleTapToDrag") public static var doubleTapToDrag: Bool = true
	@AppStorage("naturalScrolling") public static var naturalScrolling: Bool = true
	@AppStorage("swapCommandControl") public static var swapCommandControl: Bool = true
	@AppStorage("noOverlay") public static var noOverlay: Bool = false
	@AppStorage("hideStatusBar") public static var hideStatusBar: Bool = true
	@AppStorage("rightClickPosition") public static var rightClickPosition: RightClickPosition = .firstFinger
	@AppStorage("preferredFramesPerSecond") public static var preferredFramesPerSecond: Int = 60 // 0 = use device max (ProMotion)
	@AppStorage("decoderCompatibility") public static var decoderCompatibility: Bool = false // Enable for stutter issues on some devices
	@AppStorage("prefer444") public static var prefer444: Bool = false
	@AppStorage("showKeyboardButton") public static var showKeyboardButton: Bool = true

	@AppStorage("saveSessionSettings") public static var saveSessionSettings: Bool = true
	@AppStorage("savedZoomEnabled") public static var savedZoomEnabled: Bool = false
	@AppStorage("savedConstantFps") public static var savedConstantFps: Bool = false
	@AppStorage("savedMuted") public static var savedMuted: Bool = false

}

enum RendererCompatibility {
	// The bundled Parsec SDK's Metal renderer crashes inside its AGX pipeline
	// setup on current iOS hardware (confirmed from an iPhone 17 crash report).
	// Keep the implementation available for a future SDK replacement, but never
	// select it until that renderer is upgraded and validated on-device.
	static let supportsBundledSDKMetal = false

	static var effectiveRenderer: RendererType {
		supportsBundledSDKMetal ? SettingsHandler.renderer : .opengl
	}
}

enum PointerAcceleration: Int, CaseIterable, Identifiable {
	case linear
	case adaptive
	case fast

	var id: Int { rawValue }

	var label: String {
		switch self {
		case .linear: return "Linear"
		case .adaptive: return "Adaptive"
		case .fast: return "Fast"
		}
	}
}

enum HostProfileKind: String, Codable, CaseIterable, Identifiable {
	case automatic
	case work
	case gaming
	case cellular

	var id: String { rawValue }

	var label: String {
		switch self {
		case .automatic: return "Automatic"
		case .work: return "Work"
		case .gaming: return "Gaming"
		case .cellular: return "Cellular"
		}
	}

	var systemImage: String {
		switch self {
		case .automatic: return "wand.and.stars"
		case .work: return "textformat"
		case .gaming: return "gamecontroller.fill"
		case .cellular: return "antenna.radiowaves.left.and.right"
		}
	}
}

struct HostProfile: Codable, Equatable {
	var kind: HostProfileKind
	var resolution: ParsecResolution
	var bitrate: Int
	var decoder: DecoderPref
	var frameRate: Int
	var constantFPS: Bool
	var color444: Bool

	static func preset(_ kind: HostProfileKind) -> HostProfile {
		switch kind {
		case .automatic:
			return HostProfile(kind: kind, resolution: .client, bitrate: 0, decoder: .h265, frameRate: 0, constantFPS: false, color444: false)
		case .work:
			return HostProfile(kind: kind, resolution: .client, bitrate: 30, decoder: .h265, frameRate: 60, constantFPS: true, color444: true)
		case .gaming:
			return HostProfile(kind: kind, resolution: .r1920x1080_16_9, bitrate: 35, decoder: .h265, frameRate: 0, constantFPS: true, color444: false)
		case .cellular:
			return HostProfile(kind: kind, resolution: .r1280x720_16_9, bitrate: 7, decoder: .h264, frameRate: 30, constantFPS: false, color444: false)
		}
	}

	func apply() {
		SettingsHandler.resolution = resolution
		SettingsHandler.bitrate = bitrate
		SettingsHandler.decoder = decoder
		SettingsHandler.preferredFramesPerSecond = frameRate
		SettingsHandler.savedConstantFps = constantFPS
		SettingsHandler.prefer444 = color444
		DataManager.model.bitrate = bitrate
		DataManager.model.constantFps = constantFPS
	}
}

enum HostProfileStore {
	private static let storageKey = "hostProfilesV1"

	static func profile(for peerID: String) -> HostProfile {
		load()[peerID] ?? .preset(.automatic)
	}

	static func set(_ profile: HostProfile, for peerID: String) {
		var profiles = load()
		profiles[peerID] = profile
		if let data = try? JSONEncoder().encode(profiles) {
			UserDefaults.standard.set(data, forKey: storageKey)
		}
	}

	private static func load() -> [String: HostProfile] {
		guard let data = UserDefaults.standard.data(forKey: storageKey),
			  let profiles = try? JSONDecoder().decode([String: HostProfile].self, from: data) else {
			return [:]
		}
		return profiles
	}
}
