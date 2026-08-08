import Testing
@testable import rookCore

struct SurfaceCommandTests {
    /// The app's own default shell, standing in for whatever the host resolves at runtime.
    private static let defaultShell = "/bin/zsh"

    // MARK: - the four shell/command combinations

    // The load-bearing case: with neither a caller shell nor a command there is nothing to say, so
    // `config.command` stays unset and libghostty spawns exactly what it always did. Any non-nil value
    // here — even a "harmless" one like the default shell spelled out — changes the spawn for every
    // existing session, which is precisely what this feature must not do.
    @Test func neitherShellNorCommandLeavesLibghosttyOnItsOwnDefault() {
        #expect(SurfaceCommand.resolve(shell: nil, command: nil, defaultShell: Self.defaultShell) == nil)
        #expect(SurfaceCommand.resolve(shell: nil, command: nil, defaultShell: "/bin/bash") == nil)
        #expect(SurfaceCommand.resolve(shell: nil, command: nil, defaultShell: "") == nil)
    }

    @Test func shellWithoutCommandSpawnsThatShellAlone() {
        let built = SurfaceCommand.resolve(shell: "/bin/fish", command: nil, defaultShell: Self.defaultShell)
        #expect(Self.tokenize(built) == ["/bin/fish"])
    }

    @Test func commandWithoutShellIsWrappedInTheDefaultShellAsALoginShell() {
        let built = SurfaceCommand.resolve(shell: nil, command: "claude", defaultShell: Self.defaultShell)
        #expect(Self.tokenize(built) == ["/bin/zsh", "-l", "-c", "claude"])
    }

    @Test func commandWithShellIsWrappedInThatShellNotTheDefault() {
        let built = SurfaceCommand.resolve(shell: "/bin/fish", command: "claude", defaultShell: Self.defaultShell)
        #expect(Self.tokenize(built) == ["/bin/fish", "-l", "-c", "claude"])
    }

    // MARK: - an absent command

    // An empty or blank command is the caller saying nothing, not a request to run nothing: it must take
    // the no-command branch. Wrapping it would spawn `<shell> -l -c ''`, a login shell that execs an empty
    // string and exits — a session that dies the moment it opens.
    @Test func blankCommandCountsAsAbsent() {
        #expect(SurfaceCommand.resolve(shell: nil, command: "", defaultShell: Self.defaultShell) == nil)
        #expect(SurfaceCommand.resolve(shell: nil, command: "   ", defaultShell: Self.defaultShell) == nil)
        #expect(SurfaceCommand.resolve(shell: nil, command: " \t\n ", defaultShell: Self.defaultShell) == nil)
    }

    @Test func blankCommandWithAShellStillSpawnsThatShellBare() {
        #expect(Self.tokenize(SurfaceCommand.resolve(shell: "/bin/fish", command: "", defaultShell: Self.defaultShell)) == ["/bin/fish"])
        #expect(Self.tokenize(SurfaceCommand.resolve(shell: "/bin/fish", command: "  ", defaultShell: Self.defaultShell)) == ["/bin/fish"])
    }

    // Blank means "no command", but a NON-blank command travels byte-for-byte, edge whitespace included.
    // Deciding those spaces are surplus is editing what the caller asked to run, which is not ours to do.
    @Test func nonBlankCommandKeepsItsEdgeWhitespace() {
        #expect(Self.tokenize(SurfaceCommand.resolve(shell: nil, command: " claude ", defaultShell: Self.defaultShell)) == ["/bin/zsh", "-l", "-c", " claude "])
        #expect(Self.tokenize(SurfaceCommand.resolve(shell: "/bin/fish", command: " claude ", defaultShell: Self.defaultShell)) == ["/bin/fish", "-l", "-c", " claude "])
    }

    // MARK: - a malformed shell

    /// Shells that are not well-formed per `isValidShellPath`: empty, whitespace-only, relative, and one
    /// carrying a newline. `resolve` must swallow each the way it swallows a blank command.
    private static let malformedShells = ["", "   ", "zsh", "./zsh", "/bin/zsh\nrm -rf /"]

    // Validating at the dispatcher is not enough: a restored `Session.shell` comes straight off
    // `workspaces.json`, so a hand-edited or corrupted snapshot reaches `resolve` having crossed no wire and
    // no validator. A shell that isn't well-formed is therefore no shell at all — same as one never passed.
    @Test(arguments: malformedShells)
    func malformedShellWithoutACommandIsTreatedAsAbsent(shell: String) {
        #expect(SurfaceCommand.resolve(shell: shell, command: nil, defaultShell: Self.defaultShell) == nil)
    }

