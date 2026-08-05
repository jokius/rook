import Testing
@testable import rookCore

struct PaletteSearchKeysTests {
    private struct Row: Equatable {
        let title: String
        let subtitle: String?
    }

    private static let confirmRows = [
        Row(title: "Confirm", subtitle: "cannot be undone"),
        Row(title: "Cancel", subtitle: nil)
    ]

    private static func rank(_ query: String, callerSupplied: Bool) -> [Row] {
        fuzzyRank(query: query, items: confirmRows) {
            paletteSearchKeys(title: $0.title, subtitle: $0.subtitle, callerSupplied: callerSupplied)
        }
    }

    // pins the confirm-row trap: "cannot be undone" matched the refusal query "no" and left the destructive
    // row alone and preselected for Return.
    @Test func refusalQueryLeavesNoRowInACallerSuppliedConfirm() {
        #expect(Self.rank("no", callerSupplied: true).isEmpty)
    }

    @Test func refusalQueryStillMatchesASubtitleInABuiltinPalette() {
        #expect(Self.rank("no", callerSupplied: false) == [Row(title: "Confirm", subtitle: "cannot be undone")])
    }

    @Test func labelStillMatchesInACallerSuppliedPicker() {
        #expect(Self.rank("can", callerSupplied: true) == [Row(title: "Cancel", subtitle: nil)])
    }

    @Test func callerSuppliedRowMatchesItsLabelOnly() {
        #expect(paletteSearchKeys(title: "Confirm", subtitle: "cannot be undone", callerSupplied: true)
            == ["Confirm"])
    }

    @Test func builtinRowMatchesLabelAndSubtitle() {
        #expect(paletteSearchKeys(title: "Go to Session", subtitle: "work · zsh", callerSupplied: false)
            == ["Go to Session", "work · zsh"])
    }

    @Test func builtinRowWithoutSubtitleMatchesItsLabelOnly() {
        #expect(paletteSearchKeys(title: "New Window", subtitle: nil, callerSupplied: false) == ["New Window"])
    }
}

struct PickCustomRowTests {
    @Test func emptyQueryDoesNotOfferCustomRow() {
        #expect(pickCustomRowLabel(query: "", filteredCount: 0, allowCustom: true) == nil)
        #expect(pickCustomRowLabel(query: " \t ", filteredCount: 0, allowCustom: true) == nil)
    }

    @Test func unmatchedQueryOffersCustomRowWhenAllowed() {
        #expect(pickCustomRowLabel(query: "new value", filteredCount: 0, allowCustom: true)
            == "Use \"new value\"")
    }

    @Test func unmatchedQueryDoesNotOfferCustomRowWhenDisallowed() {
        #expect(pickCustomRowLabel(query: "new value", filteredCount: 0, allowCustom: false) == nil)
    }

    @Test func matchingQueryDoesNotOfferCustomRow() {
        #expect(pickCustomRowLabel(query: "one", filteredCount: 1, allowCustom: true) == nil)
    }
}
