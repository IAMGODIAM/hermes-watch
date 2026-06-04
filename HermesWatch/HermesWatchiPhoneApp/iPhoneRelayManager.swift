//
//  iPhoneRelayManager.swift
//  HermesWatch iPhone App
//
//  Core relay logic:
//  1. Receives audio data from Watch via WatchConnectivity
//  2. Forwards to Hermes Gateway via WebSocket
//  3. Receives TTS audio + transcript + response text
//  4. Sends response back to Watch
//

import Foundation
import WatchConnectivity
import Network

class iPhoneRelayManager: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var watchConnected: Bool = false
    @Published var hermesConnected: Bool = false
    @Published var transcriptLog: [String] = []

    // MARK: - Configuration
    @Published var gatewayHost: String = "192.168.1.100"
    @Published var gatewayPort: String = "8420"
    @Published var useWSS: Bool = false

    // MARK: - Private
    private var wcSession: WCSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pendingCompletions: [String: ([String: Any]) -> Void] = [:]

    // MARK: - Lifecycle
    func start() {
        setupWatchConnectivity()
        connectHermesGateway()
    }

    // MARK: - WatchConnectivity Setup
    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            log("WCSession not supported on this device")
            return
        }
        wcSession = WCSession.default
        wcSession?.delegate = self
        wcSession?.activate()
    }

    // MARK: - Hermes Gateway WebSocket
    func reconnectHermes() {
        disconnectHermes()
        connectHermesGateway()
    }

    private func connectHermesGateway() {
        let scheme = useWSS ? "wss" : "ws"
        let port = gatewayPort.isEmpty ? "8420" : gatewayPort
        guard let url = URL(string: "\(scheme)://\(gatewayHost):\(port)/ws/voice") else {
            log("Invalid gateway URL")
            return
        }

        log("Connecting to Hermes at \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        urlSession = URLSession(configuration: config)

        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Wait for connection
        receiveWebSocketMessage()

        // Send a ping to verify
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sendPing()
        }
    }

    private func disconnectHermes() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        hermesConnected = false
    }

    private func sendPing() {
        let ping: [String: Any] = ["type": "ping", "timestamp": Date().timeIntervalSince1970]
        sendToHermes(ping)
    }

    // MARK: - WebSocket Communication
    func sendToHermes(_ message: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        guard let task = webSocketTask else {
            log("WebSocket not connected")
            completion?(["error": "WebSocket not connected"])
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: message)

            // If this is an audio message, send as binary + metadata
            if message["type"] as? String == "voice_audio" {
                // Send binary audio data directly
                if let audioData = message["audio"] as? Data {
                    let wsMessage = URLSessionWebSocketTask.Message.data(audioData)
                    task.send(wsMessage) { [weak self] error in
                        if let error = error {
                            self?.log("WebSocket send error: \(error.localizedDescription)")
                        }
                    }

                    // Send metadata alongside
                    var metadata = message
                    metadata.removeValue(forKey: "audio")
                    metadata["audio_size"] = audioData.count
                    let metaJSON = try? JSONSerialization.data(withJSONObject: metadata)
                    if let metaJSON = metaJSON {
                        task.send(.data(metaJSON)) { _ in }
                    }
                }
            } else {
                let wsMessage = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8) ?? "")
                task.send(wsMessage) { [weak self] error in
                    if let error = error {
                        self?.log("WebSocket send error: \(error.localizedDescription)")
                    }
                }
            }

            if let completion = completion {
                let requestId = message["request_id"] as? String ?? UUID().uuidString
                pendingCompletions[requestId] = completion
            }
        } catch {
            log("JSON encode error: \(error.localizedDescription)")
            completion?(["error": error.localizedDescription])
        }
    }

    private func receiveWebSocketMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleWebSocketMessage(message)
                // Keep listening
                self?.receiveWebSocketMessage()

            case .failure(let error):
                self?.log("WebSocket receive error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.hermesConnected = false
                }
                // Auto-reconnect after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.connectHermesGateway()
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            handleHermesMessage(json)

        case .data(let data):
            // Could be TTS audio data or JSON metadata
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                handleHermesMessage(json)
            }
            // Otherwise it's audio — handled by specific response handlers

        @unknown default:
            break
        }
    }

    private func handleHermesMessage(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            switch type {
            case "pong":
                self?.hermesConnected = true
                self?.log("✓ Hermes Gateway connected")

            case "transcript":
                if let text = json["text"] as? String {
                    self?.log("You: \(text)")
                }

            case "response":
                if let text = json["text"] as? String {
                    self?.log("Hermes: \(text)")
                }

            case "error":
                if let error = json["message"] as? String {
                    self?.log("Hermes error: \(error)")
                }

            default:
                break
            }
        }
    }

    // MARK: - Send Response to Watch
    private func sendToWatch(_ response: [String: Any]) {
        guard let session = wcSession, session.isReachable else {
            log("Watch not reachable for response")
            return
        }

        session.sendMessage(response, replyHandler: nil) { [weak self] error in
            self?.log("Failed to send response to watch: \(error.localizedDescription)")
        }
    }

    // MARK: - Logging
    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self?.transcriptLog.append("[\(timestamp)] \(message)")
        }
    }
}

