import KEFAppCore
import KEFKit
import SwiftUI
import UIKit

/// First launch, no speaker known yet: the scan's results and the manual address.
struct OnboardingView: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        let choices = model.speakerChoices
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    SpeakerGlyph(style: .on)
                        .frame(height: 84)
                        .foregroundStyle(.tint)
                    Text("Find your speaker")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Speakeasy looks for KEF speakers on your Wi-Fi network. Make sure the speaker is plugged in and on the same network as this iPhone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(spacing: 0) {
                    if choices.isEmpty {
                        HStack(spacing: 12) {
                            if model.isDiscovering {
                                ProgressView()
                                Text("Looking for speakers…")
                            } else {
                                Image(systemName: "hifispeaker")
                                    .foregroundStyle(.secondary)
                                Text("No speakers found yet")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                    } else {
                        ForEach(choices) { choice in
                            SpeakerRow(choice: choice, isCurrent: false) {
                                ui.connectionChosen()
                                model.choose(choice)
                            }
                            .padding(.vertical, 12)
                            if choice.id != choices.last?.id { Divider() }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))

                VStack(spacing: 14) {
                    Button {
                        Task { await model.discover() }
                    } label: {
                        Label(model.isDiscovering ? "Scanning…" : "Scan Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(model.isDiscovering)

                    if ui.showsManualEntry {
                        VStack(alignment: .leading, spacing: 8) {
                            ManualHostField { text in
                                ui.connectionChosen()
                                model.useManualHost(text)
                            }
                            Text("Your router's list of connected devices shows the speaker's address.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
                    } else {
                        Button("Enter IP Address") {
                            withAnimation { ui.showsManualEntry = true }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task {
            // The connection loop is usually scanning already; scan only if it isn't.
            if !model.isDiscovering, model.discovered.isEmpty { await model.discover() }
        }
    }
}

/// Local Network access is off: say why the app needs it, and where to turn it on.
struct LocalNetworkDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Allow Local Network", systemImage: "network.slash")
        } description: {
            Text("Speakeasy needs Local Network access to find and control your speaker. Turn on Local Network for Speakeasy in Settings.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }
}

/// Looking for the speaker or connecting to it, with nothing cached to show.
struct SearchingView: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.isWideLayout) private var isWide

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text(model.statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Choose Speaker") {
                ui.open(.speakers, isWide: isWide)
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The speaker can't be reached: why, Retry, and another speaker.
struct OfflineView: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.isWideLayout) private var isWide

    var body: some View {
        let retrying = !model.connection.isOffline
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                SpeakerGlyph(style: .offline)
                    .frame(height: 56)
                    .foregroundStyle(.secondary)
            }
        } description: {
            VStack(spacing: 10) {
                if let reason = model.connection.offlineReason ?? ui.lastOfflineReason {
                    Text(reason)
                        .lineLimit(3)
                }
                if retrying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Trying again…")
                    }
                    .font(.footnote)
                }
            }
        } actions: {
            VStack(spacing: 12) {
                Button {
                    model.retry()
                } label: {
                    Text("Retry").frame(minWidth: 160)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    ui.open(.speakers, isWide: isWide)
                } label: {
                    Text("Choose Speaker").frame(minWidth: 160)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    /// "Can't reach Living Room", unless the address isn't one the app knows a name for.
    private var title: String {
        if model.hasKnownName { return "Can't reach \(model.name)" }
        if let host = model.host { return "Can't reach the speaker at \(host)" }
        return "Can't reach the speaker"
    }
}
