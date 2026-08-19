import SwiftUI
import AVFoundation
import AVFAudio

struct ContentView: View {

    // ==========================================
    // MIC STATE
    // ==========================================

    @State private var isRecording = false
    @State private var audioLevel: Float = 0

    // ==========================================
    // NETWORK STATE
    // ==========================================

    @State private var isConnected = false
    @State private var isConnecting = true

    // ==========================================
    // SERVER & AUTH
    // ==========================================

    @State private var serverIP = ""
    @State private var serverPort = ""
    @State private var authToken = ""

    // ==========================================
    // AUDIO
    // ==========================================

    private let audioEngine =
        AVAudioEngine()

    // ==========================================
    // BODY
    // ==========================================

    var body: some View {

        VStack(
            spacing: 20
        ) {

            // ======================================
            // TITLE
            // ======================================

            Text("MIC REMOTE")
                .font(
                    .largeTitle
                )
                .bold()

            // ======================================
            // NETWORK STATUS
            // ======================================

            VStack(
                spacing: 6
            ) {

                if isConnected {

                    Text(
                        "🟢 Đã kết nối"
                    )
                    .foregroundColor(
                        .green
                    )

                } else if isConnecting {

                    Text(
                        "🟡 Đang kết nối..."
                    )
                    .foregroundColor(
                        .orange
                    )

                } else {

                    Text(
                        "🔴 Mất kết nối"
                    )
                    .foregroundColor(
                        .red
                    )
                }

                Text(
                    "\(serverIP):\(serverPort)"
                )
                .font(
                    .caption
                )
                .foregroundColor(
                    .secondary
                )
            }

            // ======================================
            // SERVER ADDRESS & AUTH
            // ======================================

            VStack(
                alignment:
                    .leading,
                spacing:
                    10
            ) {

                Text(
                    "Cấu hình Server"
                )
                .font(
                    .headline
                )

                HStack(
                    spacing: 10
                ) {

                    TextField(
                        "IP",
                        text:
                            $serverIP
                    )
                    .textFieldStyle(
                        .roundedBorder
                    )
                    .keyboardType(
                        .numbersAndPunctuation
                    )
                    .autocorrectionDisabled()

                    TextField(
                        "Port",
                        text:
                            $serverPort
                    )
                    .textFieldStyle(
                        .roundedBorder
                    )
                    .keyboardType(
                        .numberPad
                    )
                    .frame(
                        width:
                            85
                    )
                }

                HStack(
                    spacing: 10
                ) {

                    TextField(
                        "Auth Token",
                        text:
                            $authToken
                    )
                    .textFieldStyle(
                        .roundedBorder
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(
                        .never
                    )

                    Button {

                        saveServer()

                    } label: {

                        Text(
                            "LƯU"
                        )
                        .bold()
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                }
            }

            // ======================================
            // MIC STATUS
            // ======================================

            Text(
                isRecording
                ? "🎤 MIC đang hoạt động"
                : "MIC đang tắt"
            )
            .foregroundColor(
                isRecording
                ? .green
                : .gray
            )

            // ======================================
            // AUDIO LEVEL
            // ======================================

            Text(
                String(
                    format:
                        "Audio level: %.3f",
                    audioLevel
                )
            )
            .font(
                .caption
            )

            // ======================================
            // MIC BUTTON
            // ======================================

            Button {

                if isRecording {

                    stopMicrophone()

                } else {

                    startMicrophone()
                }

            } label: {

                Text(
                    isRecording
                    ? "STOP"
                    : "LISTEN"
                )
                .font(
                    .title2
                )
                .bold()
                .frame(
                    width:
                        220,
                    height:
                        60
                )
            }
            .buttonStyle(
                .borderedProminent
            )
            .disabled(
                !isConnected
            )
        }
        .padding()
        .onAppear {

            // ======================================
            // LOAD SAVED SERVER & TOKEN
            // ======================================

            serverIP =
                NetworkManager.shared
                    .getServerIP()

            serverPort =
                NetworkManager.shared
                    .getServerPort()

            authToken =
                NetworkManager.shared
                    .getAuthToken()

            // ======================================
            // CONNECT
            // ======================================

            NetworkManager.shared
                .connect()
        }

        // ==========================================
        // NETWORK STATUS
        // ==========================================

        .onReceive(
            NotificationCenter.default.publisher(
                for:
                    .networkStatusChanged
            )
        ) { notification in

            let connected =
                notification.userInfo?[
                    "connected"
                ] as? Bool
                ?? false

            let connecting =
                notification.userInfo?[
                    "connecting"
                ] as? Bool
                ?? false

            isConnected =
                connected

            isConnecting =
                connecting
        }

        // ==========================================
        // SERVER → START MIC
        // ==========================================

        .onReceive(
            NotificationCenter.default.publisher(
                for:
                    .startMicrophone
            )
        ) { _ in

            print(
                "[App] Remote START received"
            )

            startMicrophone()
        }

        // ==========================================
        // SERVER → STOP MIC
        // ==========================================

        .onReceive(
            NotificationCenter.default.publisher(
                for:
                    .stopMicrophone
            )
        ) { _ in

            print(
                "[App] Remote STOP received"
            )

            stopMicrophone()
        }
    }

    // ==========================================
    // SAVE SERVER
    // ==========================================

    private func saveServer() {

        let ip =
            serverIP
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        let port =
            serverPort
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        let token =
            authToken
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard
            !ip.isEmpty,
            !port.isEmpty
        else {

            return
        }

        NetworkManager.shared
            .setServerAddress(
                ip:
                    ip,
                port:
                    port,
                token:
                    token,
                shouldReconnect:
                    true
            )

        // Sau khi lưu,
        // NetworkManager sẽ lập tức
        // chuyển sang reconnect địa chỉ mới.
    }

    // ==========================================
    // START MICROPHONE
    // ==========================================

    private func startMicrophone() {

        if isRecording {
            return
        }

        if #available(
            iOS 17.0,
            *
        ) {

            AVAudioApplication
                .requestRecordPermission {

                    allowed in

                    DispatchQueue.main.async {

                        if allowed {

                            do {

                                try setupMicrophone()

                            } catch {

                                print(
                                    "[MIC] Error:",
                                    error
                                )
                            }

                        } else {

                            print(
                                "[MIC] Permission denied"
                            )
                        }
                    }
                }

        } else {

            AVAudioSession
                .sharedInstance()
                .requestRecordPermission {

                    allowed in

                    DispatchQueue.main.async {

                        if allowed {

                            do {

                                try setupMicrophone()

                            } catch {

                                print(
                                    "[MIC] Error:",
                                    error
                                )
                            }

                        } else {

                            print(
                                "[MIC] Permission denied"
                            )
                        }
                    }
                }
        }
    }

    // ==========================================
    // SETUP MICROPHONE
    // ==========================================

    private func setupMicrophone()
        throws {

        let session =
            AVAudioSession
                .sharedInstance()

        try session.setCategory(
            .playAndRecord,
            mode:
                .default,
            options: [
                .mixWithOthers,
                .defaultToSpeaker,
                .allowBluetooth
            ]
        )

        try session.setActive(
            true
        )

        let inputNode =
            audioEngine.inputNode

        let format =
            inputNode.outputFormat(
                forBus:
                    0
            )

        let sampleRate =
            format.sampleRate

        print(
            "[Audio] Sample rate:",
            sampleRate
        )

        // ======================================
        // SEND AUDIO FORMAT
        // ======================================

        NetworkManager.shared
            .sendJSON(
                [
                    "type":
                        "audio_format",

                    "sampleRate":
                        sampleRate,

                    "channels":
                        1,

                    "bitsPerSample":
                        16
                ]
            )

        // ======================================
        // TAP
        // ======================================

        inputNode.installTap(
            onBus:
                0,
            bufferSize:
                1024,
            format:
                format
        ) {
            buffer,
            _ in

            guard
                let channelData =
                    buffer.floatChannelData
            else {
                return
            }

            let channel =
                channelData[0]

            let frameLength =
                Int(
                    buffer.frameLength
                )

            if frameLength == 0 {
                return
            }

            // ==================================
            // AUDIO LEVEL
            // ==================================

            var sum:
                Float = 0

            for i in
                0..<frameLength {

                sum +=
                    channel[i] *
                    channel[i]
            }

            let rms =
                sqrt(
                    sum /
                    Float(
                        frameLength
                    )
                )

            DispatchQueue.main.async {

                self.audioLevel =
                    rms

                self.isRecording =
                    true
            }

            // ==================================
            // VOICE PROCESSING
            // ==================================

            let threshold:
                Float = 0.12

            let ratio:
                Float = 3.0

            let makeupGain:
                Float = 1.8

            var pcmData =
                Data(
                    capacity:
                        frameLength * 2
                )

            for i in
                0..<frameLength {

                let input =
                    channel[i]

                let sign:
                    Float =
                        input >= 0
                        ? 1.0
                        : -1.0

                let magnitude =
                    abs(
                        input
                    )

                var processed =
                    magnitude

                // ------------------------------
                // COMPRESSOR
                // ------------------------------

                if magnitude >
                    threshold {

                    let excess =
                        magnitude -
                        threshold

                    processed =
                        threshold +
                        excess /
                        ratio
                }

                // ------------------------------
                // MAKEUP GAIN
                // ------------------------------

                processed *=
                    makeupGain

                // ------------------------------
                // LIMITER
                // ------------------------------

                processed =
                    min(
                        processed,
                        0.95
                    )

                let sample =
                    sign *
                    processed

                // ------------------------------
                // FLOAT32 → PCM16
                // ------------------------------

                let intSample =
                    Int16(
                        sample *
                        Float(
                            Int16.max
                        )
                    )

                var littleEndian =
                    intSample
                        .littleEndian

                withUnsafeBytes(
                    of:
                        &littleEndian
                ) {
                    bytes in

                    pcmData.append(
                        contentsOf:
                            bytes
                    )
                }
            }

            // ==================================
            // SEND AUDIO
            // ==================================

            NetworkManager.shared
                .sendAudioData(
                    pcmData
                )
        }

        // ======================================
        // START ENGINE
        // ======================================

        audioEngine.prepare()

        try audioEngine.start()

        print(
            "[MIC] Microphone started"
        )
    }

    // ==========================================
    // STOP MICROPHONE
    // ==========================================

    private func stopMicrophone() {

        audioEngine.inputNode
            .removeTap(
                onBus:
                    0
            )

        audioEngine.stop()

        do {

            try AVAudioSession
                .sharedInstance()
                .setActive(
                    false
                )

        } catch {

            print(
                "[MIC] Stop error:",
                error
            )
        }

        isRecording =
            false

        audioLevel =
            0

        print(
            "[MIC] Microphone stopped"
        )
    }
}
