import Foundation
import AVFoundation
import AudioToolbox

// =============================================================
// APP LOGGER (Hiển thị log trực tiếp lên màn hình app)
// =============================================================

final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    @Published var logs: [String] = []

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        print(line)
        DispatchQueue.main.async {
            self.logs.append(line)
            if self.logs.count > 40 {
                self.logs.removeFirst()
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
}

// =============================================================
// NETWORK & AUDIO MANAGER
// =============================================================

final class NetworkManager: NSObject {

    static let shared = NetworkManager()

    // =========================================================
    // URLSession & WebSocket
    // =========================================================

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?

    // =========================================================
    // DEFAULT SERVER & TOKEN
    // =========================================================

    private let defaultServerIP = "192.168.0.104"
    private let defaultServerPort = 3000
    private let defaultToken =
        ""

    // =========================================================
    // SERVER CONFIG
    // =========================================================

    private(set) var serverIP: String
    private(set) var serverPort: Int
    private(set) var token: String

    // =========================================================
    // CONNECTION STATE
    // =========================================================

    private var manualDisconnect = false
    private var reconnectWorkItem: DispatchWorkItem?

    private(set) var isConnected = false
    private(set) var isConnecting = false

    // =========================================================
    // AUDIO STREAMING (CoreAudio AudioQueue)
    // =========================================================

    private var audioQueue: AudioQueueRef?
    private var isAudioQueueRunning = false
    private var audioSampleRate: Double = 44100

    private var beepPlayer: AVAudioPlayer?
    private var avPlayer: AVPlayer?

    private var totalPacketsHandled = 0

    // =========================================================
    // INIT
    // =========================================================

    private override init() {
        let savedIP = UserDefaults.standard.string(forKey: "listenerServerIP")
        let savedPort = UserDefaults.standard.object(forKey: "listenerServerPort") as? Int
        let savedToken = UserDefaults.standard.string(forKey: "listenerAuthToken")

        self.serverIP = savedIP ?? defaultServerIP
        self.serverPort = savedPort ?? defaultServerPort
        self.token = savedToken ?? defaultToken

        super.init()

        setupAudioSession()
        setupInterruptionHandling()
    }

    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            AppLogger.shared.log("AudioSession kích hoạt (.playback + .mixWithOthers) - Vol: \(Int(session.outputVolume * 100))%")
        } catch {
            AppLogger.shared.log("❌ Lỗi AudioSession: \(error.localizedDescription)")
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

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            AppLogger.shared.log("⚠️ Bị gián đoạn âm thanh (Interruption began)")
        } else if type == .ended {
            AppLogger.shared.log("🔄 Phục hồi sau gián đoạn âm thanh...")
            setupAudioSession()
        }
    }

    // =========================================================
    // GETTERS & SETTERS
    // =========================================================

    func getServerIP() -> String {
        return serverIP
    }

    func getServerPort() -> Int {
        return serverPort
    }

    func getAuthToken() -> String {
        return token
    }

    func setServerAddress(ip: String, port: Int, token: String? = nil, shouldReconnect: Bool = true) {
        let cleanedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedIP.isEmpty, port > 0, port <= 65535 else { return }

        serverIP = cleanedIP
        serverPort = port

        UserDefaults.standard.set(cleanedIP, forKey: "listenerServerIP")
        UserDefaults.standard.set(port, forKey: "listenerServerPort")

        if let token = token {
            let cleanedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedToken.isEmpty {
                self.token = cleanedToken
                UserDefaults.standard.set(cleanedToken, forKey: "listenerAuthToken")
            }
        }

        AppLogger.shared.log("Đổi server thành: \(cleanedIP):\(port)")

        if shouldReconnect {
            reconnect()
        }
    }

    // =========================================================
    // WEBSOCKET CONNECTION
    // =========================================================

    private func makeWebSocketURL() -> URL? {
        return URL(string: "ws://\(serverIP):\(serverPort)/ws")
    }

    func connect() {
        manualDisconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        guard let url = makeWebSocketURL() else {
            AppLogger.shared.log("❌ URL WebSocket không hợp lệ")
            scheduleReconnect()
            return
        }

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil

        setConnecting(true)
        AppLogger.shared.log("Đang nối tới: \(url.absoluteString)")

        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())

        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        receiveMessage()
    }

    private func authenticate() {
        let message: [String: Any] = [
            "type": "auth",
            "role": "listener",
            "token": token
        ]
        sendJSON(message)
        AppLogger.shared.log("Gửi yêu cầu xác thực (auth)...")
    }

    private func receiveMessage() {
        guard let socket = webSocket else { return }

        socket.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.receiveMessage()

                switch message {
                case .string(let text):
                    self.handleJSON(text)
                case .data(let data):
                    self.handleAudio(data)
                @unknown default:
                    break
                }

            case .failure(let error):
                AppLogger.shared.log("❌ Mất kết nối WS: \(error.localizedDescription)")
                self.setDisconnected()
                self.scheduleReconnect()
            }
        }
    }

    private func handleJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let type = message["type"] as? String {
            switch type {
            case "auth_result":
                let success = message["success"] as? Bool ?? false
                if success {
                    AppLogger.shared.log("✅ Xác thực thành công (Listener)")
                    setConnected(true)
                } else {
                    AppLogger.shared.log("❌ Xác thực thất bại (Sai token)")
                    setDisconnected()
                    manualDisconnect = true
                }

            case "audio_format":
                if let sampleRate = message["sampleRate"] as? NSNumber {
                    self.audioSampleRate = sampleRate.doubleValue
                    AppLogger.shared.log("🎵 Định dạng mic gửi về: \(audioSampleRate) Hz")
                    setupAudioQueue(sampleRate: self.audioSampleRate)
                }

            case "status":
                let iphoneConnected = message["iphoneConnected"] as? Bool ?? false
                AppLogger.shared.log("Trạng thái Mic: \(iphoneConnected ? "🟢 Online" : "🔴 Offline")")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .iphoneStatusChanged,
                        object: nil,
                        userInfo: ["connected": iphoneConnected]
                    )
                }

            case "error":
                let errorMessage = message["message"] as? String ?? "Server error"
                AppLogger.shared.log("⚠️ Lỗi từ server: \(errorMessage)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .serverError,
                        object: nil,
                        userInfo: ["message": errorMessage]
                    )
                }

            default:
                break
            }
        }
    }

    // =========================================================
    // AUDIO STREAMING (CoreAudio AudioQueue)
    // =========================================================

    private func setupAudioQueue(sampleRate: Double) {
        stopAudioQueue()
        self.audioSampleRate = sampleRate
        setupAudioSession()

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let callback: AudioQueueOutputCallback = { (_, queue, buffer) in
            AudioQueueFreeBuffer(queue, buffer)
        }

        let status = AudioQueueNewOutput(
            &format,
            callback,
            nil,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue,
            0,
            &audioQueue
        )

        if status == noErr, let queue = audioQueue {
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1.0)
            AudioQueueStart(queue, nil)
            isAudioQueueRunning = true
            AppLogger.shared.log("✅ AudioQueue khởi chạy tại \(Int(sampleRate)) Hz")
        } else {
            AppLogger.shared.log("❌ AudioQueueNewOutput lỗi: \(status)")
        }
    }

    private func handleAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return }

        totalPacketsHandled += 1
        if totalPacketsHandled <= 3 || totalPacketsHandled % 100 == 0 {
            AppLogger.shared.log("📥 Đang nhận gói audio #\(totalPacketsHandled) (\(data.count)B)")
        }

        if audioQueue == nil || !isAudioQueueRunning {
            setupAudioQueue(sampleRate: audioSampleRate)
        }

        guard let queue = audioQueue else { return }

        // Khuếch đại âm lượng Gain (4.0x) và tính toán RMS
        var sumSquares: Float = 0
        var modifiedData = data

        modifiedData.withUnsafeMutableBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let original = Float(ptr[i])
                let amplified = original * 4.0
                let clamped = max(Float(Int16.min), min(Float(Int16.max), amplified))
                ptr[i] = Int16(clamped)

                let norm = clamped / 32768.0
                sumSquares += norm * norm
            }
        }

        let rms = sqrt(sumSquares / Float(sampleCount))

        // Gửi buffer PCM trực tiếp vào AudioQueue
        var buffer: AudioQueueBufferRef?
        let byteSize = UInt32(modifiedData.count)
        let allocStatus = AudioQueueAllocateBuffer(queue, byteSize, &buffer)
        if allocStatus == noErr, let buf = buffer {
            buf.pointee.mAudioDataByteSize = byteSize
            modifiedData.copyBytes(to: buf.pointee.mAudioData.assumingMemoryBound(to: UInt8.self), count: modifiedData.count)
            let enqStatus = AudioQueueEnqueueBuffer(queue, buf, 0, nil)
            if enqStatus != noErr && totalPacketsHandled <= 5 {
                AppLogger.shared.log("❌ Enqueue lỗi: \(enqStatus)")
            }

            if !isAudioQueueRunning {
                AudioQueueStart(queue, nil)
                isAudioQueueRunning = true
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .audioMetricsUpdated,
                object: nil,
                userInfo: [
                    "level": rms,
                    "bytes": data.count
                ]
            )
        }
    }

    private func stopAudioQueue() {
        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
        isAudioQueueRunning = false
    }

    // =========================================================
    // TEST SOUND: PHÁT FILE BEEP.WAV QUA NHIỀU ENGINE
    // =========================================================

    func playTestBeep() -> String {
        AppLogger.shared.log("▶️ Bấm nút TEST LOA...")
        setupAudioSession()

        // 1. Rung máy
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

        // 2. Chuông hệ thống iOS Native
        AudioServicesPlayAlertSound(1005)

        // 3. Phát file beep.wav nhúng sẵn
        if let soundURL = Bundle.main.url(forResource: "beep", withExtension: "wav") {
            AppLogger.shared.log("Tìm thấy beep.wav tại: \(soundURL.lastPathComponent)")

            do {
                beepPlayer = try AVAudioPlayer(contentsOf: soundURL)
                beepPlayer?.prepareToPlay()
                beepPlayer?.volume = 1.0
                let played = beepPlayer?.play() ?? false
                AppLogger.shared.log("AVAudioPlayer.play(): \(played ? "THÀNH CÔNG" : "THẤT BẠI")")

                // Dự phòng thêm AVPlayer
                avPlayer = AVPlayer(url: soundURL)
                avPlayer?.volume = 1.0
                avPlayer?.play()

                return played ? "✅ Đã phát tiếng bíp (AVAudioPlayer)" : "⚠️ Player trả về false"
            } catch {
                AppLogger.shared.log("❌ Lỗi AVAudioPlayer: \(error.localizedDescription)")
                return "❌ Lỗi: \(error.localizedDescription)"
            }
        } else {
            AppLogger.shared.log("❌ KHÔNG tìm thấy beep.wav trong Bundle.main!")
            return "❌ Thiếu file beep.wav"
        }
    }

    // =========================================================
    // SYSTEM AUDIO INFO
    // =========================================================

    func getAudioSystemInfo() -> (volume: Float, route: String) {
        let session = AVAudioSession.sharedInstance()
        let volume = session.outputVolume
        let route = session.currentRoute.outputs.first?.portName ?? "Loa ngoài"
        return (volume, route)
    }

    // =========================================================
    // COMMANDS
    // =========================================================

    func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        webSocket?.send(.string(text)) { error in
            if let error = error {
                AppLogger.shared.log("❌ Send error: \(error.localizedDescription)")
            }
        }
    }

    func startListening() {
        guard isConnected else {
            AppLogger.shared.log("⚠️ Chưa kết nối server!")
            return
        }
        totalPacketsHandled = 0
        setupAudioQueue(sampleRate: audioSampleRate)
        sendJSON(["command": "start_mic"])
        AppLogger.shared.log("Đã gửi lệnh START_MIC lên server")
    }

    func stopListening() {
        guard isConnected else { return }
        stopAudioQueue()
        sendJSON(["command": "stop_mic"])
        AppLogger.shared.log("Đã gửi lệnh STOP_MIC lên server")
    }

    func reconnect() {
        AppLogger.shared.log("Đang kết nối lại...")
        manualDisconnect = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil

        setDisconnected()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.connect()
        }
    }

    private func scheduleReconnect() {
        guard !manualDisconnect else { return }
        reconnectWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !self.isConnected {
                self.connect()
            }
        }

        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func setConnecting(_ value: Bool) {
        isConnecting = value
        if value {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .networkStatusChanged,
                    object: nil,
                    userInfo: ["connected": false, "connecting": true]
                )
            }
        }
    }

    private func setConnected(_ value: Bool) {
        isConnected = value
        isConnecting = false
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .networkStatusChanged,
                object: nil,
                userInfo: ["connected": value, "connecting": false]
            )
        }
    }

    private func setDisconnected() {
        isConnected = false
        isConnecting = false
        stopAudioQueue()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .networkStatusChanged,
                object: nil,
                userInfo: ["connected": false, "connecting": false]
            )
        }
    }
}

// =============================================================
// URL SESSION DELEGATE
// =============================================================

extension NetworkManager: URLSessionWebSocketDelegate {

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        AppLogger.shared.log("🟢 WebSocket đã mở kết nối!")
        authenticate()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        AppLogger.shared.log("🔴 WebSocket đã đóng (code: \(closeCode.rawValue))")
        setDisconnected()
        scheduleReconnect()
    }
}

// =============================================================
// NOTIFICATIONS
// =============================================================

extension Notification.Name {
    static let networkStatusChanged = Notification.Name("listenerNetworkStatusChanged")
    static let iphoneStatusChanged = Notification.Name("listenerIPhoneStatusChanged")
    static let serverError = Notification.Name("listenerServerError")
    static let audioMetricsUpdated = Notification.Name("listenerAudioMetricsUpdated")
}
