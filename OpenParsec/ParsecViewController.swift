import Foundation
import UIKit
import ParsecSDK
import Metal

protocol ParsecPlayground {
	init(viewController: UIViewController, updateImage: @escaping () -> Void)
	func viewDidLoad()
	func cleanUp()
	func updateSize(width: CGFloat, height: CGFloat)
	func updateRenderScale(_ zoomScale: CGFloat)
}

class ParsecViewController: UIViewController, UIScrollViewDelegate {
	var glkView: ParsecPlayground!
	var gamePadController: GamepadController!
	var touchController: TouchController!
	var u: UIImageView?
	var lastImg: CGImage?
    var lastMouseX: Int32 = -1
    var lastMouseY: Int32 = -1
    var lastCursorHidden: Bool = false
	var zoomEnabled = true
	var accumulatedDeltaX: Float = 0.0
	var accumulatedDeltaY: Float = 0.0
	var isRemoteDragging = false
	private let gestureClassifier = TouchGestureClassifier()
	private var pointerAccelerator = PointerAccelerator()
	private var holdTimer: Timer?
	private var scheduledHoldDeadline: TimeInterval?
	private var scrollRemainder: CGPoint = .zero
	private var scrollMomentumVelocity: CGPoint = .zero
	private var scrollMomentumTimer: Timer?
	/// The view size the stream was last fitted to.
	private var laidOutStreamSize: CGSize = .zero

	var mouseSensitivity: Float = Float(SettingsHandler.mouseSensitivity)

	var keyboardAccessoriesView: UIView?
	var keyboardHeight: CGFloat = 0.0
	var keyboardVisible: Bool = false
	var onKeyboardVisibilityChanged: ((Bool) -> Void)?
	var onZoomScaleChanged: ((CGFloat) -> Void)?
	/// The stream was refitted to a new view size in points, at the given screen scale.
	var onStreamResized: ((CGSize, CGFloat) -> Void)?
	private var pinchFocusPoint: CGPoint?
	var scrollView: UIScrollView!
	var contentView: UIView!

	override var prefersPointerLocked: Bool {
		return true
	}

	override var prefersHomeIndicatorAutoHidden: Bool {
		return true
	}

