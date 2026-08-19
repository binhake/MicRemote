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

                        console.log(
                            "[iPhone] Disconnected"
                        );

                        broadcastStatus();
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

            color:
                white;
        }

        audio {

            width:
                100%;

            margin-top:
                25px;
        }

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
        🎤 MIC REMOTE
    </h1>

    <div class="status">

        iPhone:

        <strong id="iphoneStatus">
            Checking...
        </strong>

    </div>

    <div id="connectionStatus">
        WebSocket connecting...
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

    <audio
        id="audio"
        controls
    ></audio>

    <div class="info">
        MIC REMOTE SERVER
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