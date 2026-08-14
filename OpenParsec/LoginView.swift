import SwiftUI
import os

struct LoginView: View {
	var controller: ContentView?

	@State var inputEmail: String = ""
	@State var inputPassword: String = ""
	@State var inputTFA: String = ""
	@State var isTFAOn: Bool = false
	@State private var presentTFAAlert = false
	@State var isLoading: Bool = false
	@State var showAlert: Bool = false
	@State var alertText: String = ""
	@FocusState private var focusedField: LoginField?

	init(_ controller: ContentView?) {
		self.controller = controller
	}

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(spacing: 28) {
					VStack(spacing: 14) {
						Image("IconTransparent")
							.resizable()
							.scaledToFit()
							.frame(width: 82, height: 82)
							.padding(18)
							.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
							.shadow(color: .black.opacity(0.18), radius: 24, y: 12)

						Text("OpenParsec")
							.font(.largeTitle.bold())

						Text("Your computers, wherever you are.")
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
					.padding(.top, 36)

					VStack(spacing: 14) {
						TextField("Email", text: $inputEmail)
							.textContentType(.emailAddress)
							.keyboardType(.emailAddress)
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()
							.submitLabel(.next)
							.focused($focusedField, equals: .email)
							.onSubmit { focusedField = .password }

						SecureField("Password", text: $inputPassword)
							.textContentType(.password)
							.submitLabel(.go)
							.focused($focusedField, equals: .password)
							.onSubmit(signIn)
					}
					.textFieldStyle(.roundedBorder)
					.font(.body)

					Button(action: signIn) {
						HStack(spacing: 10) {
							if isLoading {
								ProgressView()
									.tint(.white)
							}
							Text(isLoading ? "Signing In…" : "Sign In")
								.fontWeight(.semibold)
						}
						.frame(maxWidth: .infinity)
						.frame(height: 52)
					}
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
					.disabled(isLoading || inputEmail.isEmpty || inputPassword.isEmpty)

					Text("OpenParsec is an independent, open-source client.")
						.font(.footnote)
						.foregroundStyle(.tertiary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: 440)
				.padding(.horizontal, 24)
				.frame(maxWidth: .infinity)
			}
			.scrollDismissesKeyboard(.interactively)
			.background {
				LinearGradient(
					colors: [
						Color.accentColor.opacity(0.18),
						Color(uiColor: .systemBackground),
						Color(uiColor: .systemBackground)
					],
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				)
				.ignoresSafeArea()
			}
		}
		.disabled(isLoading)
		.sheet(isPresented: $presentTFAAlert) {
			NavigationStack {
				Form {
					Section {
						SecureField("Verification code", text: $inputTFA)
							.keyboardType(.numberPad)
							.textContentType(.oneTimeCode)
							.focused($focusedField, equals: .twoFactor)
					} footer: {
						Text("Enter the code from your authenticator app.")
					}
				}
				.navigationTitle("Two-Factor Authentication")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button("Cancel") { presentTFAAlert = false }
					}
					ToolbarItem(placement: .confirmationAction) {
						Button("Verify") { authenticate(inputTFA) }
							.fontWeight(.semibold)
							.disabled(inputTFA.isEmpty)
					}
				}
				.onAppear { focusedField = .twoFactor }
			}
			.presentationDetents([.medium])
		}
		.alert(isPresented: $showAlert) {
			Alert(title: Text("Login Failed"), message: Text(alertText))
		}
	}

	private func signIn() {
		guard !inputEmail.isEmpty, !inputPassword.isEmpty, !isLoading else { return }
		focusedField = nil
		authenticate()
	}

	func saveToKeychain(data: Data, key: String) {
		let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key, kSecValueData as String: data]
		let status = SecItemAdd(query as CFDictionary, nil)
		guard status == errSecSuccess else {
			print("Error saving to Keychain: \(status)")
			return
		}
		print("Data saved to Keychain.")
	}

	func authenticate(_ tfa: String? = "") {
		#if DEBUG
		if inputEmail == "test@example.com" { // skip authentication (DEBUG ONLY)
			if let c = controller {
				c.setView(.main)
			}
			return
		}
		#endif

		withAnimation { isLoading = true }

		let apiURL = URL(string: "https://kessel-api.parsec.app/v1/auth")!

		var request = URLRequest(url: apiURL)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")
		request.httpBody = try? JSONSerialization.data(withJSONObject:
		[
			"email": inputEmail,
			"password": inputPassword,
			"tfa": tfa
		], options: [])

		let task = URLSession.shared.dataTask(with: request) { (data, response, _) in
			DispatchQueue.main.async {
				isLoading = false
				if let data = data {
					guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { return }
					let decoder = JSONDecoder()

					print("Login Information:")
					print(statusCode)
					print(String(data: data, encoding: .utf8)!)

					if statusCode == 201 { // 201 Created
						// store it and recover it from the next app opening, so people won't swear
						NetworkHandler.clinfo = try? decoder.decode(ClientInfo.self, from: data)

						saveToKeychain(data: data, key: GLBDataModel.shared.SessionKeyChainKey)

						if let c = controller {
							print("*** Login succeeded! ***")
							c.setView(.main)
						}
					} else if statusCode >= 400 { // 4XX client errors
						guard let info: ErrorInfo = try? decoder.decode(ErrorInfo.self, from: data) else { return }

						do {
							let json = try JSONSerialization.jsonObject(with: data, options: [])
							if let dict = json as? [String: Any], let isTFARequired = dict["tfa_required"] as? Bool {
								print("Code output:")
								print(dict)
								if isTFARequired {
									presentTFAAlert = true
								} else {
									alertText = "Error: \(info)"
									showAlert = true
								}
							} else {
								alertText = info.error
								showAlert = true
							}
						} catch {
							print("Error on trying JSON Serialization on error data!")
						}
					}
				}
			}
		}
		task.resume()
	}
}

private enum LoginField {
	case email
	case password
	case twoFactor
}

struct LoginView_Previews: PreviewProvider {
	static var previews: some View {
		LoginView(nil)
	}
}
