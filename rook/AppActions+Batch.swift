import rookCore
import AppKit
import SwiftUI

extension AppActions {
    /// Close one or more sidebar-selected sessions in a window-local store, honoring the same confirmation
    /// and undo-grace settings as the single-session Close command.
    func closeSessions(_ ids: [UUID], in store: AppStore) {
        let sessions = ids.compactMap { store.session(withID: $0) }
        guard !sessions.isEmpty else { return }
        if sessions.count == 1 {
            closeSession(sessions[0].id, in: store)
            return
        }
        guard confirmCloseSessions(sessions) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            if closeGraceUndoEnabled {
                _ = store.softCloseSessions(sessions.map(\.id), grace: effectiveCloseGraceSeconds)
            } else {
                for session in sessions {
                    store.closeSession(session.id)
                }
            }
        }
        focusActiveSession()
    }

    private func confirmCloseSessions(_ sessions: [Session]) -> Bool {
        let settings = settingsModel?.settings
        guard settings?.confirmCloseSession == true,
              !ContentView.shouldBypassCloseConfirmation else { return true }
        // "only when a session is running an agent": prompt only if at least one of the batch has a live agent.
        let runningAgent = sessions.compactMap(\.agentKind).first
        if settings?.confirmCloseOnlyRunningAgent == true, runningAgent == nil { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(sessions.count) Sessions?"
        alert.informativeText = closeConfirmInformativeText(agent: runningAgent, count: sessions.count)
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { settingsModel?.setConfirmCloseSession(false) }
        return response == .alertFirstButtonReturn
    }

    /// sidebar context menus pass their own store so a background window never routes through the
    /// frontmost store by accident.
    func toggleFlags(_ sessionIDs: [UUID], in store: AppStore) {
        let sessions = sessionIDs.compactMap { store.session(withID: $0) }
        guard !sessions.isEmpty else { return }
        let allFlagged = sessions.allSatisfy(\.flagged)
        store.setFlag(!allFlagged, forSessions: sessions.map(\.id))
    }
}