	init() {
		super.init(nibName: nil, bundle: nil)

		if RendererCompatibility.effectiveRenderer == .metal, MTLCreateSystemDefaultDevice() != nil {
			self.glkView = ParsecMetalViewController(viewController: self, updateImage: updateImage)
		} else {
			self.glkView = ParsecGLKViewController(viewController: self, updateImage: updateImage)
		}

		self.gamePadController = GamepadController(viewController: self)
		self.touchController = TouchController(viewController: self)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func updateImage() {
        // Optimization: Snap current valus
        let currentMouseX = CParsec.mouseInfo.mouseX
        let currentMouseY = CParsec.mouseInfo.mouseY
        let currentHidden = CParsec.mouseInfo.cursorHidden
        let currentImg = CParsec.mouseInfo.cursorImg

        // Skip if nothing changed
        if currentMouseX == lastMouseX &&
           currentMouseY == lastMouseY &&
           currentHidden == lastCursorHidden &&
           currentImg == lastImg {
            return
        }

        lastMouseX = currentMouseX
        lastMouseY = currentMouseY
        lastCursorHidden = currentHidden

		if currentImg != nil && !currentHidden {
			if lastImg != currentImg {
				u!.image = UIImage(cgImage: currentImg!)
				lastImg = currentImg!
			}

            // Using tracked values for bounds
			u?.frame = CGRect(x: Int(currentMouseX) - Int(Double(CParsec.mouseInfo.cursorHotX) * SettingsHandler.cursorScale),
							  y: Int(currentMouseY) - Int(Double(CParsec.mouseInfo.cursorHotY) * SettingsHandler.cursorScale),
							  width: Int(Double(CParsec.mouseInfo.cursorWidth) * SettingsHandler.cursorScale),
							  height: Int(Double(CParsec.mouseInfo.cursorHeight) * SettingsHandler.cursorScale))

			// Check bounds and pan if needed
			// Only pan if we are zoomed in OR if the keyboard is visible (to allow scrolling up)
			if scrollView.zoomScale > 1.0 || isRemoteDragging || (keyboardVisible && scrollView.contentInset.bottom > 0) {
				let margin: CGFloat = 50.0

                // Convert cursor frame to screen coordinates (relative to the ViewController's view)
                // This accounts for zoom and current contentOffset automatically.
                let cursorFrameInScreen = contentView.convert(u!.frame, to: view)
                let viewBounds = view.bounds

                var targetOffsetX = scrollView.contentOffset.x
                var targetOffsetY = scrollView.contentOffset.y
                var shouldScroll = false

                // Check Left Edge
                if cursorFrameInScreen.minX < margin {
                    // We want the cursor to be at 'margin', so we shift contentOffset.
                    // NewOffset = CurrentOffset - (Margin - CurrentPos)
                    let diff = margin - cursorFrameInScreen.minX
                    targetOffsetX -= diff
                    shouldScroll = true
                }

                // Check Right Edge
                if cursorFrameInScreen.maxX > viewBounds.width - margin {
                    let diff = cursorFrameInScreen.maxX - (viewBounds.width - margin)
                    targetOffsetX += diff
                    shouldScroll = true
                }

                // Check Top Edge
                if cursorFrameInScreen.minY < margin {
                    let diff = margin - cursorFrameInScreen.minY
                    targetOffsetY -= diff
                    shouldScroll = true
                }

                // Check Bottom Edge
                // If keyboard is visible, the "bottom" is the top of the keyboard.
                let bottomInset = keyboardVisible ? keyboardHeight : 0.0
                let effectiveViewHeight = viewBounds.height - bottomInset

                if cursorFrameInScreen.maxY > effectiveViewHeight - margin {
                    let diff = cursorFrameInScreen.maxY - (effectiveViewHeight - margin)
                    targetOffsetY += diff
                    shouldScroll = true
                }

                if shouldScroll {
                    // Clamp to valid scroll range
                    // Including contentInset.bottom in calculation to allow scrolling past the original content size
                    let maxOffsetX = max(0, scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
                    let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)

                    targetOffsetX = max(-scrollView.contentInset.left, min(targetOffsetX, maxOffsetX))
                    targetOffsetY = max(-scrollView.contentInset.top, min(targetOffsetY, maxOffsetY))

                    // Use a slightly smoother animation or immediate update? 
                    // 'updateImage' might be called frequently. animated: true might stack animations.
                    // For direct control, 'animated: false' is often snappier and prevents lag, 
                    // but 'true' is smoother visually. User asked for "image moves as mouse moves".
                    // Given high frequency, false is safer, or manual interpolation.
                    // Actually, standard UIScrollView behavior is usually direct setContentOffset.
                    scrollView.setContentOffset(CGPoint(x: targetOffsetX, y: targetOffsetY), animated: false)
                }
			}

		} else {
			u?.image = nil
		}
	}

	override func viewDidLoad() {
		// ScrollView Setup
		scrollView = UIScrollView(frame: view.bounds)
		scrollView.delegate = self
		scrollView.minimumZoomScale = 1.0
		scrollView.maximumZoomScale = 5.0
		scrollView.bouncesZoom = true
		scrollView.decelerationRate = .fast
		scrollView.isDirectionalLockEnabled = true
		scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		// The scroll view only zooms. Two fingers always scroll the host, so its
		// own pan is off; when zoomed, the viewport follows the cursor and a
		// three-finger drag pans it (see TouchGestureClassifier).
		scrollView.panGestureRecognizer.isEnabled = false
		view.addSubview(scrollView)

        // ContentView
		contentView = UIView(frame: view.bounds)
		scrollView.addSubview(contentView)
		scrollView.contentSize = view.bounds.size

        // Initialize GLKView
		glkView.viewDidLoad()

		// Move GLKView to ContentView
		// glkView.viewDidLoad() adds the view to 'view', we need to move it.
		if let parsecGLK = glkView as? ParsecGLKViewController {
			parsecGLK.glkView.removeFromSuperview()
			contentView.addSubview(parsecGLK.glkView)
		} else if let parsecMetal = glkView as? ParsecMetalViewController {
			parsecMetal.metalView.removeFromSuperview()
			contentView.addSubview(parsecMetal.metalView)
		} else {
			// Fallback if type check fails, try to find the last subview added?
			// Assumption: glkView.viewDidLoad() adds a subview.
		}

		if #available(iOS 15.0, *) {
			if let parsecGLK = glkView as? ParsecGLKViewController,
			   let eaglContext = parsecGLK.eaglContext {
				PictureInPictureManager.shared.setup(sourceView: view, glContext: eaglContext, glkViewController: parsecGLK.glkViewController)
			} else if let parsecMetal = glkView as? ParsecMetalViewController,
					  let device = parsecMetal.metalView.device {
				PictureInPictureManager.shared.setup(sourceView: view, metalDevice: device)
			}
		}

		touchController.viewDidLoad()
		gamePadController.viewDidLoad()

		u = UIImageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
		contentView.addSubview(u!) // Add Cursor to ContentView

		setNeedsUpdateOfPrefersPointerLocked()

		let pointerInteraction = UIPointerInteraction(delegate: self)
		view.addInteraction(pointerInteraction)

		view.isMultipleTouchEnabled = true
		view.isUserInteractionEnabled = true

		// One recognizer classifies every finger gesture so taps, pointer
		// movement, drags, scrolling and pinching never fire together.
		// UIScrollView still performs the pinch-zoom and zoomed viewport pan.
		let touchRecognizer = StreamTouchGestureRecognizer(target: nil, action: nil)
		touchRecognizer.delegate = self
		touchRecognizer.onTouches = { [weak self] phase, touches, time in
			self?.handleStreamTouches(phase, touches, at: time)
		}
		touchRecognizer.onAbandon = { [weak self] ids, time in
			guard let self else { return }
			self.perform(self.gestureClassifier.touchesCancelled(ids, at: time))
		}
		view.addGestureRecognizer(touchRecognizer)

		let pencilInteraction = UIPencilInteraction()
		pencilInteraction.delegate = self
		view.addInteraction(pencilInteraction)

		let pencilHover = UIHoverGestureRecognizer(target: self, action: #selector(handlePencilHover(_:)))
		pencilHover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
		view.addGestureRecognizer(pencilHover)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillShow),
			name: UIResponder.keyboardWillShowNotification,
			object: nil
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(keyboardWillHide),
			name: UIResponder.keyboardWillHideNotification,
			object: nil
		)

	}

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		layoutStream(for: size)

		// Rebuild after the transition finishes, when UIWindow safe-area insets
		// reflect the cutout's new edge.
		coordinator.animate(alongsideTransition: nil) { _ in
			self.rebuildKeyboardAccessory()
		}
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		// Also catches size changes that arrive without a transition, such as the
		// first layout or moving between a foldable's cover and inner screens.
		if layoutStream(for: view.bounds.size) {
			rebuildKeyboardAccessory()
		}
	}

	/// Fits the stream, its zoom container and the SDK's frame to `size`.
	/// Returns whether anything changed.
	@discardableResult
	private func layoutStream(for size: CGSize) -> Bool {
		guard size.width > 0, size.height > 0, size != laidOutStreamSize else { return false }
		let isResize = laidOutStreamSize != .zero
		laidOutStreamSize = size

		// Zoom is relative to the old size; start the new one at 1×.
		if scrollView.zoomScale != 1 {
			scrollView.setZoomScale(1, animated: false)
		}
		contentView.frame = CGRect(origin: .zero, size: size)
		scrollView.contentSize = size
		scrollView.contentOffset = .zero
		glkView.updateSize(width: size.width, height: size.height)
		let scale = view.window?.screen.nativeScale ?? traitCollection.displayScale
		CParsec.setFrame(size.width, size.height, scale)
		let screenPixels = view.window.map { "\(Int($0.screen.nativeBounds.width))×\(Int($0.screen.nativeBounds.height)) px screen" } ?? "no window"
		sessionLog.info("Stream \(isResize ? "resized" : "laid out") to \(Int(size.width))×\(Int(size.height)) pt @\(scale)x on \(screenPixels)")
		if isResize {
			onStreamResized?(size, scale)
		}
		return isResize
	}

	private func rebuildKeyboardAccessory() {
		keyboardAccessoriesView = nil
		if keyboardVisible {
			reloadInputViews()
		}
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if let parent = parent {
			parent.setChildForHomeIndicatorAutoHidden(self)
			parent.setChildViewControllerForPointerLock(self)
		}
		if keyboardVisible {
			becomeFirstResponder()
		}
		scrollView.pinchGestureRecognizer?.isEnabled = true
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		if let parent = parent {
			parent.setChildForHomeIndicatorAutoHidden(nil)
			parent.setChildViewControllerForPointerLock(nil)
		}
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
		// Never leave the host with a held button or the local zoom locked.
		perform(gestureClassifier.reset())
		touchController.flushPendingRelease()
		syncHoldTimer()
		cancelRemoteScrollMomentum()
	}
	
	
	private var repeatTimer: Timer?
	private var repeatKeyCode: Int = -1
	private var optCmdRemapActive = false
	private var altKeyHeld = false

	override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key else { continue }

			if let remapped = remappedModifier(for: key.keyCode) {
				CParsec.sendKeyboardMessage(keyCode: remapped, pressed: true)
				continue
			}

			if key.keyCode == .keyboardLeftAlt || key.keyCode == .keyboardRightAlt {
				altKeyHeld = true
			}

			if !isModifierKey(key.keyCode) && (altKeyHeld || key.modifierFlags.contains(.alternate)) {
				if !optCmdRemapActive {
					CParsec.sendKeyboardMessage(keyCode: 226, pressed: false)
					CParsec.sendKeyboardMessage(keyCode: 227, pressed: true)
					optCmdRemapActive = true
				}
				let code = KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode)
				CParsec.sendKeyboardMessage(keyCode: UInt32(code), pressed: true)
				startKeyRepeat(keyCode: code)
				continue
			}

			CParsec.sendKeyboardMessage(event:KeyBoardKeyEvent(input: press.key, isPressBegin: true))

			if !isModifierKey(key.keyCode) {
				startKeyRepeat(keyCode: KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode))
			}
		}
	}

	override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
		for press in presses {
			guard let key = press.key else { continue }

			if let remapped = remappedModifier(for: key.keyCode) {
				CParsec.sendKeyboardMessage(keyCode: remapped, pressed: false)
				continue
			}

			if optCmdRemapActive {
				if key.keyCode == .keyboardLeftAlt || key.keyCode == .keyboardRightAlt {
					altKeyHeld = false
					CParsec.sendKeyboardMessage(keyCode: 227, pressed: false)
					optCmdRemapActive = false
					continue
				}
				if !isModifierKey(key.keyCode) {
					let code = KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode)
					CParsec.sendKeyboardMessage(keyCode: UInt32(code), pressed: false)
					if code == repeatKeyCode { stopKeyRepeat() }
					continue
				}
			}

			if key.keyCode == .keyboardLeftAlt || key.keyCode == .keyboardRightAlt {
				altKeyHeld = false
			}

			CParsec.sendKeyboardMessage(event:KeyBoardKeyEvent(input: press.key, isPressBegin: false))

			let code = KeyCodeTranslators.uiKeyCodeToInt(key: key.keyCode)
			if code == repeatKeyCode {
				stopKeyRepeat()
			}
		}
	}

	private func startKeyRepeat(keyCode: Int) {
		stopKeyRepeat()
		repeatKeyCode = keyCode

		repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
			guard let self = self else { return }
			self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
				guard let self = self else { return }
				CParsec.sendKeyboardMessage(keyCode: UInt32(self.repeatKeyCode), pressed: false)
				CParsec.sendKeyboardMessage(keyCode: UInt32(self.repeatKeyCode), pressed: true)
			}
		}
	}

	private func stopKeyRepeat() {
		repeatTimer?.invalidate()
		repeatTimer = nil
		repeatKeyCode = -1
	}

	private func isModifierKey(_ keyCode: UIKeyboardHIDUsage) -> Bool {
		switch keyCode {
		case .keyboardLeftControl, .keyboardLeftShift, .keyboardLeftAlt, .keyboardLeftGUI,
			 .keyboardRightControl, .keyboardRightShift, .keyboardRightAlt, .keyboardRightGUI,
			 .keyboardCapsLock:
			return true
		default:
			return false
		}
	}

	private func remappedModifier(for keyCode: UIKeyboardHIDUsage) -> UInt32? {
		guard SettingsHandler.swapCommandControl else { return nil }
		switch keyCode {
		case .keyboardLeftGUI: return 224
		case .keyboardRightGUI: return 228
		case .keyboardLeftControl: return 227
		case .keyboardRightControl: return 231
		default: return nil
		}
	}

	@objc func keyboardWillShow(notification: NSNotification) {
		if let keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let height = keyboardFrame.height
			keyboardHeight = height
            keyboardVisible = true

            // Allow scrolling past current bottom to see hidden content
            scrollView.contentInset.bottom = height

            // Automatic scroll up only if mouse is in the bottom half of the screen
            let mouseY = CGFloat(CParsec.mouseInfo.mouseY)
            let screenMidY = view.bounds.height / 2.1

            if mouseY > screenMidY {
                 let maxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + height)
                 let newOffsetY = min(maxOffsetY, scrollView.contentOffset.y + height / 1.25)

                 scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffsetY), animated: true)

            }
		}
		onKeyboardVisibilityChanged?(true)
	}

	@objc func keyboardWillHide(notification: NSNotification) {
		keyboardHeight = 0.0
        keyboardVisible = false

        // Restore inset
        scrollView.contentInset.bottom = 0

        // Transform cleanup (just in case)
        view.transform = .identity

        // Automatic scroll down in landscape mode (reverse of show)
        if view.bounds.width > view.bounds.height {
             // We subtract, but clamp to 0 (or valid range)
			let newOffsetY = max(0, scrollView.contentOffset.y - ((notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height ?? 0.0))
             // Or maybe just clamp to valid range without forcing a subtract?
             // User said "bajar la altura", implying a reverse scroll.
             scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newOffsetY), animated: true)
        }
		onKeyboardVisibilityChanged?(false)
	}

}