// MARK: - WCSessionDelegate
extension iPhoneRelayManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.watchConnected = activationState == .activated && session.isReachable
            self.log("WCSession activated: \(activationState.rawValue), reachable: \(session.isReachable)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async {
            self.watchConnected = false
            self.log("WCSession became inactive")
        }
    }

    func sessionDidDeactivate(_ session: WSCession) {
        DispatchQueue.main.async {
            self.watchConnected = false
            self.log("WCSession deactivated")
        }
        // Reactivate
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.watchConnected = session.isReachable
            self.log("Watch reachability changed: \(session.isReachable)")
        }
    }

    // MARK: - Handle Watch Messages
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleWatchMessage(message, replyHandler: replyHandler)
    }

    func session(_ session: WSCession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        // Handle binary audio data from Watch
        handleWatchAudioData(messageData, replyHandler: replyHandler)
    }

    private func handleWatchMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let type = message["type"] as? String else {
            replyHandler(["error": "Unknown message type"])
            return
        }

        switch type {
        case "voice_audio":
            guard let audioData = message["audio"] as? Data else {
                replyHandler(["error": "No audio data"])
                return
            }

            log("Received audio from Watch: \(audioData.count) bytes")

            // Generate request ID for this exchange
            let requestId = UUID().uuidString

            // Store reply handler
            pendingCompletions[requestId] = { [weak self] response in
                DispatchQueue.main.async {
                    replyHandler(response)
                }
            }

            // Forward to Hermes Gateway
            var hermesMessage = message
            hermesMessage["request_id"] = requestId
            hermesMessage["source"] = "apple_watch"

            sendToHermes(hermesMessage) { [weak self] response in
                replyHandler(response)
                self?.pendingCompletions.removeValue(forKey: requestId)
            }

        case "ping":
            replyHandler(["type": "pong", "timestamp": Date().timeIntervalSince1970])

        default:
            replyHandler(["error": "Unsupported message type: \(type)"])
        }
    }

    private func handleWatchAudioData(_ data: Data, replyHandler: @escaping (Data) -> Void) {
        let requestId = UUID().uuidString
        let message: [String: Any] = [
            "type": "voice_audio",
            "audio": data,
            "request_id": requestId,
            "format": "aac",
            "sample_rate": 16000
        ]

        sendToHermes(message) { response in
            if let ttsData = response["tts_audio"] as? Data {
                replyHandler(ttsData)
            } else {
                // Return empty data on error
                replyHandler(Data())
            }
        }
    }

    // MARK: - Background Transfer (fallback)
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error = error {
            log("Background transfer failed: \(error.localizedDescription)")
        }
    }
}