    @Test(arguments: malformedShells)
    func malformedShellWithACommandFallsBackToTheDefaultShell(shell: String) {
        let built = SurfaceCommand.resolve(shell: shell, command: "claude", defaultShell: Self.defaultShell)
        #expect(Self.tokenize(built) == ["/bin/zsh", "-l", "-c", "claude"])
    }

    // The first of the two holes this rule exists to close. Concatenating an empty shell yields
    // `" -l -c 'claude'"`, whose argv[0] is `-l` — the session tries to exec a flag and dies.
    @Test func anEmptyShellNeverLeavesAFlagInTheExecutablePosition() {
        let built = SurfaceCommand.resolve(shell: "", command: "claude", defaultShell: Self.defaultShell)
        #expect(Self.tokenize(built)?.first == "/bin/zsh")
        #expect(Self.tokenize(built)?.first != "-l")
    }

    // The second hole, and the sharp one: a newline in the shell path splits the built string into two
    // lines, and the trampoline's `bash -c` runs the second one. Nothing after the newline may survive —
    // not escaped, not quoted, not at all.
    @Test func aShellCarryingANewlineNeverGetsASecondLineIntoTheBuiltString() {
        let built = SurfaceCommand.resolve(shell: "/bin/zsh\nrm -rf /", command: "claude", defaultShell: Self.defaultShell)
        #expect(built?.contains("\n") == false)
        #expect(built?.contains("rm -rf") == false)
    }

    // MARK: - quoting

    /// Commands that a naive `"\(shell) -l -c \(command)"` would mangle, split, or hand to the shell as
    /// several arguments. Each must come back out of one round of tokenization byte-identical.
    private static let hostileCommands = [
        "echo 'already quoted'",          // a bare single quote — the `'\''` case
        "echo it's fine",                 // an apostrophe mid-word
        "cd /tmp && ls; echo done | wc -l", // shell operators: they belong to the INNER shell, not the tokenizer
        "echo $HOME && echo ${PATH}",     // must reach the inner shell unexpanded
        "printf 'a\\b\\n'",               // backslashes survive verbatim
        "grep \"needle\" haystack",       // double quotes are just characters here
        "sh -c 'inner '\\'' quoted'"      // an already-escaped quote, re-escaped without collapsing
    ]

    // The contract is not one exact spelling — several quotings are equally correct — but that ONE round
    // of shell-like tokenization yields exactly four arguments with the command intact as the last one.
    @Test(arguments: hostileCommands)
    func commandSurvivesOneRoundOfTokenizationVerbatim(command: String) {
        let built = SurfaceCommand.resolve(shell: nil, command: command, defaultShell: Self.defaultShell)
        #expect(Self.tokenize(built) == ["/bin/zsh", "-l", "-c", command])
    }

    // The same commands must survive the caller-supplied-shell path too, not just the default one.
    @Test(arguments: hostileCommands)
    func commandSurvivesTokenizationUnderACallerShell(command: String) {
        let built = SurfaceCommand.resolve(shell: "/bin/fish", command: command, defaultShell: Self.defaultShell)
        #expect(Self.tokenize(built) == ["/bin/fish", "-l", "-c", command])
    }

    // Stated separately from the round-trip above because it is the security-shaped half: an operator that
    // escaped the quoting would become a token of its own and run at the OUTER level.
    @Test func shellOperatorsStayInsideTheSingleCommandArgument() {
        let built = SurfaceCommand.resolve(shell: nil, command: "ls; rm -rf /tmp/x && echo pwned | tee log", defaultShell: Self.defaultShell)
        let tokens = Self.tokenize(built)
        #expect(tokens?.count == 4)
        #expect(tokens?.last == "ls; rm -rf /tmp/x && echo pwned | tee log")
    }

    // `$VAR` is the inner login shell's business — expanding it while BUILDING the string would freeze the
    // app's own environment into the session's command.
    @Test func dollarVariablesAreNotExpandedWhileBuilding() {
        let built = SurfaceCommand.resolve(shell: nil, command: "echo $HOME", defaultShell: Self.defaultShell)
        #expect(built?.contains("$HOME") == true)
        #expect(Self.tokenize(built)?.last == "echo $HOME")
    }