extension ParsecViewController: UIGestureRecognizerDelegate {

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		return true
	}

	private func handleStreamTouches(_ phase: StreamTouchGestureRecognizer.Phase, _ touches: Set<UITouch>, at time: TimeInterval) {
		let ids = touches.map { AnyHashable(ObjectIdentifier($0)) }
		let samples = touches.map {
			TouchGestureClassifier.TouchSample(id: AnyHashable(ObjectIdentifier($0)), location: $0.location(in: view))
		}

		switch phase {
		case .began:
			let momentumActive = scrollMomentumTimer != nil
			cancelRemoteScrollMomentum()
			perform(gestureClassifier.touchesBegan(samples, at: time, configuration: gestureConfiguration(interruptsMomentum: momentumActive)))
		case .moved:
			perform(gestureClassifier.touchesMoved(samples, at: time))
		case .ended:
			perform(gestureClassifier.touchesEnded(ids, at: time))
		case .cancelled:
			perform(gestureClassifier.touchesCancelled(ids, at: time))
		}
		syncHoldTimer()
	}

	private func gestureConfiguration(interruptsMomentum: Bool) -> TouchGestureClassifier.Configuration {
		// Settings can change mid-session from the controls sheet.
		mouseSensitivity = Float(SettingsHandler.mouseSensitivity)
		pointerAccelerator.curve = SettingsHandler.pointerAcceleration

		var configuration = TouchGestureClassifier.Configuration()
		configuration.mode = SettingsHandler.cursorMode == .direct ? .direct : .trackpad
		configuration.doubleTapToDrag = SettingsHandler.doubleTapToDrag
		configuration.dragLock = SettingsHandler.dragLock
		switch SettingsHandler.rightClickPosition {
		case .firstFinger: configuration.rightClickAnchor = .firstFinger
		case .middle: configuration.rightClickAnchor = .middle
		case .secondFinger: configuration.rightClickAnchor = .secondFinger
		}
		configuration.viewportPannable = scrollView.zoomScale > 1.01 || (keyboardVisible && scrollView.contentInset.bottom > 0)
		configuration.interruptsMomentum = interruptsMomentum
		return configuration
	}

	private func syncHoldTimer() {
		guard let deadline = gestureClassifier.holdDeadline else {
			holdTimer?.invalidate()
			holdTimer = nil
			scheduledHoldDeadline = nil
			return
		}
		guard deadline != scheduledHoldDeadline else { return }

		holdTimer?.invalidate()
		let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
		let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
			guard let self else { return }
			self.holdTimer = nil
			self.scheduledHoldDeadline = nil
			self.perform(self.gestureClassifier.holdTimerFired(at: ProcessInfo.processInfo.systemUptime))
			self.syncHoldTimer()
		}
		// Common modes keep the timer firing while UIScrollView is tracking.
		RunLoop.main.add(timer, forMode: .common)
		holdTimer = timer
		scheduledHoldDeadline = deadline
	}

	private func perform(_ outputs: [TouchGestureClassifier.Output]) {
		for output in outputs {
			switch output {
			case let .movePointer(dx, dy, dt, accelerate):
				touchController.flushPendingRelease()
				let delta = pointerAccelerator.scale(dx: dx, dy: dy, dt: dt, accelerate: accelerate)
				sendPointerDelta(delta)
			case .movePointerTo(let point):
				touchController.flushPendingRelease()
				let position = contentView.convert(point, from: view)
				CParsec.sendMousePosition(Int32(position.x), Int32(position.y))
			case .press(let button):
				touchController.press(parsecButton(button))
			case .release(let button):
				touchController.release(parsecButton(button))
			case let .click(button, point):
				touchController.click(parsecButton(button), at: point.map { contentView.convert($0, from: view) })
			case let .scroll(dx, dy):
				sendRemoteScroll(delta: CGPoint(x: dx, y: dy))
			case let .scrollEnded(vx, vy):
				startRemoteScrollMomentum(velocity: CGPoint(x: vx, y: vy))
			case .showKeyboard:
				showKeyboard()
			case .cycleDisplay(let direction):
				NotificationCenter.default.post(name: .parsecCycleDisplay, object: nil, userInfo: ["direction": direction])
				UISelectionFeedbackGenerator().selectionChanged()
			case let .panViewport(dx, dy):
				panViewport(by: CGPoint(x: dx, y: dy))
			case .lockViewport(let locked):
				scrollView.pinchGestureRecognizer?.isEnabled = !locked
			case .feedback(.grab):
				UIImpactFeedbackGenerator(style: .medium).impactOccurred()
			case .feedback(.release):
				UIImpactFeedbackGenerator(style: .light).impactOccurred()
			}
		}
		isRemoteDragging = gestureClassifier.isButtonHeld
	}

	/// Moves the zoomed content with the fingers, clamped to the scrollable range.
	private func panViewport(by delta: CGPoint) {
		let inset = scrollView.contentInset
		let maxX = max(-inset.left, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
		let maxY = max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
		let target = CGPoint(
			x: min(max(scrollView.contentOffset.x - delta.x, -inset.left), maxX),
			y: min(max(scrollView.contentOffset.y - delta.y, -inset.top), maxY)
		)
		scrollView.setContentOffset(target, animated: false)
	}

	/// Moves the cursor by a trackpad delta in screen points. Dividing by the zoom
	/// keeps the cursor under the same on-screen finger travel when zoomed in.
	private func sendPointerDelta(_ delta: CGVector) {
		let zoom = Float(max(scrollView.zoomScale, 1))
		accumulatedDeltaX += Float(delta.dx) / zoom * mouseSensitivity
		accumulatedDeltaY += Float(delta.dy) / zoom * mouseSensitivity

		// Send whole pixels and carry the remainder for sub-pixel precision.
		let intDeltaX = Int32(accumulatedDeltaX)
		let intDeltaY = Int32(accumulatedDeltaY)
		if intDeltaX != 0 || intDeltaY != 0 {
			CParsec.sendMouseDelta(intDeltaX, intDeltaY)
			accumulatedDeltaX -= Float(intDeltaX)
			accumulatedDeltaY -= Float(intDeltaY)
		}
	}

	private func parsecButton(_ button: TouchGestureClassifier.MouseButton) -> ParsecMouseButton {
		switch button {
		case .left: return ParsecMouseButton(rawValue: 1)
		case .right: return ParsecMouseButton(rawValue: 3)
		}
	}

	private func sendRemoteScroll(delta: CGPoint) {
		let direction: CGFloat = SettingsHandler.naturalScrolling ? 1 : -1
		let multiplier = 12 * CGFloat(mouseSensitivity) * direction
		let scaled = CGPoint(
			x: delta.x * multiplier + scrollRemainder.x,
			y: delta.y * multiplier + scrollRemainder.y
		)
		let wheelX = Int32(scaled.x.rounded(.towardZero))
		let wheelY = Int32(scaled.y.rounded(.towardZero))
		scrollRemainder = CGPoint(
			x: scaled.x - CGFloat(wheelX),
			y: scaled.y - CGFloat(wheelY)
		)

		if wheelX != 0 || wheelY != 0 {
			CParsec.sendWheelMsg(x: wheelX, y: wheelY)
		}
	}

	private func startRemoteScrollMomentum(velocity: CGPoint) {
		cancelRemoteScrollMomentum()
		guard hypot(velocity.x, velocity.y) > 80 else { return }
		scrollMomentumVelocity = velocity

		scrollMomentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
			guard let self else {
				timer.invalidate()
				return
			}

			self.sendRemoteScroll(delta: CGPoint(
				x: self.scrollMomentumVelocity.x / 60,
				y: self.scrollMomentumVelocity.y / 60
			))
			self.scrollMomentumVelocity.x *= 0.91
			self.scrollMomentumVelocity.y *= 0.91

			if hypot(self.scrollMomentumVelocity.x, self.scrollMomentumVelocity.y) < 24 {
				self.cancelRemoteScrollMomentum()
			}
		}
	}

	private func cancelRemoteScrollMomentum() {
		scrollMomentumTimer?.invalidate()
		scrollMomentumTimer = nil
		scrollMomentumVelocity = .zero
	}

	@objc func handlePencilHover(_ gestureRecognizer: UIHoverGestureRecognizer) {
		guard gestureRecognizer.state == .began || gestureRecognizer.state == .changed else { return }
		let location = contentView.convert(gestureRecognizer.location(in: view), from: view)
		CParsec.sendMousePosition(Int32(location.x), Int32(location.y))
	}

    // UIScrollViewDelegate
	func viewForZooming(in scrollView: UIScrollView) -> UIView? {
		return contentView
	}

	func scrollViewDidZoom(_ scrollView: UIScrollView) {
		let scale = max(scrollView.zoomScale, 1)
		glkView.updateRenderScale(scale)
		onZoomScaleChanged?(scale)

		if let pinch = scrollView.pinchGestureRecognizer,
		   pinch.state == .began || pinch.state == .changed {
			let focus = pinch.location(in: contentView)
			pinchFocusPoint = focus
			CParsec.sendMousePosition(Int32(focus.x), Int32(focus.y))
		}
	}

	func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
		cancelRemoteScrollMomentum()
		gestureClassifier.viewportGestureBegan()
		guard let pinch = scrollView.pinchGestureRecognizer else { return }
		let focus = pinch.location(in: contentView)
		pinchFocusPoint = focus
		CParsec.sendMousePosition(Int32(focus.x), Int32(focus.y))
	}

	func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
		guard let focus = pinchFocusPoint else { return }
		CParsec.sendMousePosition(Int32(focus.x), Int32(focus.y))

		let target = CGPoint(
			x: focus.x * scale - scrollView.bounds.width / 2,
			y: focus.y * scale - scrollView.bounds.height / 2
		)
		let maximum = CGPoint(
			x: max(scrollView.contentSize.width - scrollView.bounds.width, 0),
			y: max(scrollView.contentSize.height - scrollView.bounds.height, 0)
		)
		let clamped = CGPoint(
			x: min(max(target.x, 0), maximum.x),
			y: min(max(target.y, 0), maximum.y)
		)
		scrollView.setContentOffset(clamped, animated: true)
		onZoomScaleChanged?(scale)
	}

	func setZoomEnabled(_ enabled: Bool) {
		// Pinch-to-zoom is a core touch interaction and must remain available.
		// Keep the parameter for compatibility with the session controller API.
		zoomEnabled = true
		scrollView.pinchGestureRecognizer?.isEnabled = true
	}

}

