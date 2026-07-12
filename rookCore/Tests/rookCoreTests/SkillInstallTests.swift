import Testing
@testable import rookCore

struct SkillInstallTests {
    @Test func skillDirectoryComposesUnderAgentBase() {
        #expect(SkillInstall.skillDirectory(home: "/Users/x", base: ".claude") == "/Users/x/.claude/skills/rook")
        #expect(SkillInstall.skillDirectory(home: "/Users/x", base: ".codex") == "/Users/x/.codex/skills/rook")
        #expect(SkillInstall.skillName == "rook")
    }

    @Test func targetsCoverBothWhenBothExist() {
        let t = SkillInstall.installTargets(home: "/h", claudeExists: true, codexExists: true)
        #expect(t == [
            .init(agent: "Claude Code", skillDirectory: "/h/.claude/skills/rook"),
            .init(agent: "Codex", skillDirectory: "/h/.codex/skills/rook"),
        ])
    }

    @Test func targetsCodexOnlyWhenOnlyCodexExists() {
        let t = SkillInstall.installTargets(home: "/h", claudeExists: false, codexExists: true)
        #expect(t == [.init(agent: "Codex", skillDirectory: "/h/.codex/skills/rook")])
    }

    @Test func targetsFallBackToClaudeWhenNeitherExists() {
        let t = SkillInstall.installTargets(home: "/h", claudeExists: false, codexExists: false)
        #expect(t == [.init(agent: "Claude Code", skillDirectory: "/h/.claude/skills/rook")])
    }

    @Test func mayOverwriteWhenDirectoryAbsent() {
        #expect(SkillInstall.mayOverwrite(directoryExists: false, existingSKILL: nil) == true)
    }

    @Test func refusesOverwriteOfDirectoryWithoutSkillFile() {
        #expect(SkillInstall.mayOverwrite(directoryExists: true, existingSKILL: nil) == false)
    }

    @Test func mayOverwriteWhenMarkerPresent() {
        let contents = "---\nx\n---\n\(SkillInstall.marker)\nbody"
        #expect(SkillInstall.mayOverwrite(directoryExists: true, existingSKILL: contents) == true)
    }

    @Test func refusesOverwriteOfForeignSkill() {
        let contents = "---\ndescription: someone else's rook\n---\nbody"
        #expect(SkillInstall.mayOverwrite(directoryExists: true, existingSKILL: contents) == false)
    }
}
