import CoreGraphics
import Foundation

/// Turns raw touches on the stream view into exactly one remote-input gesture
/// at a time: a tap, pointer movement, a drag, a remote scroll, a local
/// zoom/viewport pan, or a display swipe. Nothing is sent to the host until a
/// touch sequence has been classified, so finger jitter never moves the
/// pointer and a slightly moving tap still clicks.
///
/// This type is pure logic. `ParsecViewController` feeds it touches and
/// performs the returned outputs, which keeps the rules testable off-device.
final class TouchGestureClassifier {
	enum PointerMode {
		/// Relative movement; taps click at the existing cursor.
		case trackpad
		/// Absolute movement; taps click beneath the finger.
		case direct
	}

	enum MouseButton {
		case left
		case right
	}

	enum RightClickAnchor {
		case firstFinger
		case middle
		case secondFinger
	}

	enum Feedback {
		case grab
		case release
	}

	struct Configuration {
		var mode: PointerMode = .trackpad
		var doubleTapToDrag = true
		var dragLock = false
		var rightClickAnchor: RightClickAnchor = .firstFinger
		/// When the local view can pan (zoomed in, or the keyboard is covering part
		/// of it), a three-finger drag pans it instead of scrolling the host or
		/// switching displays. Two fingers always scroll the host.
		var viewportPannable = false
		/// A touch that stops remote scroll momentum should not also click.
		var interruptsMomentum = false
	}

	enum Output: Equatable {
		/// Relative pointer motion in view points. `accelerate` is false for the
		/// catch-up that replays movement absorbed by the tap slop.
		case movePointer(dx: CGFloat, dy: CGFloat, dt: TimeInterval, accelerate: Bool)
		/// Absolute pointer position in view coordinates.
		case movePointerTo(CGPoint)
		case press(MouseButton)
		case release(MouseButton)
		/// Press and release. A nil location clicks at the current cursor.
		case click(MouseButton, at: CGPoint?)
		case scroll(dx: CGFloat, dy: CGFloat)
		case scrollEnded(vx: CGFloat, vy: CGFloat)
		case showKeyboard
		/// 1 for a leftward swipe, -1 for a rightward swipe.
		case cycleDisplay(Int)
		/// Pans the zoomed local viewport by a finger delta in view points.
		case panViewport(dx: CGFloat, dy: CGFloat)
		/// Suspends the local pinch-zoom while fingers scroll the host or pan.
		case lockViewport(Bool)
		case feedback(Feedback)
	}

	struct TouchSample {
		var id: AnyHashable
		var location: CGPoint
	}

	enum Tuning {
		/// Movement allowed before a touch stops being a tap.
		static let tapSlop: CGFloat = 10
		/// Movement before a stationary trackpad touch becomes a hold-to-drag.
		static let holdDuration: TimeInterval = 0.45
		/// Two- and three-finger taps must lift within this time.
		static let multiFingerTapDuration: TimeInterval = 0.35
		/// A touch that starts this soon after, and this close to, a one-finger
		/// tap continues it (double-click position, tap-and-drag).
		static let followUpInterval: TimeInterval = 0.3
		static let followUpRadius: CGFloat = 40
		static let scrollSlop: CGFloat = 10
		static let threeFingerSlop: CGFloat = 14
		/// Change in finger spread that marks a two-finger gesture as a pinch.
		static let pinchSlop: CGFloat = 16
		static let swipeDistance: CGFloat = 60
		/// Three-finger movement this much more horizontal than vertical is a swipe.
		static let swipeDominance: CGFloat = 1.43
	}

	private enum DragKind: Equatable {
		/// Trackpad hold until it grabs, then move.
		case hold
		/// Trackpad tap, then touch again and move.
		case tapAndDrag
		/// Trackpad movement while drag lock holds the button.
		case locked
		/// Direct-touch drag from where the finger landed.
		case direct
	}

	private enum Phase: Equatable {
		case idle
		case pending
		case pointer
		case drag(DragKind)
		case scroll
		case swipe(fired: Bool)
		/// Pinch-zoom, owned by the UIScrollView.
		case viewport
		/// Zoomed three-finger pan of the local viewport.
		case viewportPan
		/// Finished or unrecognized; wait for every finger to lift.
		case ignored
	}

	private struct TrackedTouch {
		let order: Int
		let start: CGPoint
		var previous: CGPoint
		var current: CGPoint
		var lastTime: TimeInterval
	}

