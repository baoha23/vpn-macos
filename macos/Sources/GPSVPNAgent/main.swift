import AppKit
import Combine
import CoreLocation
import Foundation
import Network
import Security

struct LocationPayload: Encodable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let altitudeMeters: Double?
    let source: String
    let capturedAt: String
}

struct HealthResponse: Encodable {
    let status: String
    let locationReady: Bool
}

struct ErrorResponse: Encodable {
    let error: String
    let message: String?

    init(error: String, message: String? = nil) {
        self.error = error
        self.message = message
    }
}

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var statusText = "Waiting for location permission"

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var latestLatitude: Double?
    private var latestLongitude: Double?
    private var latestAccuracy: Double?
    private var latestAltitude: Double?
    private var latestCapturedAt = Date()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    var isReady: Bool {
        currentPayload() != nil
    }

    var manualCoordinatesDescription: String {
        let defaults = UserDefaults.standard
        guard let latitude = defaults.object(forKey: "manualLatitude") as? Double,
              let longitude = defaults.object(forKey: "manualLongitude") as? Double else {
            return "Not set"
        }
        return String(format: "%.6f, %.6f", latitude, longitude)
    }

    func setManualCoordinates(latitude: Double, longitude: Double) {
        let defaults = UserDefaults.standard
        defaults.set(latitude, forKey: "manualLatitude")
        defaults.set(longitude, forKey: "manualLongitude")
        defaults.set(Date().timeIntervalSince1970, forKey: "manualCapturedAt")
        DispatchQueue.main.async { [weak self] in
            self?.statusText = "Using manual coordinates"
        }
    }

    func clearManualCoordinates() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "manualLatitude")
        defaults.removeObject(forKey: "manualLongitude")
        defaults.removeObject(forKey: "manualCapturedAt")
        DispatchQueue.main.async { [weak self] in
            self?.statusText = "Waiting for Mac location"
        }
    }

    func currentPayload() -> LocationPayload? {
        let defaults = UserDefaults.standard
        let formatter = ISO8601DateFormatter()
        if let latitude = defaults.object(forKey: "manualLatitude") as? Double,
           let longitude = defaults.object(forKey: "manualLongitude") as? Double {
            let capturedAt = (defaults.object(forKey: "manualCapturedAt") as? Double)?
                .map { Date(timeIntervalSince1970: $0) } ?? Date()
            return LocationPayload(
                latitude: latitude,
                longitude: longitude,
                accuracyMeters: 10,
                altitudeMeters: nil,
                source: "manual_override",
                capturedAt: formatter.string(from: capturedAt)
            )
        }

        lock.lock()
        defer { lock.unlock() }
        guard let latitude = latestLatitude,
              let longitude = latestLongitude else {
            return nil
        }
        return LocationPayload(
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: latestAccuracy ?? 200,
            altitudeMeters: latestAltitude,
            source: "core_location",
            capturedAt: formatter.string(from: latestCapturedAt)
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self?.statusText = "Locating Mac"
            case .denied, .restricted:
                self?.statusText = "Location permission denied"
            case .notDetermined:
                self?.statusText = "Waiting for location permission"
            @unknown default:
                self?.statusText = "Unknown location permission"
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        lock.lock()
        latestLatitude = location.coordinate.latitude
        latestLongitude = location.coordinate.longitude
        latestAccuracy = location.horizontalAccuracy
        latestAltitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        latestCapturedAt = location.timestamp
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.statusText = String(
                format: "Mac location: %.5f, %.5f (±%.0f m)",
                location.coordinate.latitude,
                location.coordinate.longitude,
                location.horizontalAccuracy
            )
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.statusText = "Location error: \(error.localizedDescription)"
        }
    }
}

enum APIKey {
    private static let service = "local.gps-vpn.agent"
    private static let account = "api"

    static func loadOrCreate() -> String {
        if let existing = read() {
            return existing
        }
        let token = generate()
        save(token)
        return token
    }