extension ParsecViewController: UIPointerInteractionDelegate {
	func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
		return UIPointerStyle.hidden()
	}

	func pointerInteraction(_ inter: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
		let loc = request.location
		if let iv = view!.hitTest(loc, with: nil) {
			let rect = view!.convert(iv.bounds, from: iv)
			let region = UIPointerRegion(rect: rect, identifier: iv.tag)
			return region
		}
		return nil
	}

}

extension ParsecViewController: UIPencilInteractionDelegate {
	func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
		CParsec.sendMouseClickMessage(ParsecMouseButton(rawValue: 3), true)
		CParsec.sendMouseClickMessage(ParsecMouseButton(rawValue: 3), false)
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}
}

extension Notification.Name {
	static let parsecCycleDisplay = Notification.Name("OpenParsec.CycleDisplay")
}

class KeyboardButton: UIButton {
	let keyText: String
	let isToggleable: Bool
	var isOn = false

	required init(keyText: String, isToggleable: Bool) {
		self.keyText = keyText
		self.isToggleable = isToggleable
		super.init(frame: .zero)
		addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
		addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchDragExit, .touchCancel])

	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	// Add a press-down animation for feedback
	@objc private func handleTouchDown() {
		self.alpha = 0.5
	}

	// Restore to normal state when touch ends
	@objc private func handleTouchUp() {
		UIView.animate(withDuration: 0.2) {
			self.alpha = 1.0
		}
	}
}

