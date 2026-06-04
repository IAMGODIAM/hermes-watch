//
//  VoiceSessionManager.swift
//  HermesWatch Watch App
//
//  Manages: audio recording, WatchConnectivity bridge, audio playback.
//  Sends audio to iPhone relay, receives TTS response, plays it back.
//

import Foundation
import AVFoundation
import WatchConnectivity
import Combine

class VoiceSessionManager: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isConnected: Bool = false
    @Published var isRecording: Bool = false
    @Published var isPlaying: Bool = false
    @Published var statusText: String = "Tap mic to start"
    @Published var transcript: String = ""
    @Published var responseText: String = ""

    // MARK: - Private
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var session: WCSession?

    // Audio settings optimized for speech
    private let audioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    // MARK: - Lifecycle
    override init() {
        super.init()
        setupAudioSession()
    }

    func connect() {
        guard WCSession.isSupported() else {
            statusText = "WCSession not supported"
            return
        }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    // MARK: - Audio Session Setup
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            statusText = "Audio session error: \(error.localizedDescription)"
        }
    }

    // MARK: - Recording
    func startRecording() {
        // Prepare recording URL
        let tempDir = FileManager.default.temporaryDirectory
        recordingURL = tempDir.appendingPathComponent("hermes_recording_\(Date().timeIntervalSince1970).m4a")

        guard let url = recordingURL else { return }

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: audioSettings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()

            isRecording = true
            statusText = "Listening..."
            transcript = ""
            responseText = ""
        } catch {
            statusText = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        audioRecorder?.stop()
        isRecording = false
        statusText = "Processing..."

        // Send audio to iPhone relay
        sendAudioToRelay()
    }

    // MARK: - Send Audio via WatchConnectivity
    private func sendAudioToRelay() {
        guard let url = recordingURL,
              let audioData = try? Data(contentsOf: url) else {
            statusText = "Failed to read audio"
            return
        }

        guard let session = session, session.isReachable else {
            statusText = "iPhone not reachable"
            // Try transferUserInfo as fallback (works even if iPhone app not foreground)
            sendAudioViaTransfer(audioData)
            return
        }

        let message: [String: Any] = [
            "type": "voice_audio",
            "audio": audioData,
            "sample_rate": 16000,
            "format": "aac",
            "timestamp": Date().timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                self?.handleResponse(reply)
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.statusText = "Send failed, retrying..."
                // Fallback to background transfer
                self?.sendAudioViaTransfer(audioData)
            }
        })
    }

    private func sendAudioViaTransfer(_ audioData: Data) {
        guard let session = session else { return }

        let message: [String: Any] = [
            "type": "voice_audio",
            "audio": audioData,
            "sample_rate": 16000,
            "format": "aac"
        ]

        session.transferUserInfo(message)
        statusText = "Sending (background)..."
    }

    // MARK: - Handle Response
    private func handleResponse(_ reply: [String: Any]) {
        if let transcriptText = reply["transcript"] as? String {
            transcript = "You: \(transcriptText)"
        }

        if let responseText = reply["response_text"] as? String {
            responseText = "Hermes: \(responseText)"
        }

        if let audioData = reply["tts_audio"] as? Data {
            playResponseAudio(audioData)
        } else {
            statusText = "Tap mic to start"
        }

        if let error = reply["error"] as? String {
            statusText = "Error: \(error)"
        }
    }

    // MARK: - Audio Playback
    private func playResponseAudio(_ data: Data) {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()

            isPlaying = true
            statusText = "Hermes is speaking..."
        } catch {
            statusText = "Playback error: \(error.localizedDescription)"
        }
    }
}

// MARK: - WCSessionDelegate
extension VoiceSessionManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            switch activationState {
            case .activated:
                self.isConnected = session.isReachable
                self.statusText = session.isReachable ? "Ready — tap mic" : "Waiting for iPhone..."
            case .inactive:
                self.isConnected = false
                self.statusText = "Session inactive"
            case .notActivated:
                self.isConnected = false
                self.statusText = "Session not activated"
            @unknown default:
                break
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isConnected = session.isReachable
            self.statusText = session.isReachable ? "Ready — tap mic" : "Waiting for iPhone..."
        }
    }

    // Handle background responses from iPhone
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        // Background transfer completed
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.handleResponse(message)
        }
    }
}

// MARK: - AVAudioRecorderDelegate
extension VoiceSessionManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            statusText = "Recording failed"
            isRecording = false
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension VoiceSessionManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.statusText = "Tap mic to start"
        }
    }
}