    @Test func shellPathWithASpaceStaysOneArgument() {
        let spaced = "/Applications/My Shells/fish"
        #expect(Self.tokenize(SurfaceCommand.resolve(shell: spaced, command: nil, defaultShell: Self.defaultShell)) == [spaced])
        #expect(Self.tokenize(SurfaceCommand.resolve(shell: spaced, command: "claude", defaultShell: Self.defaultShell)) == [spaced, "-l", "-c", "claude"])
    }

    @Test func defaultShellWithASpaceStaysOneArgument() {
        let spaced = "/Applications/My Shells/zsh"
        #expect(Self.tokenize(SurfaceCommand.resolve(shell: nil, command: "claude", defaultShell: spaced)) == [spaced, "-l", "-c", "claude"])
    }

    // MARK: - isValidShellPath

    @Test(arguments: ["/bin/zsh", "/bin/sh", "/usr/local/bin/fish", "/opt/homebrew/bin/fish", "/Applications/My Shells/fish"])
    func absolutePathsAreWellFormed(path: String) {
        #expect(SurfaceCommand.isValidShellPath(path))
    }

    // Existence and executability need the filesystem and live app-side; this check is purely about shape,
    // so a path that happens not to exist is still WELL-FORMED here.
    @Test func wellFormednessIsNotExistence() {
        #expect(SurfaceCommand.isValidShellPath("/definitely/not/installed/anywhere/xyzsh"))
    }

    @Test(arguments: ["", "zsh", "bin/zsh", "./zsh", "../bin/zsh", "~/bin/zsh", "$SHELL", " /bin/zsh"])
    func nonAbsolutePathsAreRejected(path: String) {
        #expect(!SurfaceCommand.isValidShellPath(path))
    }

    // A newline or control character in the path is how an argument turns into a second command once the
    // string reaches a shell — rejected outright rather than escaped.
    @Test(arguments: ["/bin/zsh\n", "/bin/zsh\nrm -rf /", "\n/bin/zsh", "/bin/zsh\r", "/bin/z\u{01}sh", "/bin/zsh\t-l", "/bin/zsh\u{7F}"])
    func pathsCarryingControlCharactersAreRejected(path: String) {
        #expect(!SurfaceCommand.isValidShellPath(path))
    }

    // MARK: - helper

    /// Parse a built command line the way one round of POSIX-ish tokenization downstream would: split on
    /// whitespace, take single-quoted runs literally, and let a backslash outside quotes escape the next
    /// character (which is what makes the conventional `'\''` idiom parse back to a bare `'`).
    ///
    /// It deliberately performs NO expansion, so `$VAR`, `;`, `&&` and `|` come back as ordinary characters
    /// — that is exactly the property the quoting tests assert. Returns nil for a nil input or an
    /// unterminated quote, so a malformed build fails the comparison loudly instead of silently.
    /// Characters this tokenizer refuses to see OUTSIDE quotes, because bash would read them as
    /// operators or expansions rather than as ordinary token bytes. Modelling them properly is not
    /// the point — refusing them is: it keeps the helper from silently endorsing a build it cannot
    /// actually reason about.
    private static let unquotedMetacharacters: Set<Character> = [
        ";", "|", "&", "<", ">", "(", ")", "$", "`", "*", "?", "\"",
    ]

    private static func tokenize(_ line: String?) -> [String]? {
        guard let line else { return nil }
        var tokens: [String] = []
        var current = ""
        var started = false
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            if quoted {
                if c == "'" { quoted = false } else { current.append(c) }
                continue
            }
            switch c {
            case "'":
                quoted = true
                started = true
            case "\\":
                guard i < chars.count else { return nil }
                current.append(chars[i])
                i += 1
                started = true
            case " ", "\t", "\n":
                if started { tokens.append(current) }
                current = ""
                started = false
            default:
                // An unquoted shell metacharacter means this tokenizer no longer models what bash
                // would do — bash would treat it as an OPERATOR and split the line into separate
                // commands, while a naive scan would happily fold it into the current token and
                // report the very shape these tests assert. Refusing (nil) turns that silent
                // agreement-with-a-wrong-build into a loud failure. The builder quotes
                // unconditionally, so a correct build never reaches this.
                guard !Self.unquotedMetacharacters.contains(c) else { return nil }
                current.append(c)
                started = true
            }
        }
        guard !quoted else { return nil }
        if started { tokens.append(current) }
        return tokens
    }
}