	private var config = Configuration()
	private var phase: Phase = .idle
	private var touches: [AnyHashable: TrackedTouch] = [:]
	private var liftedTouches: [TrackedTouch] = []
	private var nextOrder = 0

	private var gestureStart: TimeInterval = 0
	private var maxFingers = 0
	private var tapEligible = false
	private var fingerLifted = false
	private var followUpLocation: CGPoint?
	private var dragActivated = false
	private var dragButtonDown = false
	private var viewportLocked = false

	private var baselineCentroid: CGPoint = .zero
	private var baselineSpread: CGFloat = 0
	private var lastCentroid: CGPoint = .zero
	private var lastScrollTime: TimeInterval = 0
	private var scrollVelocity: CGVector = .zero
	private var scrollEndVelocity: CGVector?

	// Persist across touch sequences.
	private var lastTap: (time: TimeInterval, location: CGPoint)?
	/// Drag lock is holding the left button between touch sequences.
	private(set) var buttonLocked = false

	/// When a stationary trackpad touch becomes a hold-to-drag.
	private(set) var holdDeadline: TimeInterval?

	var isButtonHeld: Bool {
		buttonLocked || dragButtonDown
	}

	// MARK: - Input

	func touchesBegan(_ samples: [TouchSample], at time: TimeInterval, configuration: Configuration) -> [Output] {
		for sample in samples {
			touches[sample.id] = TrackedTouch(order: nextOrder, start: sample.location, previous: sample.location, current: sample.location, lastTime: time)
			nextOrder += 1
		}

		if phase == .idle {
			beginSequence(samples, at: time, configuration: configuration)
			return []
		}

		// More fingers joined a sequence that is already under way.
		holdDeadline = nil
		maxFingers = max(maxFingers, touches.count)
		var outputs: [Output] = []

		if touches.count > 3 {
			outputs += abandonDrag()
			phase = .ignored
			tapEligible = false
			return outputs
		}

		switch phase {
		case .pending:
			if fingerLifted {
				phase = .ignored
				tapEligible = false
			} else {
				rebaseline(at: time)
			}
		case .pointer, .drag, .scroll, .viewportPan:
			// The finger count changed mid-gesture: end what was happening and
			// classify the new finger set from scratch, but never as a tap.
			outputs += abandonDrag()
			phase = .pending
			tapEligible = false
			rebaseline(at: time)
		case .swipe, .viewport, .ignored, .idle:
			break
		}
		return outputs
	}

	func touchesMoved(_ samples: [TouchSample], at time: TimeInterval) -> [Output] {
		var moved: (touch: TrackedTouch, dt: TimeInterval)?
		for sample in samples {
			guard var touch = touches[sample.id] else { continue }
			let dt = time - touch.lastTime
			touch.previous = touch.current
			touch.current = sample.location
			touch.lastTime = time
			touches[sample.id] = touch
			moved = (touch, dt)
		}
		guard let moved else { return [] }

		switch phase {
		case .pending:
			return classifyPending(at: time)

		case .pointer:
			let touch = moved.touch
			return [.movePointer(dx: touch.current.x - touch.previous.x, dy: touch.current.y - touch.previous.y, dt: moved.dt, accelerate: true)]

		case .drag(let kind):
			return continueDrag(kind, touch: moved.touch, dt: moved.dt)

		case .scroll:
			guard scrollEndVelocity == nil else { return [] }
			let centroid = currentCentroid()
			let delta = CGVector(dx: centroid.x - lastCentroid.x, dy: centroid.y - lastCentroid.y)
			let dt = max(time - lastScrollTime, 1.0 / 240.0)
			scrollVelocity = CGVector(
				dx: scrollVelocity.dx * 0.5 + delta.dx / dt * 0.5,
				dy: scrollVelocity.dy * 0.5 + delta.dy / dt * 0.5
			)
			lastCentroid = centroid
			lastScrollTime = time
			guard delta.dx != 0 || delta.dy != 0 else { return [] }
			return [.scroll(dx: delta.dx, dy: delta.dy)]

		case .viewportPan:
			let centroid = currentCentroid()
			let delta = CGVector(dx: centroid.x - lastCentroid.x, dy: centroid.y - lastCentroid.y)
			lastCentroid = centroid
			guard delta.dx != 0 || delta.dy != 0 else { return [] }
			return [.panViewport(dx: delta.dx, dy: delta.dy)]

		case .swipe(fired: false):
			return fireSwipeIfFarEnough()

		case .swipe(fired: true), .viewport, .ignored, .idle:
			return []
		}
	}

