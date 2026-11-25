import Foundation
import os

/// The app's own log messages (scene phases, suspend and resume, Bonjour scans), under the
/// same subsystem as the model's. Never logs an address or a speaker identifier.
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "Speakeasy"
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
}
