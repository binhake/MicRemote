const fs = require("fs");
const path = require("path");
const http = require("http");
const express = require("express");
const WebSocket = require("ws");

// ============================================================
// LOAD ENVIRONMENT VARIABLES (.env)
// ============================================================

function loadEnvFile() {
    const envPath = path.join(__dirname, ".env");
    if (!fs.existsSync(envPath)) return;

    if (typeof process.loadEnvFile === "function") {
        try {
            process.loadEnvFile(envPath);
            return;
        } catch (e) {
            // Fallback manual parser
        }
    }

    try {
        const content = fs.readFileSync(envPath, "utf8");
        content.split("\n").forEach(line => {
            const trimmed = line.trim();
            if (!trimmed || trimmed.startsWith("#") || !trimmed.includes("=")) return;
            const idx = trimmed.indexOf("=");
            const key = trimmed.slice(0, idx).trim();
            let val = trimmed.slice(idx + 1).trim();
            if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
                val = val.slice(1, -1);
            }
            if (process.env[key] === undefined) {
                process.env[key] = val;
            }
        });
    } catch (err) {
        console.warn("[ENV] Could not read .env file:", err.message);
    }
}

loadEnvFile();

const app = express();

const PORT = parseInt(process.env.PORT || "3000", 10);

// ============================================================
// CONFIG & AUTH VALIDATION
// ============================================================

const AUTH_TOKEN = (process.env.AUTH_TOKEN || "").trim();

if (!AUTH_TOKEN) {
    console.error("");
    console.error("=========================================================");
    console.error("❌ [LỖI KHỞI ĐỘNG]: Chưa thiết lập biến môi trường AUTH_TOKEN!");
    console.error("👉 Vui lòng tạo file .env từ .env.example và điền AUTH_TOKEN:");
    console.error("     cp .env.example .env");
    console.error("   hoặc chạy với: AUTH_TOKEN=your_token node server.js");
    console.error("=========================================================");
    console.error("");
    process.exit(1);
}

// ============================================================
// HTTP SERVER
// ============================================================

const server =
    http.createServer(app);

// ============================================================
// WEBSOCKET SERVER
// ============================================================

const wss =
    new WebSocket.Server({
        server,
        path: "/ws"
    });

// ============================================================
// CLIENTS
// ============================================================

// Chỉ cho phép 1 iPhone active
let iphone = null;

// Lưu trữ telemetry gần nhất từ iPhone
let lastIPhoneTelemetry = null;

// Có thể có nhiều web listener
const listeners = new Set();


// ============================================================
// STATUS
// ============================================================

function getStatus() {

    const iphoneConnected =
        iphone !== null &&
        iphone.readyState === WebSocket.OPEN;

    // Dọn listener chết
    for (const ws of listeners) {

        if (
            ws.readyState !==
            WebSocket.OPEN
        ) {
            listeners.delete(ws);
        }
    }

    return {

        iphoneConnected,

        listeners:
            listeners.size
    };
}

// ============================================================
// SEND JSON
// ============================================================

function sendJSON(
    ws,
    data
) {

    if (!ws) {
        return false;
    }

    if (
        ws.readyState !==
        WebSocket.OPEN
    ) {
        return false;
    }

    try {

        ws.send(
            JSON.stringify(data)
        );

        return true;

    } catch (error) {

        console.log(
            "[WS] Send JSON error:",
            error.message
        );

        return false;
    }
}

// ============================================================
// BROADCAST STATUS
// ============================================================

function broadcastStatus() {

    const status = {

        type:
            "status",

        ...getStatus()
    };

    for (const listener of listeners) {

        sendJSON(
            listener,
            status
        );
    }
}

// ============================================================
// BROADCAST JSON FROM IPHONE
// ============================================================

function broadcastFromIPhone(
    message
) {

    for (const listener of listeners) {

        if (
            listener.readyState ===
            WebSocket.OPEN
        ) {

            sendJSON(
                listener,
                message
            );
        }
    }
}

// ============================================================
// BROADCAST AUDIO
// ============================================================

function broadcastAudio(
    data
) {

    for (const listener of listeners) {

        if (
            listener.readyState ===
            WebSocket.OPEN
        ) {

            try {

                listener.send(
                    data,
                    {
                        binary: true
                    }
                );

            } catch (error) {

                console.log(
                    "[AUDIO] Send error:",
                    error.message
                );
            }
        }
    }
}

