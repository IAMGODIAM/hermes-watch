//
//  ContentView.swift
//  HermesWatch Watch App
//
//  Main UI: Hold-to-talk button with connection status and transcript display.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var voiceSession = VoiceSessionManager()

    var body: some View {
        VStack(spacing: 12) {
            // Connection status indicator
            HStack {
                Circle()
                    .fill(voiceSession.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(voiceSession.isConnected ? "Connected" : "Connecting...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            Spacer()

            // Hermes avatar / status
            VStack(spacing: 4) {
                Image(systemName: "ear.and.waveform")
                    .font(.system(size: 36))
                    .foregroundColor(voiceSession.isRecording ? .red : .cyan)
                    .symbolEffect(.pulse, isActive: voiceSession.isRecording || voiceSession.isPlaying)

                Text(voiceSession.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // Transcript area
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !voiceSession.transcript.isEmpty {
                        Text(voiceSession.transcript)
                            .font(.caption2)
                            .foregroundColor(.primary)
                    }
                    if !voiceSession.responseText.isEmpty {
                        Text(voiceSession.responseText)
                            .font(.caption2)
                            .foregroundColor(.cyan)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 60)

            // Hold-to-talk button
            Button(action: {}) {
                Image(systemName: voiceSession.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(voiceSession.isRecording ? Color.red : Color.cyan)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !voiceSession.isRecording {
                            voiceSession.startRecording()
                        }
                    }
                    .onEnded { _ in
                        voiceSession.stopRecording()
                    }
            )
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .onAppear {
            voiceSession.connect()
        }
    }
}

#Preview {
    ContentView()
}
