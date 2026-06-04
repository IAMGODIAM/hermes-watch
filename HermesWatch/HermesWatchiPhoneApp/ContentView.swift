//
//  ContentView.swift
//  HermesWatch iPhone App
//
//  Relay UI: Shows connection status, transcript log, and Hermes Gateway config.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var relay = iPhoneRelayManager()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Status cards
                HStack(spacing: 12) {
                    StatusCard(
                        title: "Watch",
                        status: relay.watchConnected ? "Connected" : "Disconnected",
                        color: relay.watchConnected ? .green : .red,
                        icon: "applewatch"
                    )
                    StatusCard(
                        title: "Hermes",
                        status: relay.hermesConnected ? "Connected" : "Disconnected",
                        color: relay.hermesConnected ? .green : .red,
                        icon: "network"
                    )
                }
                .padding(.horizontal)

                // Hermes Gateway config
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hermes Gateway")
                        .font(.headline)

                    TextField("Host (e.g. 192.168.1.100)", text: $relay.gatewayHost)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .keyboardType(.decimalPad)

                    HStack {
                        TextField("Port", text: $relay.gatewayPort)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .frame(width: 80)

                        Toggle("WSS", isOn: $relay.useWSS)
                            .toggleStyle(.switch)
                    }

                    Button(action: { relay.reconnectHermes() }) {
                        Label("Connect", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)

                // Transcript log
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(relay.transcriptLog, id: \.self) { entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(entry.hasPrefix("Hermes:") ? .cyan : .primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Hermes Relay")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            relay.start()
        }
    }
}

struct StatusCard: View {
    let title: String
    let status: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(status)
                .font(.caption2)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

#Preview {
    ContentView()
}