	func touchesEnded(_ ids: [AnyHashable], at time: TimeInterval) -> [Output] {
		removeTouches(ids)
		var outputs: [Output] = []

		switch phase {
		case .pending:
			if touches.isEmpty {
				outputs += finishPending(at: time)
			} else {
				// Fingers rarely lift at exactly the same moment; a multi-finger
				// tap is still possible until the last one lifts.
				fingerLifted = true
				holdDeadline = nil
			}

		case .drag(let kind) where touches.isEmpty:
			outputs += finishDrag(kind)

		case .scroll:
			if scrollEndVelocity == nil {
				// Capture the fling when the first finger lifts; the centroid jumps
				// once the finger set changes.
				let stale = time - lastScrollTime > 0.08
				scrollEndVelocity = stale ? .zero : scrollVelocity
			}
			if touches.isEmpty, let velocity = scrollEndVelocity {
				outputs.append(.scrollEnded(vx: velocity.dx, vy: velocity.dy))
			}

		case .viewportPan:
			// The centroid jumps once a finger lifts; stop panning.
			phase = .ignored

		case .pointer, .drag, .swipe, .viewport, .ignored, .idle:
			break
		}

		if touches.isEmpty {
			outputs += endSequence()
		}
		return outputs
	}

	func touchesCancelled(_ ids: [AnyHashable], at time: TimeInterval) -> [Output] {
		removeTouches(ids)
		var outputs = abandonDrag()
		phase = touches.isEmpty ? .idle : .ignored
		tapEligible = false
		holdDeadline = nil
		if touches.isEmpty {
			outputs += endSequence()
		}
		return outputs
	}

	func holdTimerFired(at time: TimeInterval) -> [Output] {
		guard phase == .pending,
			  let deadline = holdDeadline, time + 0.005 >= deadline,
			  touches.count == 1, maxFingers == 1, !fingerLifted else {
			return []
		}
		holdDeadline = nil

		// While drag lock holds the button, a stationary touch stays a tap so
		// lifting it releases the lock.
		guard !buttonLocked else { return [] }

		tapEligible = false
		phase = .drag(.hold)
		dragActivated = false
		dragButtonDown = false
		return [.feedback(.grab)]
	}

	/// The UIScrollView started pinch-zooming.
	func viewportGestureBegan() {
		guard phase == .pending, touches.count >= 2 else { return }
		phase = .viewport
		tapEligible = false
	}

	/// Releases anything held, for when the stream view goes away.
	func reset() -> [Output] {
		var outputs = abandonDrag()
		if buttonLocked {
			buttonLocked = false
			outputs.append(.release(.left))
		}
		touches.removeAll()
		phase = .idle
		outputs += endSequence()
		lastTap = nil
		return outputs
	}

	// MARK: - Classification

	private func beginSequence(_ samples: [TouchSample], at time: TimeInterval, configuration: Configuration) {
		config = configuration
		gestureStart = time
		maxFingers = touches.count
		tapEligible = !configuration.interruptsMomentum
		fingerLifted = false
		dragActivated = false
		dragButtonDown = false
		scrollEndVelocity = nil
		liftedTouches = []

		followUpLocation = nil
		if touches.count == 1, let tap = lastTap, let location = samples.first?.location,
		   time - tap.time <= Tuning.followUpInterval,
		   distance(location, tap.location) <= Tuning.followUpRadius {
			followUpLocation = tap.location
		}
		lastTap = nil

		phase = touches.count > 3 ? .ignored : .pending
		let canHold = phase == .pending && touches.count == 1 && configuration.mode == .trackpad
		holdDeadline = canHold ? time + Tuning.holdDuration : nil
		rebaseline(at: time)
	}

