import MetalKit
import UIKit

final class ParsecMetalViewController: ParsecPlayground {
	private unowned let viewController: UIViewController
	private let updateImage: () -> Void
	private(set) var metalView: MTKView!
	private var renderer: ParsecMetalRenderer?

	required init(viewController: UIViewController, updateImage: @escaping () -> Void) {
		self.viewController = viewController
		self.updateImage = updateImage
	}

	func viewDidLoad() {
		guard let device = MTLCreateSystemDefaultDevice() else { return }
		let view = MTKView(frame: viewController.view.bounds, device: device)
		view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.colorPixelFormat = .bgra8Unorm
		view.framebufferOnly = false
		view.enableSetNeedsDisplay = false
		view.isPaused = false
		view.preferredFramesPerSecond = SettingsHandler.preferredFramesPerSecond == 0
			? viewController.view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
			: SettingsHandler.preferredFramesPerSecond

		let renderer = ParsecMetalRenderer(view: view, updateImage: updateImage)
		view.delegate = renderer
		self.renderer = renderer
		self.metalView = view
		viewController.view.addSubview(view)
	}

	func cleanUp() {
		metalView?.isPaused = true
		metalView?.delegate = nil
		renderer = nil
	}

	func updateSize(width: CGFloat, height: CGFloat) {
		metalView?.frame.size = CGSize(width: width, height: height)
		metalView?.drawableSize = CGSize(
			width: width * (metalView?.contentScaleFactor ?? 1),
			height: height * (metalView?.contentScaleFactor ?? 1)
		)
	}

	func updateRenderScale(_ zoomScale: CGFloat) {
		guard let metalView else { return }
		let screenScale = viewController.view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
		let detailScale = min(max(zoomScale, 1), 3)
		metalView.drawableSize = CGSize(
			width: metalView.bounds.width * screenScale * detailScale,
			height: metalView.bounds.height * screenScale * detailScale
		)
		CParsec.setFrame(metalView.bounds.width, metalView.bounds.height, screenScale * detailScale)
	}
}
