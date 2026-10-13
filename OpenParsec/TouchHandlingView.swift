import ParsecSDK
import UIKit

/// Sends the mouse buttons produced by touch gestures to the host.
class TouchController {
	let viewController: UIViewController
	private var pendingRelease: (button: ParsecMouseButton, work: DispatchWorkItem)?

	init(viewController: UIViewController) {
		self.viewController = viewController
	}

	/// Clicks at `location` in content coordinates, or at the current cursor when nil.
	func click(_ button: ParsecMouseButton, at location: CGPoint?) {
		flushPendingRelease()
		if let location {
			CParsec.sendMousePosition(Int32(location.x), Int32(location.y))
		}
		CParsec.sendMouseClickMessage(button, true)

		// Some games ignore an instant release, so release shortly after, in
		// place. Resending the tap position here would snap the cursor back if
		// it moved in the meantime.
		let work = DispatchWorkItem { [weak self] in
			self?.pendingRelease = nil
			CParsec.sendMouseClickMessage(button, false)
		}
		pendingRelease = (button, work)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
	}

	func press(_ button: ParsecMouseButton) {
		flushPendingRelease()
		CParsec.sendMouseClickMessage(button, true)
	}

	func release(_ button: ParsecMouseButton) {
		flushPendingRelease()
		CParsec.sendMouseClickMessage(button, false)
	}

	/// Sends a scheduled click release now so it stays ordered before later input.
	func flushPendingRelease() {
		guard let pending = pendingRelease else { return }
		pendingRelease = nil
		pending.work.cancel()
		CParsec.sendMouseClickMessage(pending.button, false)
	}

	public func viewDidLoad() { }

}

/// Observes every finger and Pencil touch on the stream view and forwards it
/// to a `TouchGestureClassifier`. It recognizes alongside UIScrollView's pinch
/// and pan rather than competing with them.
final class StreamTouchGestureRecognizer: UIGestureRecognizer {
	enum Phase {
		case began
		case moved
		case ended
		case cancelled
	}

	var onTouches: ((Phase, Set<UITouch>, TimeInterval) -> Void)?
	/// Touches UIKit dropped without ending, e.g. when the recognizer is reset.
	var onAbandon: (([AnyHashable], TimeInterval) -> Void)?

	private var activeTouches = Set<ObjectIdentifier>()

	override init(target: Any?, action: Selector?) {
		super.init(target: target, action: action)
		cancelsTouchesInView = false
		delaysTouchesBegan = false
		delaysTouchesEnded = false
		allowedTouchTypes = [
			NSNumber(value: UITouch.TouchType.direct.rawValue),
			NSNumber(value: UITouch.TouchType.pencil.rawValue)
		]
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
		activeTouches.formUnion(touches.map(ObjectIdentifier.init))
		onTouches?(.began, touches, event.timestamp)
		state = state == .possible ? .began : .changed
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
		onTouches?(.moved, touches, event.timestamp)
		state = .changed
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
		activeTouches.subtract(touches.map(ObjectIdentifier.init))
		onTouches?(.ended, touches, event.timestamp)
		state = activeTouches.isEmpty ? .ended : .changed
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
		activeTouches.subtract(touches.map(ObjectIdentifier.init))
		onTouches?(.cancelled, touches, event.timestamp)
		state = activeTouches.isEmpty ? .cancelled : .changed
	}

	override func reset() {
		super.reset()
		if !activeTouches.isEmpty {
			onAbandon?(activeTouches.map { AnyHashable($0) }, ProcessInfo.processInfo.systemUptime)
		}
		activeTouches.removeAll()
	}
}