	private func classifyPending(at time: TimeInterval) -> [Output] {
		let displacement = maxDisplacement()
		if displacement > Tuning.tapSlop {
			tapEligible = false
		}

		if fingerLifted {
			// Only a multi-finger tap can come out of a partly lifted sequence.
			if displacement > Tuning.tapSlop {
				phase = .ignored
			}
			return []
		}

		switch touches.count {
		case 1 where maxFingers == 1:
			guard displacement > Tuning.tapSlop, let touch = touches.values.first else { return [] }
			holdDeadline = nil
			return startOneFingerMotion(touch, at: time)

		case 2:
			if abs(currentSpread() - baselineSpread) > Tuning.pinchSlop {
				phase = .viewport
				return []
			}
			let centroid = currentCentroid()
			guard distance(centroid, baselineCentroid) > Tuning.scrollSlop else { return [] }
			return startScroll(from: centroid, at: time)

		case 3:
			let centroid = currentCentroid()
			let dx = centroid.x - baselineCentroid.x
			let dy = centroid.y - baselineCentroid.y
			guard hypot(dx, dy) > Tuning.threeFingerSlop else { return [] }
			if config.viewportPannable {
				phase = .viewportPan
				lastCentroid = centroid
				var outputs: [Output] = [.panViewport(dx: dx, dy: dy)]
				if !viewportLocked {
					viewportLocked = true
					outputs.insert(.lockViewport(true), at: 0)
				}
				return outputs
			}
			if abs(dx) > abs(dy) * Tuning.swipeDominance {
				phase = .swipe(fired: false)
				return fireSwipeIfFarEnough()
			}
			return startScroll(from: centroid, at: time)

		default:
			return []
		}
	}

	private func startOneFingerMotion(_ touch: TrackedTouch, at time: TimeInterval) -> [Output] {
		switch config.mode {
		case .direct:
			phase = .drag(.direct)
			dragActivated = true
			dragButtonDown = true
			return [.movePointerTo(touch.start), .press(.left), .movePointerTo(touch.current)]

		case .trackpad:
			// Replay the movement the slop absorbed so the pointer tracks the
			// finger exactly, without accelerating that first jump.
			let catchUp = Output.movePointer(
				dx: touch.current.x - touch.start.x,
				dy: touch.current.y - touch.start.y,
				dt: time - gestureStart,
				accelerate: false
			)
			if buttonLocked {
				phase = .drag(.locked)
				dragActivated = true
				return [catchUp]
			}
			if followUpLocation != nil && config.doubleTapToDrag {
				phase = .drag(.tapAndDrag)
				dragActivated = true
				dragButtonDown = true
				return [.press(.left), .feedback(.grab), catchUp]
			}
			phase = .pointer
			return [catchUp]
		}
	}

	private func continueDrag(_ kind: DragKind, touch: TrackedTouch, dt: TimeInterval) -> [Output] {
		if !dragActivated {
			// A hold arms the drag; the button goes down once the finger moves.
			guard distance(touch.current, touch.start) > Tuning.tapSlop else { return [] }
			dragActivated = true
			dragButtonDown = true
			return [
				.press(.left),
				.movePointer(dx: touch.current.x - touch.start.x, dy: touch.current.y - touch.start.y, dt: dt, accelerate: false)
			]
		}
		if kind == .direct {
			return [.movePointerTo(touch.current)]
		}
		return [.movePointer(dx: touch.current.x - touch.previous.x, dy: touch.current.y - touch.previous.y, dt: dt, accelerate: true)]
	}

	private func startScroll(from centroid: CGPoint, at time: TimeInterval) -> [Output] {
		phase = .scroll
		lastCentroid = centroid
		lastScrollTime = time
		scrollVelocity = .zero
		scrollEndVelocity = nil
		guard !viewportLocked else { return [] }
		viewportLocked = true
		return [.lockViewport(true)]
	}

	private func fireSwipeIfFarEnough() -> [Output] {
		let dx = currentCentroid().x - baselineCentroid.x
		guard abs(dx) >= Tuning.swipeDistance else { return [] }
		phase = .swipe(fired: true)
		return [.cycleDisplay(dx < 0 ? 1 : -1)]
	}

	// MARK: - Completion

	private func finishPending(at time: TimeInterval) -> [Output] {
		guard tapEligible else { return [] }
		let fingers = liftedTouches.sorted { $0.order < $1.order }

		switch maxFingers {
		case 1:
			guard let touch = fingers.first else { return [] }
			if buttonLocked {
				buttonLocked = false
				return [.release(.left), .feedback(.release)]
			}
			switch config.mode {
			case .trackpad:
				lastTap = (time, touch.start)
				return [.click(.left, at: nil)]
			case .direct:
				// Keep both clicks of a double-tap on one spot so the host
				// recognizes the double-click.
				let point = followUpLocation ?? touch.start
				lastTap = (time, point)
				return [.click(.left, at: point)]
			}

		case 2:
			guard time - gestureStart <= Tuning.multiFingerTapDuration, fingers.count >= 2 else { return [] }
			switch config.mode {
			case .trackpad:
				return [.click(.right, at: nil)]
			case .direct:
				let point: CGPoint
				switch config.rightClickAnchor {
				case .firstFinger: point = fingers[0].start
				case .secondFinger: point = fingers[1].start
				case .middle: point = midpoint(fingers[0].start, fingers[1].start)
				}
				return [.click(.right, at: point)]
			}

		case 3:
			guard time - gestureStart <= Tuning.multiFingerTapDuration else { return [] }
			return [.showKeyboard]

		default:
			return []
		}
	}

