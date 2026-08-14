// import SwiftUI
// import GLKit
//
// struct ParsecGLKViewController: UIViewControllerRepresentable
// {
//	let glkView = GLKView()
//	let glkViewController = GLKViewController()
//	let onBeforeRender:() -> Void
//
//	func makeCoordinator() -> ParsecGLKRenderer
//	{
//		ParsecGLKRenderer(glkView, glkViewController, onBeforeRender)
//	}
//
//	func makeUIViewController(context: UIViewControllerRepresentableContext<ParsecGLKViewController>) -> GLKViewController
//	{
//		glkView.context = EAGLContext(api:.openGLES3)!
//		glkViewController.view = glkView
//		glkViewController.preferredFramesPerSecond = 60
//		return glkViewController
//	}
//
//	func updateUIViewController(_ uiViewController:GLKViewController, context: UIViewControllerRepresentableContext<ParsecGLKViewController>) { }
// }

import UIKit
import GLKit

class ParsecGLKViewController: ParsecPlayground {

	var glkView: GLKView!
	let glkViewController = GLKViewController()
	var glkRenderer: ParsecGLKRenderer!
	let updateImage: () -> Void

	let viewController: UIViewController
	private var baseContentScale: CGFloat = UIScreen.main.nativeScale

	required init(viewController: UIViewController, updateImage: @escaping () -> Void) {
		self.viewController = viewController
		self.updateImage = updateImage
	}

	public func viewDidLoad() {
		glkView = GLKView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height))
		baseContentScale = viewController.view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
		glkView.contentScaleFactor = baseContentScale
		glkRenderer = ParsecGLKRenderer(glkView, glkViewController, updateImage)
		self.viewController.view.addSubview(glkView)
		setupGLKViewController()

	}

	private func setupGLKViewController() {
		glkView.context = EAGLContext(api: .openGLES3)!
		glkViewController.view = glkView

		// Use configured FPS or device max (for ProMotion displays)
		let fps = SettingsHandler.preferredFramesPerSecond
		if fps == 0 {
			// Use device's maximum refresh rate (120Hz on ProMotion iPads)
			glkViewController.preferredFramesPerSecond = Int(UIScreen.main.maximumFramesPerSecond)
		} else {
			glkViewController.preferredFramesPerSecond = fps
		}

		self.viewController.addChild(glkViewController)
		self.viewController.view.addSubview(glkViewController.view)
		self.glkViewController.didMove(toParent: self.viewController)
	}

	var eaglContext: EAGLContext? {
		return glkView?.context
	}

	func cleanUp() {

	}

	func updateSize(width: CGFloat, height: CGFloat) {
		glkView.frame.size.width = width
		glkView.frame.size.height = height
	}

	func updateRenderScale(_ zoomScale: CGFloat) {
		guard glkView != nil else { return }
		let detailScale = min(max(zoomScale, 1), 3)
		let newScale = baseContentScale * detailScale
		guard abs(glkView.contentScaleFactor - newScale) > 0.05 else { return }
		glkView.contentScaleFactor = newScale
		CParsec.setFrame(glkView.bounds.width, glkView.bounds.height, newScale)
		glkView.setNeedsDisplay()
	}

}
