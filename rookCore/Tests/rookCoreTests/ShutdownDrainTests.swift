import Foundation
import Testing
@testable import rookCore

struct ShutdownDrainTests {
    @Test func activeCountCountsOnlyActive() {
        #expect(ShutdownDrain.activeCount([.active, .idle, .completed, .blocked, .active]) == 2)
        #expect(ShutdownDrain.activeCount([]) == 0)
        #expect(ShutdownDrain.activeCount([.idle, .completed, .blocked]) == 0)
    }

    @Test func shouldDrainRequiresActiveAgentAndPositiveGrace() {
        #expect(ShutdownDrain.shouldDrain(statuses: [.active], graceSeconds: 5) == true)
        // turned off by the setting
        #expect(ShutdownDrain.shouldDrain(statuses: [.active], graceSeconds: 0) == false)
        // a negative value reads as off, not as "wait forever"
        #expect(ShutdownDrain.shouldDrain(statuses: [.active], graceSeconds: -1) == false)
        // nobody to wait for: an agent is running, but not mid-turn
        #expect(ShutdownDrain.shouldDrain(statuses: [.idle, .completed, .blocked], graceSeconds: 5) == false)
        #expect(ShutdownDrain.shouldDrain(statuses: [], graceSeconds: 5) == false)
    }

    @Test func flagPathSitsNextToTheSocket() {
        #expect(ShutdownDrain.flagPath(socketPath: "/tmp/rook-dev/rook.sock") == "/tmp/rook-dev/shutdown")
        // socket at the root: no leading double slash
        #expect(ShutdownDrain.flagPath(socketPath: "/rook.sock") == "/shutdown")
    }

    @Test func flagMessageIsOneLineAndNamesTheBudget() {
        let message = ShutdownDrain.flagMessage(seconds: 5)
        #expect(message.contains("5"))
        // the hook slurps this as one line via `read`: an inner newline would drop half the text
        #expect(!message.contains("\n"))
    }

    @Test func waitingMessagePluralizesAgents() {
        #expect(ShutdownDrain.waitingMessage(activeCount: 1, secondsLeft: 5).contains("1 agent "))
        #expect(ShutdownDrain.waitingMessage(activeCount: 3, secondsLeft: 2).contains("3 agents "))
    }

    @Test func quitPromptSuffixAppearsOnlyWhenDraining() {
        #expect(ShutdownDrain.quitPromptSuffix(activeCount: 2, graceSeconds: 5)?.contains("2 agents") == true)
        #expect(ShutdownDrain.quitPromptSuffix(activeCount: 0, graceSeconds: 5) == nil)
        #expect(ShutdownDrain.quitPromptSuffix(activeCount: 2, graceSeconds: 0) == nil)
    }

    @Test func agentQuitGraceDefaultsToFifteenAndHonorsZero() {
        // 15, not 5: an agent needs time to READ the warning and act on it, not just receive it
        #expect(AppSettings().effectiveAgentQuitGraceSeconds == 15)
        #expect(AppSettings().effectiveAgentQuitGraceSeconds == AppSettings.defaultAgentQuitGraceSeconds)
        #expect(AppSettings(agentQuitGraceSeconds: 12).effectiveAgentQuitGraceSeconds == 12)
        // 0 is the user's off switch, not "instantly", and it must survive down to shouldDrain
        #expect(AppSettings(agentQuitGraceSeconds: 0).effectiveAgentQuitGraceSeconds == 0)
        #expect(ShutdownDrain.shouldDrain(statuses: [.active],
                                          graceSeconds: AppSettings(agentQuitGraceSeconds: 0)
                                              .effectiveAgentQuitGraceSeconds) == false)
    }
}