// ============================================================
// SEND ERROR
// ============================================================

function sendError(
    ws,
    message
) {

    sendJSON(
        ws,
        {
            type:
                "error",

            message
        }
    );
}

// ============================================================
// WEBSOCKET CONNECTION
// ============================================================

wss.on(
    "connection",
    (ws, request) => {

        console.log("");
        console.log(
            "================================"
        );
        console.log(
            "[WS] New connection:",
            request.socket.remoteAddress
        );
        console.log(
            "================================"
        );

        // ====================================================
        // CLIENT STATE
        // ====================================================

        let role = null;

        let authenticated =
            false;

        // ====================================================
        // MESSAGE
        // ====================================================

        ws.on(
            "message",
            (data, isBinary) => {

                // ==================================================
                // BINARY AUDIO
                // ==================================================

                if (isBinary) {

                    // ----------------------------------------------
                    // Chỉ iPhone đã authenticate mới được gửi audio
                    // ----------------------------------------------

                    if (
                        !authenticated ||
                        role !== "iphone"
                    ) {

                        console.log(
                            "[AUDIO] Rejected unauthenticated binary data"
                        );

                        return;
                    }

                    // ----------------------------------------------
                    // Không log từng packet audio
                    // ----------------------------------------------
                    // Tránh terminal bị spam hàng nghìn dòng.
                    //
                    // Audio packet vẫn được forward bình thường.

                    broadcastAudio(
                        data
                    );

                    return;
                }

                // ==================================================
                // PARSE JSON
                // ==================================================

                let message;

                try {

                    message =
                        JSON.parse(
                            data.toString()
                        );

                } catch (error) {

                    console.log(
                        "[WS] Invalid JSON"
                    );

                    return;
                }

                // ==================================================
                // AUTHENTICATION
                // ==================================================

                if (
                    message.type ===
                    "auth"
                ) {

                    // ----------------------------------------------
                    // TOKEN
                    // ----------------------------------------------

                    if (
                        message.token !==
                        AUTH_TOKEN
                    ) {

                        console.log(
                            "[AUTH] Invalid token"
                        );

                        sendJSON(
                            ws,
                            {
                                type:
                                    "auth_result",

                                success:
                                    false
                            }
                        );

                        ws.close();

                        return;
                    }

                    // ----------------------------------------------
                    // ROLE
                    // ----------------------------------------------

                    if (
                        message.role !==
                        "iphone" &&
                        message.role !==
                        "listener"
                    ) {

                        console.log(
                            "[AUTH] Unknown role:",
                            message.role
                        );

                        sendJSON(
                            ws,
                            {
                                type:
                                    "auth_result",

                                success:
                                    false
                            }
                        );

                        ws.close();

                        return;
                    }

                    // ----------------------------------------------
                    // AUTH SUCCESS
                    // ----------------------------------------------

                    role =
                        message.role;

                    authenticated =
                        true;

                    // =================================================
                    // IPHONE
                    // =================================================

                    if (
                        role ===
                        "iphone"
                    ) {

                        // ---------------------------------------------
                        // Nếu đã có iPhone khác
                        // ---------------------------------------------

                        if (
                            iphone &&
                            iphone !== ws &&
                            iphone.readyState ===
                            WebSocket.OPEN
                        ) {

                            console.log(
                                "[iPhone] Replacing old connection"
                            );

                            sendJSON(
                                iphone,
                                {
                                    type:
                                        "connection_replaced"
                                }
                            );

                            iphone.close();
                        }

                        // ---------------------------------------------
                        // Set current iPhone
                        // ---------------------------------------------

                        iphone =
                            ws;

                        console.log(
                            "[iPhone] Connected"
                        );

                        // ---------------------------------------------
                        // Auth response
                        // ---------------------------------------------

                        sendJSON(
                            ws,
                            {
                                type:
                                    "auth_result",

                                success:
                                    true,

                                role:
                                    "iphone"
                            }
                        );

                        // ---------------------------------------------
                        // Broadcast status
                        // ---------------------------------------------

                        broadcastStatus();

                        return;
                    }

                    // =================================================
                    // LISTENER / WEB
                    // =================================================

                    if (
                        role ===
                        "listener"
                    ) {

                        listeners.add(
                            ws
                        );

                        console.log(
                            "[Listener] Connected"
                        );

                        // ---------------------------------------------
                        // Auth response
                        // ---------------------------------------------

                        sendJSON(
                            ws,
                            {
                                type:
                                    "auth_result",

                                success:
                                    true,

                                role:
                                    "listener"
                            }
                        );

                        // ---------------------------------------------
                        // Send current status
                        // ---------------------------------------------

                        sendJSON(
                            ws,
                            {
                                type:
                                    "status",

                                ...getStatus()
                            }
                        );

                        // ---------------------------------------------
                        // Send last telemetry if available
                        // ---------------------------------------------

                        if (lastIPhoneTelemetry) {
                            sendJSON(ws, lastIPhoneTelemetry);
                        }

                        // ---------------------------------------------
                        // Notify all listeners
                        // ---------------------------------------------

                        broadcastStatus();

                        return;
                    }
                }

                // ==================================================
                // REQUIRE AUTHENTICATION
                // ==================================================

                if (!authenticated) {

                    console.log(
                        "[WS] Message before authentication"
                    );

                    return;
                }

                // ==================================================
                // MESSAGE FROM IPHONE
                // ==================================================

                if (
                    role ===
                    "iphone"
                ) {

                    // ----------------------------------------------
                    // TELEMETRY & DEVICE INFO
                    // ----------------------------------------------

                    if (
                        message.type ===
                        "telemetry"
                    ) {
                        lastIPhoneTelemetry = message;
                        broadcastFromIPhone(message);
                        return;
                    }

                    // ----------------------------------------------
                    // AUDIO FORMAT
                    // ----------------------------------------------

                    if (
                        message.type ===
                        "audio_format"
                    ) {

                        console.log(
                            "[AUDIO] Format:",
                            message.sampleRate,
                            "Hz"
                        );

                        broadcastFromIPhone(
                            message
                        );

                        return;
                    }

                    // ----------------------------------------------
                    // Other messages from iPhone
                    // ----------------------------------------------

                    broadcastFromIPhone(
                        message
                    );

                    return;
                }


                // ==================================================
                // COMMANDS FROM WEB
                // ==================================================

                if (
                    role ===
                    "listener"
                ) {

                    // =================================================
                    // START MIC
                    // =================================================

                    if (
                        message.command ===
                        "start_mic"
                    ) {

                        console.log(
                            "[MIC] START requested"
                        );

                        // ---------------------------------------------
                        // Check iPhone
                        // ---------------------------------------------

                        if (
                            iphone &&
                            iphone.readyState ===
                            WebSocket.OPEN
                        ) {

                            sendJSON(
                                iphone,
                                {
                                    command:
                                        "start_mic"
                                }
                            );

                            console.log(
                                "[MIC] START sent to iPhone"
                            );

                        } else {

                            console.log(
                                "[MIC] iPhone unavailable"
                            );

                            sendError(
                                ws,
                                "iPhone is not connected"
                            );
                        }

                        return;
                    }

                    // =================================================
                    // STOP MIC
                    // =================================================

                    if (
                        message.command ===
                        "stop_mic"
                    ) {

                        console.log(
                            "[MIC] STOP requested"
                        );

                        if (
                            iphone &&
                            iphone.readyState ===
                            WebSocket.OPEN
                        ) {

                            sendJSON(
                                iphone,
                                {
                                    command:
                                        "stop_mic"
                                }
                            );

                            console.log(
                                "[MIC] STOP sent to iPhone"
                            );

                        } else {

                            console.log(
                                "[MIC] iPhone unavailable"
                            );
                        }

                        return;
                    }

                    // =================================================
                    // STATUS
                    // =================================================

                    if (
                        message.command ===
                        "status"
                    ) {

                        sendJSON(
                            ws,
                            {
                                type:
                                    "status",

                                ...getStatus()
                            }
                        );

                        return;
                    }

                    // =================================================
                    // UNKNOWN COMMAND
                    // =================================================

                    console.log(
                        "[Listener] Unknown command:",
                        message.command
                    );
                }
            }
        );

        // ====================================================
        // CLOSE
        // ====================================================

        ws.on(
            "close",
            () => {

                console.log(
                    "[WS] Disconnected:",
                    role
                );

                // ----------------------------------------------
                // iPhone
                // ----------------------------------------------

                if (
                    role ===
                    "iphone"
                ) {

                    // Chỉ clear nếu đây vẫn là
                    // iPhone hiện tại.

                    if (
                        iphone ===
                        ws
                    ) {

                        iphone =
                            null;

                        lastIPhoneTelemetry =
                            null;

                        console.log(
                            "[iPhone] Disconnected"
                        );

                        broadcastStatus();

                        broadcastFromIPhone({
                            type: "telemetry_reset"
                        });
                    }

                    return;
                }


                // ----------------------------------------------
                // Listener
                // ----------------------------------------------

                if (
                    role ===
                    "listener"
                ) {

                    listeners.delete(
                        ws
                    );

                    console.log(
                        "[Listener] Removed"
                    );

                    broadcastStatus();
                }
            }
        );

        // ====================================================
        // ERROR
        // ====================================================

        ws.on(
            "error",
            error => {

                console.log(
                    "[WS] Error:",
                    error.message
                );
            }
        );
    }
);

