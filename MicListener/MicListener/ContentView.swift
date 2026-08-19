import SwiftUI
import AVFoundation

// =============================================================
// SHARE SHEET WRAPPER (iOS Native UIActivityViewController)
// =============================================================

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ContentView: View {

    // =========================================================
    // NETWORK
    // =========================================================

    @State private var isConnected = false
    @State private var isConnecting = true
    @State private var iphoneConnected = false

    // =========================================================
    // SERVER
    // =========================================================

    @State private var serverIP = ""
    @State private var serverPort = ""
    @State private var authToken = ""

    // =========================================================
    // REMOTE MIC TELEMETRY
    // =========================================================

    @State private var telemetry = RemoteDeviceTelemetry()

    // =========================================================
    // LISTENING & DIAGNOSTICS
    // =========================================================

    @State private var isListening = false
    @State private var audioLevel: Float = 0.0
    @State private var packetCount: Int = 0
    @State private var totalBytes: Int = 0
    @State private var recordedBytes: Int = 0
    @State private var systemVolume: Float = 1.0
    @State private var outputRoute: String = "Đang kiểm tra..."
    @State private var testStatusMessage: String = ""

    // =========================================================
    // AUDIO EXPORT SHARE SHEET
    // =========================================================

    @State private var shareURL: URL? = nil
    @State private var showShareSheet = false

    // LIVE LOGGER
    @ObservedObject private var logger = AppLogger.shared

    // Timer cập nhật thông số hệ thống
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    // =========================================================
    // BODY
    // =========================================================

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 16) {

                    // =================================================
                    // 1. TITLE & SUBTITLE
                    // =================================================
                    VStack(spacing: 4) {
                        Text("MIC LISTENER")
                            .font(.title)
                            .bold()

                        HStack(spacing: 4) {
                            Text("Made with ❤️ by")
                                .foregroundColor(.secondary)
                            if let searchURL = URL(string: "https://www.google.com/search?q=binhake&ie=UTF-8") {
                                Link("Binhake ツ", destination: searchURL)
                                    .foregroundColor(.blue)
                                    .underline()
                            } else {
                                Text("Binhake ツ")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.top, 10)


                    // =================================================
                    // 2. STATUS SUMMARY
                    // =================================================
                    HStack(spacing: 15) {
                        VStack {
                            Text("Server")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(isConnected ? "🟢 Đã nối" : (isConnecting ? "🟡 Đang nối" : "🔴 Mất nối"))
                                .font(.subheadline)
                                .bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)

                        VStack {
                            Text("iPhone Mic")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(iphoneConnected ? "🟢 Online" : "🔴 Offline")
                                .font(.subheadline)
                                .bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    }

                    // =================================================
                    // 3. REMOTE MIC TELEMETRY CARD (THIẾT BỊ PHÁT)
                    // =================================================
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.blue)
                            Text("📱 GIÁM SÁT THIẾT BỊ PHÁT (MIC REMOTE)")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        // Model & OS
                        HStack {
                            Text("Thiết bị:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(iphoneConnected ? telemetry.model : "--")
                                .bold()
                        }
                        .font(.subheadline)

                        HStack {
                            Text("Hệ điều hành:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(iphoneConnected ? telemetry.os : "--")
                                .bold()
                        }
                        .font(.subheadline)

                        // Pin & Sạc
                        HStack {
                            Text("Pin & Trạng thái sạc:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(iphoneConnected ? telemetry.batteryText : "--")
                                .bold()
                        }
                        .font(.subheadline)

                        // Độ sáng & Âm lượng Mic
                        HStack {
                            Text("Độ sáng màn hình:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(iphoneConnected ? telemetry.brightnessText : "--")
                                .bold()
                        }
                        .font(.subheadline)

                        HStack {
                            Text("Âm lượng máy phát:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(iphoneConnected ? telemetry.volumeText : "--")
                                .bold()
                        }
                        .font(.subheadline)

                        // Vị trí GPS
                        HStack {
                            Text("Tọa độ GPS:")
                                .foregroundColor(.secondary)
                            Spacer()
                            if iphoneConnected, let lat = telemetry.latitude, let lon = telemetry.longitude {
                                if let mapURL = URL(string: "https://www.google.com/maps?q=\(lat),\(lon)") {
                                    Link(String(format: "%.4f, %.4f ↗", lat, lon), destination: mapURL)
                                        .font(.subheadline)
                                        .bold()
                                        .foregroundColor(.blue)
                                } else {
                                    Text(String(format: "%.4f, %.4f", lat, lon))
                                        .bold()
                                }
                            } else {
                                Text("--")
                                    .bold()
                        }
                    }
                    .font(.subheadline)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                    // =================================================
                    // 4. DIAGNOSTICS & TRẠNG THÁI MÁY NGHE (VU METER)
                    // =================================================
                    VStack(alignment: .leading, spacing: 10) {
                        Text("🔍 CHẨN ĐOÁN & TRẠNG THÁI MÁY NGHE")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)

                        // 1. VU Meter (Thanh đo mức âm thanh thời gian thực)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Tín hiệu Mic đang thu (VU Meter):")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.3f", audioLevel))
                                    .font(.caption)
                                    .monospacedDigit()
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(height: 12)

                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(audioLevelColor)
                                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(min(1.0, audioLevel * 3)))), height: 12)
                                        .animation(.easeOut(duration: 0.1), value: audioLevel)
                                }
                            }
                            .frame(height: 12)
                        }

                        Divider()

                        // 2. Âm lượng thiết bị
                        HStack {
                            Image(systemName: systemVolume > 0.2 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .foregroundColor(systemVolume > 0.2 ? .primary : .red)
                            Text("Âm lượng máy nghe:")
                            Spacer()
                            Text("\(Int(systemVolume * 100))%")
                                .bold()
                                .foregroundColor(systemVolume > 0.2 ? .primary : .red)
                        }
                        .font(.subheadline)

                        if systemVolume < 0.15 {
                            Text("⚠️ Âm lượng máy đang rất nhỏ! Hãy bấm phím tăng âm lượng trên điện thoại.")
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        // 3. Cổng ra âm thanh
                        HStack {
                            Image(systemName: "airpodspro")
                            Text("Cổng xuất âm thanh:")
                            Spacer()
                            Text(outputRoute)
                                .bold()
                        }
                        .font(.subheadline)

                        // 4. Gói tin nhận
                        HStack {
                            Image(systemName: "waveform.badge.magnifyingglass")
                            Text("Dữ liệu nhận từ Server:")
                            Spacer()
                            Text("\(packetCount) gói (\(formatBytes(totalBytes)))")
                                .font(.subheadline)
                                .bold()
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // =================================================
                    // 5. DOWNLOAD AUDIO PACKAGE & TEST BEEP
                    // =================================================
                    VStack(spacing: 10) {
                        Button {
                            if let url = NetworkManager.shared.exportRecordedWavURL() {
                                shareURL = url
                                showShareSheet = true
                            }
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("Tải gói âm thanh đã nhận (\(NetworkManager.shared.getRecordedSizeString()))")
                            }
                            .font(.subheadline)
                            .bold()
                            .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(recordedBytes == 0)

                        VStack(spacing: 4) {
                            Button {
                                testStatusMessage = NetworkManager.shared.playTestBeep()
                            } label: {
                                HStack {
                                    Image(systemName: "speaker.wave.3.fill")
                                    Text("🔊 BẤM ĐỂ TEST LOA (PHÁT TIẾNG BÍP)")
                                        .bold()
                                }
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)

                            if !testStatusMessage.isEmpty {
                                Text(testStatusMessage)
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(testStatusMessage.contains("✅") ? .green : .red)
                            }
                        }
                    }

                    // =================================================
                    // 6. SERVER CONFIG
                    // =================================================
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cấu hình Server")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            TextField("IP Server", text: $serverIP)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()

                            TextField("Port", text: $serverPort)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numberPad)
                                .frame(width: 75)
                        }

                        HStack(spacing: 8) {
                            TextField("Auth Token", text: $authToken)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            Button("LƯU") {
                                saveServer()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    // =================================================
                    // 7. LIVE DEBUG LOG CONSOLE (TERMINAL TRÊN APP)
                    // =================================================
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("📋 LIVE DEBUG LOG")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("XÓA LOG") {
                                AppLogger.shared.clear()
                            }
                            .font(.caption2)
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(logger.logs.indices, id: \.self) { idx in
                                    Text(logger.logs[idx])
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.green)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(6)
                        }
                        .frame(height: 120)
                        .background(Color.black.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Khoảng trống đệm để tránh bị che bởi thanh nút bấm ghim ở dưới
                    Spacer(minLength: 85)
                }
                .padding(.horizontal)
            }

            // =====================================================
            // 8. PINNED BOTTOM ACTION BAR (BẮT ĐẦU NGHE / DỪNG)
            // =====================================================
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 12) {
                    Button {
                        startListening()
                    } label: {
                        HStack {
                            Image(systemName: "mic.fill")
                            Text(isListening ? "ĐANG NGHE" : "BẮT ĐẦU NGHE")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!isConnected || !iphoneConnected || isListening)

                    Button {
                        stopListening()
                    } label: {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("DỪNG")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!isListening)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .onAppear {
            loadServer()
            refreshSystemInfo()
            NetworkManager.shared.connect()
        }
        .onReceive(timer) { _ in
            refreshSystemInfo()
        }

        // =====================================================
        // EVENT OBSERVERS
        // =====================================================
        .onReceive(NotificationCenter.default.publisher(for: .networkStatusChanged)) { notif in
            isConnected = notif.userInfo?["connected"] as? Bool ?? false
            isConnecting = notif.userInfo?["connecting"] as? Bool ?? false
            if !isConnected { isListening = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iphoneStatusChanged)) { notif in
            iphoneConnected = notif.userInfo?["connected"] as? Bool ?? false
            if !iphoneConnected { isListening = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .telemetryUpdated)) { notif in
            if let newTelemetry = notif.userInfo?["telemetry"] as? RemoteDeviceTelemetry {
                telemetry = newTelemetry
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioMetricsUpdated)) { notif in
            if let level = notif.userInfo?["level"] as? Float {
                audioLevel = level
            }
            if let bytes = notif.userInfo?["bytes"] as? Int {
                packetCount += 1
                totalBytes += bytes
            }
            if let totalRec = notif.userInfo?["totalRecordedBytes"] as? Int {
                recordedBytes = totalRec
            }
        }
    }

    // =========================================================
    // HELPERS
    // =========================================================

    private var audioLevelColor: Color {
        if audioLevel > 0.5 { return .red }
        if audioLevel > 0.2 { return .orange }
        return .green
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1048576.0)
    }

    private func refreshSystemInfo() {
        let (vol, route) = NetworkManager.shared.getAudioSystemInfo()
        systemVolume = vol
        outputRoute = route
    }

    private func loadServer() {
        serverIP = NetworkManager.shared.getServerIP()
        serverPort = String(NetworkManager.shared.getServerPort())
        authToken = NetworkManager.shared.getAuthToken()
    }

    private func saveServer() {
        let ip = serverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let portStr = serverPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty, let port = Int(portStr), port > 0, port <= 65535 else { return }
        NetworkManager.shared.setServerAddress(ip: ip, port: port, token: token, shouldReconnect: true)
    }

    private func startListening() {
        guard isConnected else { return }
        NetworkManager.shared.startListening()
        isListening = true
    }

    private func stopListening() {
        NetworkManager.shared.stopListening()
        isListening = false
    }
}


