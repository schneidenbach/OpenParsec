import SwiftUI

enum ViewType {
	case login
	case main
	case parsec
	case test

	/// Navigation depth: moving to a deeper screen pushes, moving up pops.
	var depth: Int {
		switch self {
		case .login: return 0
		case .main, .test: return 1
		case .parsec: return 2
		}
	}
}

struct ContentView: View {
	@State var curView: ViewType = .login
	@State private var isNavigatingBack = false

	/// Push slides the new screen in from the trailing edge; pop reverses it so
	/// returning from a session reads as going back, not deeper.
	private var pageTransition: AnyTransition {
		.asymmetric(
			insertion: .move(edge: isNavigatingBack ? .leading : .trailing),
			removal: .move(edge: isNavigatingBack ? .trailing : .leading)
		)
	}

	var body: some View {
		ZStack {
			switch curView {
			case .login:
				LoginView(self)
					.transition(pageTransition)
			case .main:
				MainView(self)
					.transition(pageTransition)
			case .parsec:
				ParsecView(self)
					.transition(pageTransition)
			case .test:
				TestView(self)
					.transition(pageTransition)
			}
		}
		.onAppear(perform: initApp)
		.onOpenURL { url in
			SessionContext.shared.pendingConnectionURL = url
			if NetworkHandler.clinfo != nil {
				setView(.main)
			}
		}
		.background(Rectangle().fill(Color.black).edgesIgnoringSafeArea(.all))
	}

	func initApp() {

		// Check to see if we have old session data
		if let data = loadFromKeychain(key: GLBDataModel.shared.SessionKeyChainKey) {
			let decoder = JSONDecoder()

			print("Retrieved data from keychain: \(data).\nTrying to restore session.")
			NetworkHandler.clinfo = try? decoder.decode(ClientInfo.self, from: data)
			if NetworkHandler.clinfo != nil {
				curView = .main
				print("Session restored and moved to the main page.")
			} else {
				print("Unable to restore session, falling back to login page.")
			}
		}

		print("Initialized")
	}

	func loadFromKeychain(key: String) -> Data? {
		let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecReturnData as String: kCFBooleanTrue!, kSecMatchLimit as String: kSecMatchLimitOne]
		var item: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &item)
		guard status == errSecSuccess else {
			if status != errSecItemNotFound {
				print("Error loading from keychain: \(status)")
			}
			return nil
		}
		guard let data = item as? Data else {
			return nil
		}
		return data
	}

	public func setView(_ t: ViewType) {
		guard t != curView else { return }
		// SwiftUI animates a removed view with the transition from its last
		// render, so commit the direction before switching screens.
		isNavigatingBack = t.depth < curView.depth
		DispatchQueue.main.async {
			withAnimation(.easeInOut(duration: 0.32)) { curView = t }
		}
	}
}

struct ContentView_Previews: PreviewProvider {
	static var previews: some View {
		ContentView()
	}
}
