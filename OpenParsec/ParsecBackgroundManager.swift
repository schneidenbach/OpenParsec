import UIKit
import AVFoundation
import os

/// Session lifecycle log. View with Console.app or `log stream --predicate 'subsystem == "com.spencer.OpenParsec"'`.
let sessionLog = Logger(subsystem: "com.spencer.OpenParsec", category: "session")

class ParsecBackgroundManager {
	static let shared = ParsecBackgroundManager()

	private(set) var hasActiveConnection = false
	private var lastPeerId: String?
	private var didDisconnectDueToBackground = false
	private(set) var isReconnecting = false

	var onShouldReconnect: ((String) -> Void)?
	var onShouldDisconnect: (() -> Void)?

	var isMarkedForReconnect: Bool {
		return didDisconnectDueToBackground || isReconnecting
	}

	var isPiPActive: Bool {
		if #available(iOS 15.0, *) {
			return PictureInPictureManager.shared.isPiPActive
		}
		return false
	}

	private init() {
	}

	func connectionDidStart(peerId: String) {
		hasActiveConnection = true
		lastPeerId = peerId
		didDisconnectDueToBackground = false
		isReconnecting = false
	}

	func connectionDidEnd() {
		hasActiveConnection = false
	}

	func sceneWillResignActive() {
	}

	func sceneDidBecomeActive() {
		// Takes priority over isPiPActive check because stopPiP() is async
		if didDisconnectDueToBackground, let peerId = lastPeerId {
			didDisconnectDueToBackground = false
			isReconnecting = true

			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
				self?.onShouldReconnect?(peerId)
			}
		}
	}

	func sceneDidEnterBackground() {
		if hasActiveConnection {
			var pipAttempted = false
			if #available(iOS 15.0, *) {
				pipAttempted = isPiPActive || PictureInPictureManager.shared.isStarting
			}
			if !pipAttempted {
				didDisconnectDueToBackground = true
			}
		}
	}

	func markForReconnect() {
		guard lastPeerId != nil else { return }
		didDisconnectDueToBackground = true
	}

	func disableAutoReconnect() {
		didDisconnectDueToBackground = false
		isReconnecting = false
		lastPeerId = nil
	}
}

/// Owns the shared audio session for a stream. Host audio only takes over
/// playback, pausing music, when sound is on. While muted the app mixes with
/// other audio, so starting a session never interrupts what is already playing.
enum SessionAudio {
	/// Whether the current session's host audio is muted.
	private(set) static var isMuted = false

	/// Chooses the starting mute state and configures the audio session. Call
	/// after `CParsec.initialize()` and before connecting: the SDK starts
	/// playing host audio as soon as the connection opens.
	static func beginSession() {
		let savedMuted = SettingsHandler.saveSessionSettings && SettingsHandler.savedMuted
		// If music or a podcast is playing, start muted and leave it playing;
		// turning sound on in the session takes over audio.
		setMuted(savedMuted || AVAudioSession.sharedInstance().isOtherAudioPlaying)
	}

	static func setMuted(_ muted: Bool) {
		isMuted = muted
		// Stop host playback before giving up exclusive audio; take exclusive
		// audio before host playback resumes.
		if muted {
			CParsec.setMuted(true)
		}
		configureSession()
		if !muted {
			CParsec.setMuted(false)
		}
	}

	/// Applies the category for the current mute state. Both use `.playback`,
	/// which Picture in Picture requires.
	static func configureSession() {
		let session = AVAudioSession.sharedInstance()
		do {
			if isMuted {
				if session.category == .playback && !session.categoryOptions.contains(.mixWithOthers) {
					// Let the app we interrupted resume.
					try? session.setActive(false, options: .notifyOthersOnDeactivation)
				}
				try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
			} else {
				try session.setCategory(.playback, mode: .default, options: [])
			}
			try session.setActive(true)
		} catch {
			print("[OpenParsec] Audio session configuration failed: \(error)")
		}
	}
}

/// Pauses host video while nothing is drawing the stream, such as when Picture
/// in Picture is stashed at the screen edge or the app switcher is up, and
/// resumes it on the next drawn frame. The SDK documents pausing for exactly
/// this; leaving video flowing with no consumer can end the session.
final class StreamVideoPauser {
	static let shared = StreamVideoPauser()

	/// How long without a drawn frame before video is paused.
	private let stallThreshold: CFTimeInterval = 1.0
	private var lastFrameTime = CACurrentMediaTime()
	private var timer: Timer?
	private(set) var isVideoPaused = false

	private init() { }

	func start() {
		lastFrameTime = CACurrentMediaTime()
		guard timer == nil else { return }
		let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
			self?.checkForStall()
		}
		// Common modes so it also fires while UIKit is tracking touches.
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	func stop() {
		timer?.invalidate()
		timer = nil
		isVideoPaused = false
	}

	/// Called by the renderer for every drawn frame.
	func frameDrawn() {
		lastFrameTime = CACurrentMediaTime()
		guard isVideoPaused else { return }
		isVideoPaused = false
		let status = CParsec.setVideoPaused(false)
		sessionLog.info("Stream visible again; resumed host video (status \(status.rawValue))")
	}

	private func checkForStall() {
		guard !isVideoPaused,
			  ParsecBackgroundManager.shared.hasActiveConnection,
			  CACurrentMediaTime() - lastFrameTime > stallThreshold else { return }
		isVideoPaused = true
		let status = CParsec.setVideoPaused(true)
		sessionLog.info("No frames drawn for \(self.stallThreshold)s (app state \(UIApplication.shared.applicationState.rawValue)); paused host video (status \(status.rawValue))")
	}
}