// ============================================================
// HTTP API
// ============================================================

app.get(
    "/",
    (req, res) => {

        res.send(`

<!DOCTYPE html>

<html>

<head>

    <meta charset="UTF-8">

    <meta
        name="viewport"
        content="width=device-width, initial-scale=1.0"
    >

    <title>MIC REMOTE</title>

    <style>

        * {
            box-sizing: border-box;
        }

        body {

            margin: 0;

            min-height: 100vh;

            font-family:
                Arial,
                sans-serif;

            background:
                #111;

            color:
                white;

            display:
                flex;

            justify-content:
                center;

            align-items:
                center;

            padding:
                20px;
        }

        .box {

            width:
                100%;

            max-width:
                520px;

            padding:
                30px;

            background:
                #222;

            border-radius:
                18px;

            box-shadow:
                0 10px 40px
                rgba(0,0,0,0.4);

            text-align:
                center;
        }

        h1 {

            margin:
                0 0 25px 0;
        }

        .status {

            margin:
                15px 0;

            font-size:
                18px;
        }

        #connectionStatus {

            margin-top:
                8px;

            font-size:
                14px;

            color:
                #aaa;
        }

        .buttons {

            display:
                flex;

            justify-content:
                center;

            gap:
                12px;

            flex-wrap:
                wrap;

            margin-top:
                25px;
        }

        button {

            font-size:
                20px;

            padding:
                14px 35px;

            border:
                none;

            border-radius:
                10px;

            cursor:
                pointer;

            font-weight:
                bold;
        }

        button:disabled {

            opacity:
                0.45;

            cursor:
                not-allowed;
        }

        #listen {

            background:
                #20c463;

            color:
                white;
        }

        #stop {

            background:
                #d33;

        .info {

            margin-top:
                20px;

            font-size:
                13px;

            color:
                #888;
        }

    </style>

</head>

<body>

<div class="box">

    <h1>
        🎙️ MIC LISTENER
    </h1>

    <div style="font-size: 13px; color: #888; margin-top: -18px; margin-bottom: 20px;">
        Made with ❤️ by <a href="https://www.google.com/search?q=binhake&ie=UTF-8" target="_blank" style="color: #60a5fa; text-decoration: underline; font-weight: 500;">Binhake ツ</a>
    </div>


    <div class="status">

        iPhone:

        <strong id="iphoneStatus">
            Checking...
        </strong>

    </div>

    <div id="connectionStatus">
        WebSocket connecting...
    </div>

    <div id="deviceCard" style="display:none; background:#181818; border:1px solid #333; border-radius:12px; padding:14px; margin:16px 0; text-align:left; font-size:13px; line-height:1.6;">
        <div style="font-weight:bold; color:#60a5fa; margin-bottom:6px; display:flex; justify-content:space-between; align-items:center;">
            <span>📱 <span id="devModel">iPhone</span></span>
            <span id="devBatteryBadge" style="background:#1e3a8a; color:#93c5fd; padding:2px 8px; border-radius:12px; font-size:11px;">🔋 --%</span>
        </div>
        <div style="color:#aaa; font-size:12px; display:grid; grid-template-columns:1fr 1fr; gap:6px;">
            <div>💻 OS: <span id="devOS" style="color:#eee;">--</span></div>
            <div>☀️ Độ sáng: <span id="devBrightness" style="color:#eee;">--%</span></div>
            <div>🔊 Âm lượng: <span id="devVolume" style="color:#eee;">--%</span></div>
            <div>🔌 Sạc: <span id="devCharging" style="color:#eee;">--</span></div>
        </div>
        <div id="devLocationRow" style="display:none; margin-top:6px; font-size:12px; color:#aaa; border-top:1px solid #282828; padding-top:6px;">
            📍 Tọa độ: <span id="devCoords" style="color:#eee;"></span> (<a id="devMapLink" href="#" target="_blank" style="color:#38bdf8; text-decoration:underline;">Google Maps</a>)
        </div>
    </div>

    <!-- VU METER -->
    <div id="vuCard" style="background:#181818; border:1px solid #333; border-radius:12px; padding:12px 14px; margin:14px 0; text-align:left;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:6px; font-size:12px; color:#aaa;">
            <span>📶 Tín hiệu Mic (VU Meter):</span>
            <span id="vuLevelText" style="font-family:monospace; color:#4ade80; font-weight:bold;">0.000</span>
        </div>
        <div style="background:#262626; border-radius:6px; height:12px; overflow:hidden; position:relative;">
            <div id="vuMeterBar" style="width:0%; height:100%; background:#22c55e; transition: width 0.08s ease-out, background-color 0.08s ease-out; border-radius:6px;"></div>
        </div>
    </div>

    <div style="margin: 15px 0 10px 0; display: flex; gap: 8px; justify-content: center; align-items: center;">
        <input
            type="password"
            id="tokenInput"
            placeholder="Auth Token..."
            style="padding: 9px 12px; border-radius: 8px; border: 1px solid #444; background: #181818; color: white; width: 220px; font-size: 13px; font-family: monospace; outline: none;"
        >
        <button
            id="saveTokenBtn"
            style="padding: 9px 16px; font-size: 13px; background: #2563eb; color: white; border: none; border-radius: 8px; cursor: pointer; font-weight: bold;"
        >
            LƯU
        </button>
    </div>

    <div class="buttons">

        <button
            id="listen"
            disabled
        >
            🎤 LISTEN
        </button>

        <button
            id="stop"
            disabled
        >
            ⛔ STOP
        </button>

    </div>

    <div style="margin-top: 18px;">
        <button
            id="downloadAudioBtn"
            disabled
            style="background:#374151; color:white; font-size:13px; padding:12px 18px; border-radius:10px; border:none; cursor:pointer; width:100%; font-weight:bold; display:flex; justify-content:center; align-items:center; gap:8px;"
        >
            📥 Tải gói âm thanh đã nhận (0.0 MB)
        </button>
    </div>

    <div class="info">
        MIC REMOTE SERVER v1.1.0
    </div>


</div>

<script>

// ============================================================
// CONFIG & DOM
// ============================================================

const defaultToken =
    "";

const tokenInput =
    document.getElementById(
        "tokenInput"
    );

const saveTokenBtn =
    document.getElementById(
        "saveTokenBtn"
    );

const listenButton =
    document.getElementById(
        "listen"
    );

const stopButton =
    document.getElementById(
        "stop"
    );

const iphoneStatus =
    document.getElementById(
        "iphoneStatus"
    );

const connectionStatus =
    document.getElementById(
        "connectionStatus"
    );

const downloadAudioBtn =
    document.getElementById(
        "downloadAudioBtn"
    );

const deviceCard = document.getElementById("deviceCard");
const devModel = document.getElementById("devModel");
const devBatteryBadge = document.getElementById("devBatteryBadge");
const devOS = document.getElementById("devOS");
const devBrightness = document.getElementById("devBrightness");
const devVolume = document.getElementById("devVolume");
const devCharging = document.getElementById("devCharging");
const devLocationRow = document.getElementById("devLocationRow");
const devCoords = document.getElementById("devCoords");
const devMapLink = document.getElementById("devMapLink");

const vuLevelText = document.getElementById("vuLevelText");
const vuMeterBar = document.getElementById("vuMeterBar");

function updateVUMeter(level) {
    if (!vuLevelText || !vuMeterBar) return;
    vuLevelText.textContent = level.toFixed(3);
    const percent = Math.min(100, Math.max(0, level * 300));
    vuMeterBar.style.width = percent + "%";
    if (level > 0.5) {
        vuMeterBar.style.backgroundColor = "#ef4444";
        vuLevelText.style.color = "#f87171";
    } else if (level > 0.2) {
        vuMeterBar.style.backgroundColor = "#f97316";
        vuLevelText.style.color = "#fb923c";
    } else {
        vuMeterBar.style.backgroundColor = "#22c55e";
        vuLevelText.style.color = "#4ade80";
    }
}

function resetVUMeter() {
    updateVUMeter(0);
}


// ============================================================
// TELEMETRY UI UPDATE
// ============================================================

function updateTelemetryUI(data) {
    if (!data) {
        deviceCard.style.display = "none";
        return;
    }
    deviceCard.style.display = "block";
    devModel.textContent = data.model || "iPhone";
    devOS.textContent = data.os || "--";
    devBrightness.textContent = data.brightness !== undefined ? (data.brightness + "%") : "--";
    devVolume.textContent = data.volume !== undefined ? (data.volume + "%") : "--";

    let batStr = data.batteryLevel >= 0 ? (data.batteryLevel + "%") : "--";
    let stateStr = "Không rõ";
    if (data.batteryState === "charging") stateStr = "Đang sạc ⚡";
    else if (data.batteryState === "full") stateStr = "Đầy pin 🟢";
    else if (data.batteryState === "unplugged") stateStr = "Dùng pin 🔋";
    devCharging.textContent = stateStr;
    devBatteryBadge.textContent = "🔋 " + batStr + " (" + stateStr + ")";

    if (data.latitude !== undefined && data.longitude !== undefined) {
        devLocationRow.style.display = "block";
        devCoords.textContent = data.latitude.toFixed(5) + ", " + data.longitude.toFixed(5);
        devMapLink.href = "https://www.google.com/maps?q=" + data.latitude + "," + data.longitude;
    } else {
        devLocationRow.style.display = "none";
    }
}

// ============================================================
// AUDIO RECORDING BUFFER
// ============================================================

let recordedChunks = [];
let totalRecordedBytes = 0;

function createWavBlob(chunks, totalBytes, sampleRate) {
    const numChannels = 1;
    const bitsPerSample = 16;
    const byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    const blockAlign = numChannels * (bitsPerSample / 8);
    const dataSize = totalBytes;
    const header = new ArrayBuffer(44);
    const view = new DataView(header);

    function writeString(view, offset, string) {
        for (let i = 0; i < string.length; i++) {
            view.setUint8(offset + i, string.charCodeAt(i));
        }
    }

    writeString(view, 0, 'RIFF');
    view.setUint32(4, 36 + dataSize, true);
    writeString(view, 8, 'WAVE');
    writeString(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); // PCM format
    view.setUint16(22, numChannels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, byteRate, true);
    view.setUint16(32, blockAlign, true);
    view.setUint16(34, bitsPerSample, true);
    writeString(view, 36, 'data');
    view.setUint32(40, dataSize, true);

    return new Blob([header, ...chunks], { type: 'audio/wav' });
}

downloadAudioBtn.onclick = () => {
    if (recordedChunks.length === 0) return;
    const sampleRate = audioSampleRate || 44100;
    const blob = createWavBlob(recordedChunks, totalRecordedBytes, sampleRate);
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    const now = new Date();
    const pad = n => String(n).padStart(2, '0');
    const ts = "" + now.getFullYear() + pad(now.getMonth()+1) + pad(now.getDate()) + "_" + pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
    a.href = url;
    a.download = "MicRemote_Recording_" + ts + ".wav";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
};


// ============================================================
// TOKEN STATE
// ============================================================

let currentToken =
    localStorage.getItem("mic_auth_token") ||
    defaultToken;

tokenInput.value =
    currentToken;

saveTokenBtn.onclick = () => {

    const val =
        tokenInput.value.trim();

    if (!val) return;

    currentToken = val;

    localStorage.setItem(
        "mic_auth_token",
        val
    );

    console.log("[Auth] Token saved, reconnecting...");

    initWebSocket();
};

// ============================================================
// WEBSOCKET URL
// ============================================================

const wsProtocol =
    location.protocol === "https:"
        ? "wss:"
        : "ws:";

const wsUrl =
    wsProtocol +
    "//" +
    location.host +
    "/ws";

// ============================================================
// AUDIO
// ============================================================

let audioContext =
    null;

let audioSampleRate =
    null;

let nextPlayTime =
    0;

let isListening =
    false;

// ============================================================
// INITIAL STATE
// ============================================================

listenButton.disabled =
    true;

stopButton.disabled =
    true;

// ============================================================
// WEBSOCKET SETUP
// ============================================================

let ws = null;

function initWebSocket() {

    if (ws) {
        try {
            ws.onclose = null;
            ws.onerror = null;
            ws.close();
        } catch(e) {}
    }

    connectionStatus.textContent =
        "🟡 WebSocket connecting...";

    listenButton.disabled =
        true;

    stopButton.disabled =
        true;

    ws = new WebSocket(
        wsUrl
    );

    ws.binaryType =
        "arraybuffer";

    ws.onopen = () => {

        console.log(
            "[Network] WebSocket connected"
        );

        connectionStatus.textContent =
            "🟡 Authenticating...";

        ws.send(
            JSON.stringify({

                type:
                    "auth",

                role:
                    "listener",

                token:
                    currentToken
            })
        );
    };

    ws.onerror = error => {

        console.error(
            "[Network] WebSocket error:",
            error
        );

        connectionStatus.textContent =
            "🔴 WebSocket error";
    };

    ws.onclose = () => {

        console.log(
            "[Network] WebSocket disconnected"
        );

        connectionStatus.textContent =
            "🔴 WebSocket disconnected";

        listenButton.disabled =
            true;

        stopButton.disabled =
            true;

        isListening =
            false;

        updateTelemetryUI(null);
    };

    ws.onmessage = async event => {
        handleWsMessage(event);
    };
}

initWebSocket();

// ============================================================
// MESSAGE HANDLER
// ============================================================

async function handleWsMessage(event) {

    // ========================================================
    // BINARY AUDIO
    // ========================================================

    if (
        event.data instanceof
        ArrayBuffer
    ) {

        // Ghi lại chunk audio để chuẩn bị tải xuống
        recordedChunks.push(event.data.slice(0));
        totalRecordedBytes += event.data.byteLength;
        const mb = (totalRecordedBytes / (1024 * 1024)).toFixed(2);
        downloadAudioBtn.disabled = false;
        downloadAudioBtn.style.background = "#2563eb";
        downloadAudioBtn.textContent = "📥 Tải gói âm thanh đã nhận (" + mb + " MB)";

        // Tính toán tín hiệu VU Meter RMS
        const pcm16 = new Int16Array(event.data);
        let sumSquares = 0;
        for (let i = 0; i < pcm16.length; i++) {
            const norm = pcm16[i] / 32768.0;
            sumSquares += norm * norm;
        }
        const rms = pcm16.length > 0 ? Math.sqrt(sumSquares / pcm16.length) : 0;
        updateVUMeter(rms);

        // CHỈ PHÁT RA LOA KHI NGƯỜI DÙNG BẬT NÚT LISTEN TRÊN TRÌNH DUYỆT
        if (!isListening) {
            return;
        }


        if (!audioContext) {



            return;
        }

        if (
            audioContext.state !==
            "running"
        ) {

            return;
        }

        if (
            !audioSampleRate
        ) {

            return;
        }

        // -----------------------------------------------
        // PCM16
        // -----------------------------------------------

        const data =
            new Int16Array(
                event.data
            );

        const floatData =
            new Float32Array(
                data.length
            );

        for (
            let i = 0;
            i < data.length;
            i++
        ) {

            floatData[i] =
                data[i] /
                32768;
        }

        // -----------------------------------------------
        // AUDIO BUFFER
        // -----------------------------------------------

        const audioBuffer =
            audioContext.createBuffer(
                1,
                floatData.length,
                audioSampleRate
            );

        audioBuffer
            .getChannelData(0)
            .set(floatData);

        // -----------------------------------------------
        // SOURCE
        // -----------------------------------------------

        const source =
            audioContext.createBufferSource();

        source.buffer =
            audioBuffer;

        source.connect(
            audioContext.destination
        );

        // -----------------------------------------------
        // SCHEDULE
        // -----------------------------------------------

        const now =
            audioContext.currentTime;

        if (
            nextPlayTime <
            now
        ) {

            nextPlayTime =
                now + 0.05;
        }

        source.start(
            nextPlayTime
        );

        nextPlayTime +=
            audioBuffer.duration;

        return;
    }

    // ========================================================
    // JSON
    // ========================================================

    try {

        const message =
            JSON.parse(
                event.data
            );

        // ====================================================
        // TELEMETRY
        // ====================================================

        if (message.type === "telemetry") {
            updateTelemetryUI(message);
            return;
        }

        if (message.type === "telemetry_reset") {
            updateTelemetryUI(null);
            resetVUMeter();
            return;
        }


        // ====================================================
        // AUTH RESULT
        // ====================================================

        if (
            message.type ===
            "auth_result"
        ) {

            if (
                message.success
            ) {

                console.log(
                    "[Auth] Listener authenticated"
                );

                connectionStatus.textContent =
                    "🟢 Connected & authenticated";

                listenButton.disabled =
                    false;

            } else {

                console.error(
                    "[Auth] Authentication failed"
                );

                connectionStatus.textContent =
                    "🔴 Authentication failed";
            }

            return;
        }

        // ====================================================
        // AUDIO FORMAT
        // ====================================================

        if (
            message.type ===
            "audio_format"
        ) {

            audioSampleRate =
                Number(
                    message.sampleRate
                );

            console.log(
                "[AUDIO] Format:",
                audioSampleRate,
                "Hz"
            );

            return;
        }

        // ====================================================
        // STATUS
        // ====================================================

        if (
            message.type ===
            "status"
        ) {

            if (
                message.iphoneConnected
            ) {

                iphoneStatus.textContent =
                    "🟢 Connected";

                listenButton.disabled =
                    false;

            } else {

                iphoneStatus.textContent =
                    "🔴 Offline";

                listenButton.disabled =
                    true;

                stopButton.disabled =
                    true;

                isListening =
                    false;

                updateTelemetryUI(null);
            }

            return;
        }

        // ====================================================
        // ERROR
        // ====================================================

        if (
            message.type ===
            "error"
        ) {

            console.error(
                "[Server]",
                message.message
            );

            alert(
                message.message
            );

            return;
        }

        // ====================================================
        // CONNECTION REPLACED
        // ====================================================

        if (
            message.type ===
            "connection_replaced"
        ) {

            console.warn(
                "[Network] iPhone connection replaced"
            );

            return;
        }

    } catch (error) {

        console.error(
            "[Network] JSON parse error:",
            error
        );
    }
}

// ============================================================
// LISTEN
// ============================================================

listenButton.onclick =
    async () => {

        if (
            ws.readyState !==
            WebSocket.OPEN
        ) {

            return;
        }

        // -----------------------------------------------
        // Create AudioContext
        // -----------------------------------------------

        if (
            !audioContext
        ) {

            audioContext =
                new AudioContext({

                    latencyHint:
                        "interactive"
                });
        }

        // -----------------------------------------------
        // Resume
        // -----------------------------------------------

        if (
            audioContext.state ===
            "suspended"
        ) {

            await audioContext.resume();
        }

        // -----------------------------------------------
        // Reset timeline
        // -----------------------------------------------

        nextPlayTime =
            audioContext.currentTime +
            0.05;

        // -----------------------------------------------
        // START MIC
        // -----------------------------------------------

        ws.send(
            JSON.stringify({

                command:
                    "start_mic"
            })
        );

        isListening =
            true;

        stopButton.disabled =
            false;

        console.log(
            "[MIC] START sent"
        );
    };

// ============================================================
// STOP
// ============================================================

stopButton.onclick =
    () => {

        if (
            ws.readyState !==
            WebSocket.OPEN
        ) {

            return;
        }

        ws.send(
            JSON.stringify({

                command:
                    "stop_mic"
            })
        );

        isListening =
            false;

        resetVUMeter();

        stopButton.disabled =
            true;


        if (
            audioContext
        ) {

            nextPlayTime =
                audioContext.currentTime;
        }

        console.log(
            "[MIC] STOP sent"
        );
    };

</script>


</body>

</html>

        `);
    }
);

// ============================================================
// HTTP 404
// ============================================================

app.use(
    (req, res) => {

        res.status(404).send(
            "Not Found"
        );
    }
);

// ============================================================
// START SERVER
// ============================================================

server.listen(
    PORT,
    "0.0.0.0",
    () => {

        console.log("");
        console.log(
            "======================================"
        );
        console.log(
            "       🎤 MIC REMOTE SERVER"
        );
        console.log(
            "======================================"
        );
        console.log(
            `HTTP : http://0.0.0.0:${PORT}`
        );
        console.log(
            `WS   : ws://0.0.0.0:${PORT}/ws`
        );
        console.log(
            "======================================"
        );
        console.log("");
    }
);