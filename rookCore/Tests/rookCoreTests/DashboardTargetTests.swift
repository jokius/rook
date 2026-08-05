import Foundation
import Testing
@testable import rookCore

/// The `dashboard` pane-ref grammar. It is worth its own low-level suite because the split-on-FIRST-colon
/// rule is what makes a half-resolve impossible: a valid head (`active`, a UUID, a UUID prefix) can never
/// contain a colon, so `surface:<uuid>:left` must fail outright rather than resolving a head of `surface`.
struct DashboardTargetTests {
    @Test(arguments: [
        ("A1B2C3D4", "A1B2C3D4"),
        ("active", "active"),
        ("a", "a")
    ])
    func bareTargetKeepsHeadAndTakesEveryPane(raw: String, head: String) {
        let target = DashboardTarget(rawValue: raw)
        #expect(target?.head == head)
        #expect(target?.pane == nil) // nil = the bare form, which expands to every pane of the session
    }

    @Test(arguments: [
        ("A1B2C3D4:left", "A1B2C3D4", TerminalZoomSurface.primary),
        ("A1B2C3D4:right", "A1B2C3D4", TerminalZoomSurface.split),
        // case-insensitive, and it composes with any head the resolver accepts
        ("A1B2C3D4:LEFT", "A1B2C3D4", TerminalZoomSurface.primary),
        ("A1B2C3D4:Right", "A1B2C3D4", TerminalZoomSurface.split),
        ("active:left", "active", TerminalZoomSurface.primary),
        ("a:right", "a", TerminalZoomSurface.split)
    ])
    func paneSuffixSelectsOneCell(raw: String, head: String, pane: TerminalZoomSurface) {
        let target = DashboardTarget(rawValue: raw)
        #expect(target?.head == head)
        #expect(target?.pane == pane)
    }

    @Test(arguments: [
        "A:lft",        // a typo must be a real error, not a mystery `unresolved` entry
        "A:primary",    // parses as a TerminalZoomSurface but is refused: the read-back emits left/right
        "A:split",
        "A:scratch",    // never a dashboard cell
        "A:overlay",
        "A:",           // empty suffix
        "A::left",      // the first colon wins, so the suffix is ":left"
        ":left",        // empty head
        ":",
        "",             // an empty target used to be a soft `unresolved:` miss; now it fails the command
        "surface:A1B2C3D4:left" // a pasted surface.zoom address fails whole rather than half-resolving
    ])
    func malformedTargetIsRejected(raw: String) {
        #expect(DashboardTarget(rawValue: raw) == nil)
    }
}