	private func finishDrag(_ kind: DragKind) -> [Output] {
		defer {
			dragActivated = false
			dragButtonDown = false
		}

		if !dragActivated {
			// Held without moving: a long click.
			return [.click(.left, at: nil)]
		}

		if kind == .locked {
			return []
		}
		if kind != .direct && config.dragLock {
			buttonLocked = true
			return []
		}
		return [.release(.left), .feedback(.release)]
	}

	/// Ends a drag that is interrupted rather than lifted. A locked button stays
	/// locked; drag lock only releases on a tap.
	private func abandonDrag() -> [Output] {
		defer {
			dragActivated = false
			dragButtonDown = false
		}
		guard dragButtonDown else { return [] }
		return [.release(.left), .feedback(.release)]
	}

	private func endSequence() -> [Output] {
		phase = .idle
		holdDeadline = nil
		liftedTouches = []
		guard viewportLocked else { return [] }
		viewportLocked = false
		return [.lockViewport(false)]
	}

	// MARK: - Geometry

	private func removeTouches(_ ids: [AnyHashable]) {
		for id in ids {
			if let touch = touches.removeValue(forKey: id) {
				liftedTouches.append(touch)
			}
		}
	}

	private func rebaseline(at time: TimeInterval) {
		baselineCentroid = currentCentroid()
		baselineSpread = currentSpread()
		lastCentroid = baselineCentroid
		lastScrollTime = time
	}

	private func currentCentroid() -> CGPoint {
		guard !touches.isEmpty else { return .zero }
		var sum = CGPoint.zero
		for touch in touches.values {
			sum.x += touch.current.x
			sum.y += touch.current.y
		}
		let count = CGFloat(touches.count)
		return CGPoint(x: sum.x / count, y: sum.y / count)
	}

	/// Mean distance of the fingers from their centroid.
	private func currentSpread() -> CGFloat {
		guard touches.count >= 2 else { return 0 }
		let centroid = currentCentroid()
		let total = touches.values.reduce(CGFloat(0)) { $0 + distance($1.current, centroid) }
		return total / CGFloat(touches.count)
	}

	private func maxDisplacement() -> CGFloat {
		touches.values.reduce(CGFloat(0)) { max($0, distance($1.current, $1.start)) }
	}

	private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
		hypot(a.x - b.x, a.y - b.y)
	}

	private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
		CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
	}
}

/// Velocity-based pointer acceleration. Slow, precise movement maps 1:1 (or the
/// curve's base gain); only fast flicks are amplified. Gain depends on finger
/// speed rather than per-event distance, so it behaves the same at any touch
/// sample rate, and it scales both axes together to preserve direction.
struct PointerAccelerator {
	var curve: PointerAcceleration = .adaptive
	private var smoothedSpeed: CGFloat = 0

	init(curve: PointerAcceleration = .adaptive) {
		self.curve = curve
	}

	mutating func reset() {
		smoothedSpeed = 0
	}

	mutating func scale(dx: CGFloat, dy: CGFloat, dt: TimeInterval, accelerate: Bool) -> CGVector {
		guard accelerate else {
			reset()
			return CGVector(dx: dx, dy: dy)
		}
		let speed = hypot(dx, dy) / CGFloat(max(dt, 1.0 / 240.0))
		smoothedSpeed = smoothedSpeed == 0 ? speed : smoothedSpeed * 0.5 + speed * 0.5
		let gain = Self.gain(for: smoothedSpeed, curve: curve)
		return CGVector(dx: dx * gain, dy: dy * gain)
	}

	/// Speed is in points per second.
	static func gain(for speed: CGFloat, curve: PointerAcceleration) -> CGFloat {
		let threshold: CGFloat = 150
		switch curve {
		case .linear:
			return 1
		case .adaptive:
			return 1 + min(max((speed - threshold) / 900, 0), 1.2)
		case .fast:
			return 1.35 + min(max((speed - threshold) / 550, 0), 1.85)
		}
	}
}