// MARK: - Virtual Keyboard
extension ParsecViewController: UIKeyInput, UITextInputTraits {
	var hasText: Bool {
		return true
	}

	var keyboardType: UIKeyboardType {
		get {
			return .asciiCapable
		}
		set {

		}
	}

	override var canBecomeFirstResponder: Bool {
		return true
	}

	func insertText(_ text: String) {
		// iOS may deliver QuickType/autocorrect text as a multi-character
		// insertion. The Parsec input API accepts one HID key at a time.
		for character in text {
			CParsec.sendVirtualKeyboardInput(text: String(character))
		}
	}

	func deleteBackward() {
		CParsec.sendVirtualKeyboardInput(text: "BACKSPACE")
	}

    // copied from moonlight https://github.com/moonlight-stream/moonlight-ios/blob/022352c1667788d8626b659d984a290aa5c25e17/Limelight/Input/StreamView.m#L393
	override var inputAccessoryView: UIView? {

		if let keyboardAccessoriesView {
			return keyboardAccessoriesView
		}
        // Refactored to UIView with autoresizing mask for better landscape support
        // Using frame-based layout for the container to avoid constraint conflicts with keyboard
		let containerView = UIView(frame: CGRect(x: 0, y: 0, width: self.view.bounds.width, height: 94))
        containerView.autoresizingMask = [.flexibleWidth]
        containerView.backgroundColor = .clear

		// Use a simple UIView instead of UIToolbar to avoid constraint conflicts
		let windowInsets = view.window?.safeAreaInsets ?? .zero
		let safeLeft = max(view.safeAreaInsets.left, windowInsets.left, 8)
		let safeRight = max(view.safeAreaInsets.right, windowInsets.right, 8)
		let toolbarBackground = UIView(frame: CGRect(x: 0, y: 50, width: containerView.bounds.width, height: 44))
		toolbarBackground.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
		toolbarBackground.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)

