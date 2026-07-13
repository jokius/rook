import Testing
@testable import rookCore

struct AgentKindTests {
    @Test(arguments: [
        (["claude"], AgentKind.claude),
        (["codex"], AgentKind.codex),
        (["/opt/homebrew/bin/claude"], AgentKind.claude),
        (["/Users/x/.local/bin/codex", "--model", "gpt-5"], AgentKind.codex),
        (["claude", "--continue"], AgentKind.claude),
    ])
    func classifiesTheAgentByArgv0Basename(_ argv: [String], _ expected: AgentKind) {
        #expect(AgentKind.classify(argv: argv) == expected)
    }

    @Test(arguments: [
        ["vim", "notes.md"],
        ["go", "run", "./cmd/main.go"],
        ["claude-monet"], // a PREFIX is not a match — exact basename only
        ["mycodex"],
        ["zsh"], // ForegroundProcess already filters an idle shell out, but a bare shell is not an agent
        [],
    ])
    func classifiesAnythingElseAsNil(_ argv: [String]) {
        #expect(AgentKind.classify(argv: argv) == nil)
    }

    @Test func classifiesNilArgvAsNil() {
        #expect(AgentKind.classify(argv: nil) == nil)
    }

    @Test(arguments: [
        (["/bin/sh", "/usr/local/bin/claude"], AgentKind.claude), // the #!/bin/sh + exec claude shim
        (["env", "codex"], AgentKind.codex),
        (["npx", "--yes", "claude"], AgentKind.claude), // flags are skipped to reach the payload argument
        (["bun", "codex"], AgentKind.codex),
    ])
    func looksPastALauncherToTheRealAgent(_ argv: [String], _ expected: AgentKind) {
        #expect(AgentKind.classify(argv: argv) == expected)
    }

    @Test(arguments: [
        ["/bin/sh", "/usr/local/bin/cld"], // a wrapper under its OWN name stays unrecognized
        ["node", "/opt/claude/cli.js"],
        ["zsh", "-lc", "make test"],
    ])
    func doesNotGuessBehindALauncher(_ argv: [String]) {
        #expect(AgentKind.classify(argv: argv) == nil)
    }
}
