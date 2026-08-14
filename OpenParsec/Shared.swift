import Foundation
import SwiftUI
import Network

var appScheme: ColorScheme = .dark

struct GLBData {
	let SessionKeyChainKey = "OPStoredAuthData"
}

class GLBDataModel {
	static let shared = GLBData()
}

extension String {
	static func fromBuffer(_ ptr: UnsafeMutablePointer<CChar>, length len: Int) -> String {
		let bytes = UnsafeBufferPointer(start: ptr, count: len)
		let meaningful = bytes.prefix { $0 != 0 }
		return String(decoding: meaningful.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	}
}

class CursorPositionHelper {
	static func toHost(_ xp: Int, _ yp: Int) -> (Int, Int) {
		let xh = CParsec.hostWidth
		let yh = CParsec.hostHeight
		let xc = CParsec.clientWidth
		let yc = CParsec.clientHeight

		let tc = yc / xc
		let th = yh / xh

		var xa: Float
		var ya: Float
		if th < tc {
			xa = Float(xp) * xh / xc
			ya = (Float(yp) - 0.5 * (yc - xc*th)) * xh / xc
		} else {
			ya = Float(yp) * yh / yc
			xa = (Float(xp) - 0.5 * (xc - yc/th)) * yh / yc
		}

		return (Int(ParsecSDKBridge.clamp(xa, minValue: 0, maxValue: CParsec.hostWidth)), Int(ParsecSDKBridge.clamp(ya, minValue: 0, maxValue: CParsec.hostHeight)))
	}

	static func toClient(_ xa: Int, _ ya: Int) -> (Int, Int) {
		let xh = CParsec.hostWidth
		let yh = CParsec.hostHeight
		let xc = CParsec.clientWidth
		let yc = CParsec.clientHeight

		let tc = yc / xc
		let th = yh / xh

		var xp: Float
		var yp: Float
		if th < tc {
			xp = Float(xa) * xc / xh
			yp = Float(ya) * xc / xh + 0.5 * (yc - xc*th)
		} else {
			yp = Float(ya) * yc / yh
			xp = Float(xa) * yc / yh + 0.5 * (xc - yc/th)
		}

		return (Int(ParsecSDKBridge.clamp(xp, minValue: 0, maxValue: CParsec.clientWidth)), Int(ParsecSDKBridge.clamp(yp, minValue: 0, maxValue: CParsec.clientHeight)))
	}
}

class SharedModel: ObservableObject {
	@Published var resolutionX = 0
	@Published var resolutionY = 0
	@Published var bitrate = 0
	@Published var constantFps = false
	@Published var output = "none"
	@Published var displayConfigs: [ParsecDisplayConfig] = []

}

class DataManager {
	static let model = SharedModel()
}

enum DiagnosticSeverity: Int, Comparable {
	case healthy
	case notice
	case warning
	case critical

	static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

struct SessionDiagnostic: Identifiable {
	let id: String
	let title: String
	let detail: String
	let systemImage: String
	let severity: DiagnosticSeverity
}

final class SessionDiagnostics: ObservableObject {
	static let shared = SessionDiagnostics()

	@Published var decodeLatency: Double = 0
	@Published var encodeLatency: Double = 0
	@Published var networkLatency: Double = 0
	@Published var bitrate: Double = 0
	@Published var codec = "—"
	@Published var resolution = "—"
	@Published var chroma = "—"
	@Published var decoder = "—"
	@Published var issues: [SessionDiagnostic] = []

	private init() {}

	func update(
		decode: Double,
		encode: Double,
		network: Double,
		bitrate: Double,
		codec: String,
		resolution: String,
		chroma: String,
		decoder: String
	) {
		decodeLatency = decode
		encodeLatency = encode
		networkLatency = network
		self.bitrate = bitrate
		self.codec = codec
		self.resolution = resolution
		self.chroma = chroma
		self.decoder = decoder

		var newIssues: [SessionDiagnostic] = []
		if network > 80 {
			newIssues.append(.init(id: "network", title: "Network delay", detail: "\(Int(network)) ms — reduce bitrate or use Wi‑Fi/Ethernet.", systemImage: "wifi.exclamationmark", severity: .critical))
		} else if network > 40 {
			newIssues.append(.init(id: "network", title: "Network delay", detail: "\(Int(network)) ms — responsiveness may feel soft.", systemImage: "wifi.exclamationmark", severity: .warning))
		}
		if encode > 16 {
			newIssues.append(.init(id: "encode", title: "Host encoding is slow", detail: "\(encode.formatted(.number.precision(.fractionLength(1)))) ms — lower host resolution or FPS.", systemImage: "desktopcomputer.trianglebadge.exclamationmark", severity: .warning))
		}
		if decode > 12 {
			newIssues.append(.init(id: "decode", title: "Device decoding is slow", detail: "\(decode.formatted(.number.precision(.fractionLength(1)))) ms — lower resolution or use H.264.", systemImage: "iphone.gen3.radiowaves.left.and.right", severity: .warning))
		}
		issues = newIssues
	}

	var overallSeverity: DiagnosticSeverity {
		issues.map(\.severity).max() ?? .healthy
	}
}

final class SessionContext: ObservableObject {
	static let shared = SessionContext()
	@Published var peerID: String?
	@Published var hostName: String?
	@Published var pendingConnectionURL: URL?

	private init() {}
}

final class ConnectivityMonitor: ObservableObject {
	static let shared = ConnectivityMonitor()

	@Published private(set) var isOnline = true
	@Published private(set) var isExpensive = false
	@Published private(set) var interfaceName = "Network"

	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "OpenParsec.Connectivity")

	private init() {
		monitor.pathUpdateHandler = { [weak self] path in
			DispatchQueue.main.async {
				self?.isOnline = path.status == .satisfied
				self?.isExpensive = path.isExpensive
				if path.usesInterfaceType(.wifi) {
					self?.interfaceName = "Wi‑Fi"
				} else if path.usesInterfaceType(.cellular) {
					self?.interfaceName = "Cellular"
				} else if path.usesInterfaceType(.wiredEthernet) {
					self?.interfaceName = "Ethernet"
				} else {
					self?.interfaceName = "Network"
				}
			}
		}
		monitor.start(queue: queue)
	}
}