		let scrollView = UIScrollView(frame: CGRect(
			x: safeLeft,
			y: 0,
			width: max(toolbarBackground.bounds.width - safeLeft - safeRight - 70, 120),
			height: 44
		))
		scrollView.autoresizingMask = [.flexibleWidth]
		scrollView.showsHorizontalScrollIndicator = false

		let buttonStackView = UIStackView()
		buttonStackView.axis = .horizontal
		buttonStackView.distribution = .equalSpacing
		buttonStackView.alignment = .center
		buttonStackView.spacing = 8
		buttonStackView.translatesAutoresizingMaskIntoConstraints = false

		let shiftBarButton = createKeyboardButton(displayText: "⇧", keyText: "SHIFT", isToggleable: true)
		let windowsBarButton = createKeyboardButton(displayText: "⌘", keyText: "LGUI", isToggleable: true)
		let tabBarButton = createKeyboardButton(displayText: "⇥", keyText: "TAB", isToggleable: false)
		let escapeBarButton = createKeyboardButton(displayText: "⎋", keyText: "UIKeyInputEscape", isToggleable: false)
		let controlBarButton = createKeyboardButton(displayText: "⌃", keyText: "CONTROL", isToggleable: true)
		let altBarButton = createKeyboardButton(displayText: "⌥", keyText: "LALT", isToggleable: true)
		let deleteBarButton = createKeyboardButton(displayText: "Del", keyText: "DELETE", isToggleable: false)
		let functionButton = createFunctionMenuButton()
		let upButton = createKeyboardButton(displayText: "↑", keyText: "UP", isToggleable: false)
		let downButton = createKeyboardButton(displayText: "↓", keyText: "DOWN", isToggleable: false)
		let leftButton = createKeyboardButton(displayText: "←", keyText: "LEFT", isToggleable: false)
		let rightButton = createKeyboardButton(displayText: "→", keyText: "RIGHT", isToggleable: false)