    private static func generate() -> String {
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { pointer -> OSStatus in
            guard let baseAddress = pointer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, pointer.count, baseAddress)
        }
        precondition(result == errSecSuccess)
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func read() -> String? {
        var query = self.query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ token: String) {
        var attributes = query()
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

final class HTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.gps-vpn.agent.http")
    private let token: String
    private let provider: LocationProvider
    private let formatter = ISO8601DateFormatter()

    init(port: UInt16, token: String, provider: LocationProvider) throws {
        self.token = token
        self.provider = provider
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw URLError(.badURL)
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpointPort)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("GPSVPN HTTP server failed: \(error)")
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data {
                self.handle(connection, data: data)
            }
            if error == nil && !isComplete {
                self.receive(connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ connection: NWConnection, data: Data) {
        let requestText = String(decoding: data.prefix(16 * 1024), as: UTF8.self)
        let requestLine = requestText.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(connection, status: "400 Bad Request", body: ["error": "bad_request"])
            return
        }

        let path = String(parts[1])
        switch path {
        case "/v1/health":
            send(connection, status: "200 OK", body: HealthResponse(status: "ok", locationReady: provider.isReady))
        case "/v1/location":
            guard authorized(requestText) else {
                send(connection, status: "401 Unauthorized", body: ErrorResponse(error: "unauthorized"))
                return
            }
            guard let payload = provider.currentPayload() else {
                send(connection, status: "503 Service Unavailable", body: ErrorResponse(error: "location_unavailable", message: provider.statusText))
                return
            }
            send(connection, status: "200 OK", body: payload)
        default:
            send(connection, status: "404 Not Found", body: ErrorResponse(error: "not_found"))
        }
    }

    private func authorized(_ requestText: String) -> Bool {
        let expected = "Bearer \(token)"
        return requestText
            .split(separator: "\r\n")
            .map(String.init)
            .first { $0.lowercased().hasPrefix("authorization:") }?
            .dropFirst("authorization:".count)
            .trimmingCharacters(in: .whitespaces) == expected
    }

    private func send(_ connection: NWConnection, status: String, body: Encodable) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(AnyEncodable(body))
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(encoded.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + encoded, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeFunction: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeFunction = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunction(encoder)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let provider: LocationProvider
    private let token: String
    private var statusItem: NSStatusItem?

    init(provider: LocationProvider, token: String) {
        self.provider = provider
        self.token = token
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "📍"
        let menu = NSMenu()
        let status = NSMenuItem(title: "Location: loading", action: nil, keyEquivalent: "")
        let manual = NSMenuItem(title: "Manual coordinates: \(provider.manualCoordinatesDescription)", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(manual)
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy endpoint", action: #selector(copyEndpoint), object: "http://127.0.0.1:8787"))
        menu.addItem(menuItem("Copy API token", action: #selector(copyText(_:)), object: token))
        menu.addItem(menuItem("Set manual coordinates", action: #selector(setManualCoordinates)))
        menu.addItem(menuItem("Clear manual coordinates", action: #selector(clearManualCoordinates)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", action: #selector(NSApplication.terminate(_:))))
        item.menu = menu
        statusItem = item

        provider.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                status.title = "Location: \(value)"
                manual.title = "Manual coordinates: \(self?.provider.manualCoordinatesDescription ?? "Not set")"
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func menuItem(_ title: String, action: Selector, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        return item
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func copyEndpoint(_ sender: NSMenuItem) {
        copyText(sender)
    }

    @objc private func setManualCoordinates() {
        let alert = NSAlert()
        alert.messageText = "Manual coordinates"
        alert.informativeText = "Use decimal degrees. Leave empty to keep current values."
        let stack = NSStackView()
        stack.orientation = .vertical
        let latitudeField = NSTextField(string: (UserDefaults.standard.object(forKey: "manualLatitude") as? Double).map { String($0) } ?? "")
        let longitudeField = NSTextField(string: (UserDefaults.standard.object(forKey: "manualLongitude") as? Double).map { String($0) } ?? "")
        latitudeField.placeholderString = "Latitude"
        longitudeField.placeholderString = "Longitude"
        latitudeField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        longitudeField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        stack.addArrangedSubview(latitudeField)
        stack.addArrangedSubview(longitudeField)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let currentLatitude = UserDefaults.standard.object(forKey: "manualLatitude") as? Double
        let currentLongitude = UserDefaults.standard.object(forKey: "manualLongitude") as? Double
        guard let latitude = Double(latitudeField.stringValue) ?? currentLatitude,
              let longitude = Double(longitudeField.stringValue) ?? currentLongitude,
              abs(latitude) <= 90,
              abs(longitude) <= 180 else {
            let invalidAlert = NSAlert()
            invalidAlert.messageText = "Invalid coordinates"
            invalidAlert.informativeText = "Latitude must be -90 through 90 and longitude must be -180 through 180."
            invalidAlert.runModal()
            return
        }
        provider.setManualCoordinates(latitude: latitude, longitude: longitude)
    }

    @objc private func clearManualCoordinates() {
        provider.clearManualCoordinates()
    }
}

let provider = LocationProvider()
let token = APIKey.loadOrCreate()

do {
    let server = try HTTPServer(port: 8787, token: token, provider: provider)
    server.start()
    let delegate = AppDelegate(provider: provider, token: token)
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
} catch {
    let alert = NSAlert()
    alert.messageText = "GPSVPN Agent failed to start"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    exit(1)
}
