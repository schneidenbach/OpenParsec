import MetalKit

final class ParsecMetalRenderer: NSObject, MTKViewDelegate {
	private let commandQueue: MTLCommandQueue
	private let updateImage: () -> Void
	private var lastDrawableSize: CGSize = .zero

	init?(view: MTKView, updateImage: @escaping () -> Void) {
		guard let device = view.device,
			  let commandQueue = device.makeCommandQueue() else {
			return nil
		}
		self.commandQueue = commandQueue
		self.updateImage = updateImage
		super.init()
	}

	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
		updateDimensions(for: view)
	}

	func draw(in view: MTKView) {
		guard let drawable = view.currentDrawable else { return }
		let texture = drawable.texture
		updateDimensions(for: view)

		let fps = SettingsHandler.preferredFramesPerSecond == 0
			? view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
			: SettingsHandler.preferredFramesPerSecond
		let timeout = UInt32(max(1000 / max(fps, 1), 8))
		CParsec.renderMetalFrame(commandQueue: commandQueue, target: texture, timeout: timeout)
		StreamVideoPauser.shared.frameDrawn()

		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.captureMetalFrame(
				sourceTexture: texture,
				commandQueue: commandQueue,
				streamWidth: Int(CParsec.hostWidth),
				streamHeight: Int(CParsec.hostHeight)
			)
		}
		if let presentationBuffer = commandQueue.makeCommandBuffer() {
			presentationBuffer.present(drawable)
			presentationBuffer.commit()
		}
		updateImage()
	}

	private func updateDimensions(for view: MTKView) {
		guard view.drawableSize != lastDrawableSize else { return }
		lastDrawableSize = view.drawableSize
		CParsec.setFrame(view.bounds.width, view.bounds.height, view.contentScaleFactor)
	}
}