		let buttons = [tabBarButton, shiftBarButton, controlBarButton, altBarButton, windowsBarButton, escapeBarButton, functionButton, deleteBarButton, upButton, downButton, leftButton, rightButton]

		for button in buttons {
			buttonStackView.addArrangedSubview(button)
		}

		scrollView.addSubview(buttonStackView)

		// Set constraints for the stack view inside the scroll view
		NSLayoutConstraint.activate([
			buttonStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
			buttonStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
			buttonStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
			buttonStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
			buttonStackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
		])

		// Done button with frame-based layout
		let doneButton = UIButton(type: .system)
		doneButton.frame = CGRect(x: toolbarBackground.bounds.width - safeRight - 60, y: 0, width: 60, height: 44)
		doneButton.autoresizingMask = [.flexibleLeftMargin]
		doneButton.setTitle("Done", for: .normal)
		doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

		toolbarBackground.addSubview(scrollView)
		toolbarBackground.addSubview(doneButton)

		containerView.addSubview(toolbarBackground)

		keyboardAccessoriesView = containerView
		return containerView
	}

	func createKeyboardButton(displayText: String, keyText: String, isToggleable: Bool) -> UIButton {
		let button = KeyboardButton(keyText: keyText, isToggleable: isToggleable)

		// Set the image and button properties
		button.setTitle(displayText, for: .normal)
		button.titleLabel?.font = UIFont(name: "System", size: 10.0)
		button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
		button.titleLabel?.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
		if let label = button.titleLabel {
			label.textAlignment = .center
		}
		button.backgroundColor = .black
		button.layer.cornerRadius = 3.0

		button.titleLabel?.contentMode = .scaleAspectFit

		// Set target and action for button
		button.addTarget(target, action: #selector(toolbarButtonClicked(_:)), for: .touchUpInside)

		return button
	}

	func createFunctionMenuButton() -> UIButton {
		let button = UIButton(type: .system)
		button.setTitle("Fn", for: .normal)
		button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
		button.setTitleColor(.white, for: .normal)
		button.backgroundColor = .black
		button.layer.cornerRadius = 6
		button.widthAnchor.constraint(equalToConstant: 40).isActive = true
		button.heightAnchor.constraint(equalToConstant: 36).isActive = true
		button.showsMenuAsPrimaryAction = true
		button.menu = UIMenu(
			title: "Function Keys",
			options: .displayInline,
			children: (1...12).map { number in
				UIAction(title: "F\(number)") { _ in
					CParsec.sendVirtualKeyboardInput(text: "F\(number)")
					UISelectionFeedbackGenerator().selectionChanged()
				}
			}
		)
		return button
	}

	@objc func toolbarButtonClicked(_ sender: KeyboardButton) {
		let isToggleable = sender.isToggleable
		var isOn = sender.isOn

		if isToggleable {
			isOn.toggle()
			if isOn {
				sender.backgroundColor = .lightGray
			} else {
				sender.backgroundColor = .black
			}
		}

		sender.isOn = isOn
		let keyText = sender.keyText

		if isToggleable {
			if isOn {
				CParsec.sendVirtualKeyboardInput(text: keyText, isOn: true)
			} else {
				CParsec.sendVirtualKeyboardInput(text: keyText, isOn: false)
			}
		} else {
			CParsec.sendVirtualKeyboardInput(text: keyText)
		}

	}

	@objc func doneTapped() {
		// Resign first responder to dismiss the keyboard
		resignFirstResponder()
	}

	@objc func showKeyboard() {
		becomeFirstResponder()
	}

	// CRITICAL: This is the robust way to show the keyboard.
    // 1. Dispatch async to ensure view is attached to window.
    // 2. call reloadInputViews() to ensure updated accessory view (especially for rotation).
    // 3. call becomeFirstResponder().
    // 4. Do NOT simplify this to a synchronous call, or it will fail in some race conditions.
	func setKeyboardVisible(_ visible: Bool) {
		keyboardVisible = visible
		if visible {
            DispatchQueue.main.async {
                self.reloadInputViews()
                let success = self.becomeFirstResponder()
                if !success {
                   // Fallback: try again? or just log (can't log).
                   // Maybe ensure user interaction is on on window?
                }
            }
		} else {
			resignFirstResponder()
		}
	}

}
