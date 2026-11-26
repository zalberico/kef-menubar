import Observation
import SwiftUI

/// Everything one window remembers about its own UI, kept above every layout branch so
/// rotating, resizing or folding never loses it: a panel shown as a sheet and the same
/// panel shown as a column are different views, and SwiftUI would drop their `@State`.
@MainActor @Observable
final class UIState {
    enum Panel: String, Hashable, Sendable {
        case speakers, sound, settings
    }

    /// Screens pushed inside the panel's navigation stack.
    enum Route: Hashable, Sendable {
        #if DEBUG || PROBE
        case diagnostics
        #endif
    }

    /// The panel chosen last. In the wide layout it fills the side column (Sound when none
    /// was chosen); in the compact layouts it is what the sheet shows.
    var panel: Panel?
    /// The compact layouts show ``panel`` as a sheet. Kept apart from the selection so
    /// folding keeps the choice without popping a sheet over the outer screen.
    var isSheetPresented = false
    /// The panel's navigation stack, shared by the sheet and the column.
    var panelPath: [Route] = []

    /// Scroll positions, restored when a layout change rebuilds a scroll view.
    var remoteScroll = ScrollPosition(edge: .top)
    var panelScroll = ScrollPosition(edge: .top)
    var soundScroll = ScrollPosition(edge: .top)
    /// How far Sound is scrolled. `ScrollPosition` doesn't record where the person scrolled
    /// to, so it is tracked here and scrolled back to when the panel moves between the
    /// sheet and the column. Closing the sheet starts it at the top again.
    var soundOffset: CGFloat = 0

    /// The manual address being typed (Speakers and onboarding).
    var manualHostDraft = ""
    /// Onboarding shows the address field.
    var showsManualEntry = false

    /// The offline screen stays up while the connection keeps retrying, instead of
    /// flipping to a spinner on every attempt. Cleared once online or when the person
    /// picks another speaker.
    var showsOffline = false
    /// Why the last attempt failed, kept while the next one runs.
    var lastOfflineReason: String?

    /// The panel the wide layout's column shows.
    var columnPanel: Panel { panel ?? .sound }

    /// Open a panel: in a column when `isWide`, else as a sheet.
    func open(_ panel: Panel, isWide: Bool) {
        if self.panel != panel { panelPath = [] }
        self.panel = panel
        if !isWide { isSheetPresented = true }
    }

    /// The layout changed. Going wide closes the sheet (the column shows its panel);
    /// going back to compact keeps the choice but never reopens a sheet by itself.
    func layoutChanged(isWide: Bool) {
        if isWide { isSheetPresented = false }
    }

    /// The sheet's binding: the system may set it to `false` because the layout changed
    /// (not because it was dismissed), which is ignored unless the layout is still compact.
    func sheetBinding(isWide: Bool) -> Binding<Bool> {
        Binding(
            get: { [unowned self] in !isWide && self.isSheetPresented && self.panel != nil },
            set: { [unowned self] presented in
                if presented { self.isSheetPresented = true } else if !isWide { self.closeSheet() }
            })
    }

    /// The person closed the sheet (Close, or swiping it away).
    func closeSheet() {
        isSheetPresented = false
        soundOffset = 0
    }

    /// A connection change the person asked for (another speaker, an address).
    func connectionChosen() {
        showsOffline = false
        lastOfflineReason = nil
        closeSheet()
    }
}
