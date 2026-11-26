import AppKit
import Carbon.HIToolbox
import Observation
import os

enum HotKeyAction: String, CaseIterable, Identifiable {
    case volumeUp, volumeDown, mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        }
    }

    /// ⌃⌥⌘↑ / ⌃⌥⌘↓ / ⌃⌥⌘M: unlikely to clash with window managers or apps.
    var defaultCombo: KeyCombo {
        let mods = UInt32(controlKey | optionKey | cmdKey)
        switch self {
        case .volumeUp: return KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: mods)
        case .volumeDown: return KeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: mods)
        case .mute: return KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: mods)
        }
    }

    var repeats: Bool { self != .mute }
}

/// A key plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a key-down event; `nil` unless a ⌘, ⌥ or ⌃ modifier is held (function keys excepted).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let isFunctionKey = Self.functionKeys[Int(code)] != nil
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 || isFunctionKey else { return nil }
        keyCode = code
        modifiers = mods
    }

    /// Whether the key and all of its modifiers are physically held right now.
    var isHeld: Bool {
        guard CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else { return false }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let required: [(Int, CGEventFlags)] = [
            (cmdKey, .maskCommand), (optionKey, .maskAlternate), (controlKey, .maskControl), (shiftKey, .maskShift),
        ]
        return required.allSatisfy { carbon, flag in modifiers & UInt32(carbon) == 0 || flags.contains(flag) }
    }

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    private var keyName: String {
        if let name = Self.specialKeys[Int(keyCode)] ?? Self.functionKeys[Int(keyCode)] { return name }
        // Ask the current keyboard layout what this key types.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    fileprivate static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// System-wide hot keys through Carbon's RegisterEventHotKey (no Accessibility permission
/// needed). Volume keys auto-repeat while held. Also owns shortcut recording, so only one
/// recorder can be active and hot keys stay suspended exactly while it is.
@MainActor @Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// The action whose shortcut is being recorded in Settings, if any.
    private(set) var recordingAction: HotKeyAction?
    /// Bumped whenever registrations change (Settings re-reads shortcuts and availability).
    private(set) var revision = 0

    @ObservationIgnored var handler: ((HotKeyAction) -> Void)?
    /// Re-registers every shortcut from the preferences (set by the app delegate).
    @ObservationIgnored var registerAll: (() -> Void)?

    @ObservationIgnored private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var combos: [HotKeyAction: KeyCombo] = [:]
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?
    private static let signature: OSType = 0x4B45_466D  // 'KEFm'
    private static let log = Logger(subsystem: "KEFMenuBar", category: "hotkeys")

    private init() {}

    func install() {
        guard eventHandler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeyCenter.shared.handle(id: id, pressed: pressed) }
            return noErr
        }, specs.count, &specs, nil, &eventHandler)
    }

    func register(_ combo: KeyCombo?, for action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        combos[action] = nil
        revision += 1
        guard let combo else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: UInt32(HotKeyAction.allCases.firstIndex(of: action)! + 1))
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[action] = ref
            combos[action] = combo
            Self.log.info("hot key registered: \(action.rawValue, privacy: .public) \(combo.display, privacy: .public)")
        } else {
            Self.log.error("hot key unavailable: \(action.rawValue, privacy: .public) \(combo.display, privacy: .public) (status \(status))")
        }
    }

    func isRegistered(_ action: HotKeyAction) -> Bool { refs[action] != nil }

    /// Temporarily release every hot key (while recording a new shortcut).
    func suspend() {
        repeatTask?.cancel()
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        combos.removeAll()
        revision += 1
    }

    // MARK: Recording

    /// Record the next key combination for `action` (⎋ cancels, ⌫ clears). Any other
    /// recording is cancelled first; hot keys are suspended until recording ends.
    func beginRecording(_ action: HotKeyAction, save: @escaping (KeyCombo?) -> Void) {
        endRecording(reregister: false)
        recordingAction = action
        suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let center = HotKeyCenter.shared
                switch Int(event.keyCode) {
                case kVK_Escape:
                    center.endRecording()
                case kVK_Delete, kVK_ForwardDelete:
                    save(nil)
                    center.endRecording()
                default:
                    guard let combo = KeyCombo(event: event) else { NSSound.beep(); return }
                    save(combo)
                    center.endRecording()
                }
            }
            return nil
        }
    }

    func endRecording(reregister: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recordingAction != nil else { return }
        recordingAction = nil
        if reregister { registerAll?() }
    }

    private func handle(id: UInt32, pressed: Bool) {
        repeatTask?.cancel()
        repeatTask = nil
        guard pressed, id >= 1, Int(id) <= HotKeyAction.allCases.count else { return }
        let action = HotKeyAction.allCases[Int(id) - 1]
        handler?(action)
        guard action.repeats, let combo = combos[action] else { return }
        // Auto-repeat while the whole combination is held. The hot-key "released" event is
        // not enough on its own: it never comes if the modifiers are let go first, so each
        // tick checks that the key AND every modifier are still physically down.
        // Bounded as a last resort.
        repeatTask = Task {
            try? await Task.sleep(for: .milliseconds(380))
            for _ in 0..<50 {
                guard !Task.isCancelled, combo.isHeld else { break }
                handler?(action)
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }
}
