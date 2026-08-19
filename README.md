# 🎤 MicRemote & MicListener

Real-time audio streaming from an iPhone microphone to any device or web browser over Local Network (LAN/Wi-Fi) or Internet via WebSocket.

---

## 📦 .IPA FILES
- **`MicRemote.ipa`**: Microphone broadcaster app (captures and streams audio in real-time).
- **`MicListener.ipa`**: Audio receiver app (plays audio stream with ultra-low latency).

---

## 📱 PREPARE DEVICES
- **x1 iPhone** for microphone broadcaster.
- **x1 Device** running any OS supporting Node.js >= 18.x (PC, Mac, Linux, VPS, etc.) to host the server.
- **Any iPhone** for Listener (or any PC / mobile device with a web browser via WebApp).

---

## ⚙️ INSTALL FLOW

1. **Install Server**:
   - Install Node.js (>= 18.x) on your server device.
   - Clone this repository and install dependencies:
     ```bash
     npm install
     ```
   - Copy `.env.example` to `.env` and configure your `AUTH_TOKEN`:
     ```bash
     cp .env.example .env
     ```
   - Start the server:
     ```bash
     node server.js
     ```

2. **Install iOS Apps**:
   - Install `MicRemote.ipa` to the iPhone prepared for mic (using TrollStore, Sideloadly, AltStore, or Developer Certificate).
   - Install `MicListener.ipa` to any iOS device you want to use for listening (or use the WebApp directly).

---

## 🚀 HOW TO USE

1. **Mic iPhone (Broadcaster)**:
   - Open **MicRemote** app.
   - Type the **Server IP**, **Port** (default: `3000`), and your **Auth Token**.
   - Tap **LƯU** (Save). The app will automatically connect to the server and stay ready in background.

2. **Listener (Receiver)**:
   - **WebApp**: Open `http://<server_ipv4>:3000` in your web browser, enter your Auth Token, and click **LISTEN**.
   - **iOS App**: Open **MicListener**, enter Server IP, Port, and Auth Token, tap **LƯU** (Save), then tap **BẮT ĐẦU NGHE** to play live audio from the mic iPhone.

---

## 🌐 WANT TO ACCESS OVER THE INTERNET (PUBLIC SERVER)?

- **Best & Easiest Method**: Use [Tailscale](https://tailscale.com/).
  - Install Tailscale on the server device.
  - Access the WebApp from anywhere using your server's Tailscale IP: `http://<tailscale_ip>:3000`.
  - If you want to use the iOS `MicRemote` / `MicListener` apps remotely over cellular data / outside networks, install the Tailscale app on your iPhones and use the server's Tailscale IP. That's all!
