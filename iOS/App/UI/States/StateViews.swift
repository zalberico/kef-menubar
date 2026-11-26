import KEFAppCore
import KEFKit
import SwiftUI
import UIKit

/// First launch, no speaker known yet: the scan's results and the manual address.
struct OnboardingView: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @ScaledMetric(relativeTo: .largeTitle) private var cabinetHeight = 132

    var body: some View {
        let choices = model.speakerChoices
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    CabinetTile()
                        .frame(height: min(cabinetHeight, 200))
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
                    // The panel above shows a scan in progress; the button is for after one.
                    if !model.isDiscovering {
                        Button {
                            Task { await model.discover() }
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }

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
            .prominentGlassStyle()
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
    @ScaledMetric(relativeTo: .title) private var cabinetHeight = 124

    var body: some View {
        let retrying = !model.connection.isOffline
        ContentUnavailableView {
            // Not a Label: its icon slot would shrink the cabinet to symbol size.
            let height = min(cabinetHeight, 180)
            VStack(spacing: 14) {
                CabinetTile(isAsleep: true)
                    .frame(width: height, height: height)
                    .overlay(alignment: .bottomTrailing) {
                        // On the tile's lower right corner.
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .orange)
                            .offset(x: 8, y: 8)
                    }
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        } description: {
            VStack(spacing: 10) {
                Text(OfflineExplanation(reason: model.connection.offlineReason ?? ui.lastOfflineReason,
                                        host: model.host).text)
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
                .prominentGlassStyle()
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

    /// "Can't Reach Living Room", or "Can't Reach Speaker" when the app knows no name for
    /// the address (the description gives the address).
    private var title: String {
        model.hasKnownName ? "Can't Reach \(model.name)" : "Can't Reach Speaker"
    }
}

/// The offline screen's description: the model's reason (written for logs, e.g. "Speaker
/// unreachable: 192.0.2.1: The request timed out.") turned into a sentence that says what
/// to check. The raw reason stays in the log.
struct OfflineExplanation {
    let reason: String?
    let host: String?

    var text: String {
        let reason = reason ?? ""
        if reason == "No speaker found" {
            return "No speaker answered on this Wi-Fi network. Check that it's plugged in and on the same network as this iPhone."
        }
        if reason.hasPrefix("A different speaker answered") {
            return "Another speaker answered at \(host ?? "this address"). Choose your speaker again."
        }
        let from = host.map { "No response from \($0)." } ?? "No response from the speaker."
        if reason.hasPrefix("Speaker unreachable") || reason.isEmpty {
            return "\(from) Check that the speaker is on and connected to the same Wi-Fi network as this iPhone."
        }
        return "The speaker at \(host ?? "this address") answered in a way Speakeasy didn't expect. Try again, or restart the speaker."
    }
}
