import Foundation
import Testing
@testable import rookCore

struct LinkPolicyTests {
    // MARK: disposition (open / reveal / ignore)

    /// A URL followed by garbage (what the pre-fix `String(cString:)` over-read past `len` could produce)
    /// does not silently become an openable web link: the trailing space + junk make it unparseable or
    /// non-web, so the disposition is never `.open`.
    @Test func trailingGarbageDoesNotYieldAWebURL() {
        #expect(LinkPolicy.disposition(for: "https://example.com\u{00}/etc/other", localHosts: Self.localHosts) == .ignore)
        #expect(LinkPolicy.disposition(for: "https://example.com extra junk", localHosts: Self.localHosts) == .ignore)
    }

    /// A fixed injected set so host matching is deterministic in tests (independent of the real machine).
    static let localHosts: Set<String> = ["myhost", "localhost"]

    @Test(arguments: [
        "http://example.com",
        "https://example.com/path?q=1#frag",
        "HTTPS://EXAMPLE.COM",
        "mailto:someone@example.com",
        "ftp://host/file.txt",
    ])
    func webSchemesOpen(_ raw: String) throws {
        let expected = try #require(URL(string: raw))
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .open(expected))
    }

    /// A local `file://` to a NON-Markdown target reveals the HOST-STRIPPED, dot-normalized path — Finder never
    /// sees the original authority — so every host form of `/tmp/x.txt` resolves to the same `file:///tmp/x.txt`.
    /// (Markdown is the one extension that peels off into `.preview`; see `markdownPreviews`.)
    @Test(arguments: [
        ("file:///tmp/x.txt", "file:///tmp/x.txt"),            // empty host
        ("file:/tmp/x.txt", "file:///tmp/x.txt"),              // authority-less (single-slash) form → no host
        ("file://localhost/tmp/x.txt", "file:///tmp/x.txt"),   // localhost — host stripped
        ("file://myhost/tmp/x.txt", "file:///tmp/x.txt"),      // this machine's own name (GNU ls) — host stripped
        ("file://MYHOST/tmp/x.txt", "file:///tmp/x.txt"),      // host match is case-insensitive
        ("file://myhost./tmp/x.txt", "file:///tmp/x.txt"),     // trailing FQDN dot is stripped
        ("FILE:///tmp/x.txt", "file:///tmp/x.txt"),            // scheme match is case-insensitive
        ("file:///tmp/../tmp/x.txt", "file:///tmp/x.txt"),     // dot segments normalized away
        ("file://myhost/tmp/a%20b.md", "file:///tmp/a%20b.md"),  // percent-encoded space survives the round-trip
        ("file:///Applications/Some.app", "file:///Applications/Some.app"),  // revealed in Finder, NOT launched
    ])
    func localFileReveals(_ raw: String, _ expected: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == expected)
    }

    @Test(arguments: [
        "file:///net/server/share/x.txt",         // /net (-hosts) auto-mount root
        "file:///Network/Servers/host/share",     // /Network auto-mount root
        "file:///home/someone/x.txt",              // /home (auto_home) auto-mount root
        "file://localhost/net/server/share",      // local host but an auto-mount path
        "file:///tmp/../net/server/share",        // dot segments resolve INTO /net — must still ignore
        "file:///tmp/%2E%2E/net/server/share",    // percent-encoded `..` decodes BEFORE normalization — still ignore
        "file:///NET/server/share",               // auto-mount match is case-insensitive
        "file:///net",                            // bare root (no child) — exercises the `lower == root` branch
        "file:///home",                           // bare root
        "file:///network",                        // bare root
        "file:///System/Volumes/Data/home/someone/x.txt",     // canonical Data path where auto_home really mounts
        "file:///System/Volumes/Data/net/server/share",      // canonical Data /net
        "file:///System/Volumes/Data/Network/Servers/host",  // canonical Data /Network/Servers
    ])
    func autoMountPathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    /// Sibling names that merely start with an auto-mount root are NOT auto-mount paths — still revealed.
    /// The last case is the boundary that keeps the Data denylist narrow: a normal file on the Data volume
    /// (`/System/Volumes/Data/Users/…`, where every real file lives) must reveal, not be treated as automount.
    @Test(arguments: [
        ("file:///networkx/x.md", "file:///networkx/x.md"),
        ("file:///nettools/x.md", "file:///nettools/x.md"),
        ("file:///homebrew/x.md", "file:///homebrew/x.md"),
        ("file:///System/Volumes/Data/Users/me/doc.md", "file:///System/Volumes/Data/Users/me/doc.md"),
    ])
    func autoMountLookalikesStillReveal(_ raw: String, _ expected: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == expected)   // and the revealed path is the exact one, not a mis-normalized neighbor
    }

    /// The classifier never resolves symlinks: revealing a link INSIDE a symlinked directory keeps the LINK
    /// path, not the resolved target — so a `link -> /net` can never be followed into an automount root. This
    /// is a value-result assertion (the reveal URL string), the invariant the lexical normalizer guarantees.
    @Test func revealDoesNotResolveSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agt-linkpolicy-symlink-test", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // the real leaf MUST exist, else `resolvingSymlinksInPath()` also returns the link path and the test
        // could not tell the lexical normalizer from a symlink-resolving regression.
        try Data().write(to: target.appendingPathComponent("x.txt"))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }
        let linkLeaf = base.appendingPathComponent("link").appendingPathComponent("x.txt")
        guard case let .reveal(url) = LinkPolicy.disposition(for: linkLeaf.absoluteString, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(linkLeaf.absoluteString)"); return
        }
        // reveal keeps the LINK path; a regression to resolvingSymlinksInPath() would yield .../target/x.txt
        #expect(url.path(percentEncoded: false) == linkLeaf.path(percentEncoded: false))
    }

    /// An empty or relative `file://` path is ignored — an empty path would make `URL(fileURLWithPath:)`
    /// resolve to the process working directory, revealing the wrong thing.
    @Test(arguments: [
        "file://localhost",   // local host, no path
        "file://myhost",      // local host, no path
        "file:relative",      // relative path, no leading slash
    ])
    func emptyOrRelativeFilePathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    @Test(arguments: [
        "file://otherhost/tmp/x.md",             // non-local host → ignore (would trip a Finder network mount)
        "file://remote.example.com/share/x.md",
    ])
    func nonLocalFileIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    @Test(arguments: [
        "javascript:alert(1)",
        "vscode://file/x",
        "tel:+15550100",
        "example.com",
        "",
        "   ",
    ])
    func otherSchemesIgnore(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    @Test(arguments: [
        "file:////server/share/x.md",          // empty host, UNC-style path — remote target hidden in the path
        "file://localhost//server/share/x.md",  // local host but UNC path — still a network target
        "file://localhost/%2Fserver/share",     // encoded slash decodes to a leading // — still a UNC target
    ])
    func uncPathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    // MARK: preview (Markdown) vs reveal — the built-in panel allow-list

    /// A fake filesystem so the decision is deterministic: only these paths exist, and only as files.
    static func probe(files: Set<String>, directories: Set<String> = []) -> (String) -> LinkPolicy.FileProbe? {
        { path in
            if files.contains(path) { return .file }
            if directories.contains(path) { return .directory }
            return nil
        }
    }

    /// The point of the feature: a Markdown file — bare, relative, tilde'd, or `file://` — opens in rook's own
    /// panel. `src/foo.ts:42` (a libghostty match with a line suffix) resolves to the FILE and goes to Finder.
    @Test(arguments: [
        ("plan.md", "/work/plan.md"),                          // bare relative → resolved against the cwd
        ("./docs/x.markdown", "/work/docs/x.markdown"),        // dot-relative
        ("../sibling/y.mdx", "/sibling/y.mdx"),                // `..` normalized away
        ("/work/plan.md", "/work/plan.md"),                    // absolute
        ("~/notes.md", "/Users/me/notes.md"),                  // tilde-expanded against the injected home
        ("plan.md:12", "/work/plan.md"),                       // `:line` stripped — it only blocked resolution
        ("plan.md:12:3", "/work/plan.md"),                     // `:line:column` too
        ("PLAN.MD", "/work/PLAN.MD"),                          // extension match is case-insensitive
        ("file:///work/plan.md", "/work/plan.md"),             // OSC 8 — what Claude Code puts on Read/Edit
    ])
    func markdownPreviews(_ raw: String, _ expected: String) {
        let files: Set<String> = ["/work/plan.md", "/work/docs/x.markdown", "/sibling/y.mdx",
                                  "/Users/me/notes.md", "/work/PLAN.MD"]
        guard case let .preview(url) = LinkPolicy.disposition(
            for: raw, cwd: "/work", localHosts: Self.localHosts, home: "/Users/me", probe: Self.probe(files: files)
        ) else {
            Issue.record("expected .preview for \(raw)"); return
        }
        #expect(url.path(percentEncoded: false) == expected)
    }

    /// Everything that is NOT Markdown goes to Finder — including an executable bundle, which is the whole
    /// reason a local file is revealed and never opened. `.preview` must not become a general file opener.
    @Test(arguments: [
        ("src/foo.ts:42", "/work/src/foo.ts"),                 // `:line` stripped, then revealed (not previewed)
        ("notes.txt", "/work/notes.txt"),
        ("Some.app", "/work/Some.app"),                        // a directory bundle — revealed, NEVER launched
        ("deploy.sh", "/work/deploy.sh"),                      // executable — revealed, NEVER run
        ("file:///work/deploy.sh", "/work/deploy.sh"),
    ])
    func nonMarkdownReveals(_ raw: String, _ expected: String) {
        let files: Set<String> = ["/work/src/foo.ts", "/work/notes.txt", "/work/deploy.sh"]
        guard case let .reveal(url) = LinkPolicy.disposition(
            for: raw, cwd: "/work", localHosts: Self.localHosts, home: "/Users/me",
            probe: Self.probe(files: files, directories: ["/work/Some.app"])
        ) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.path(percentEncoded: false) == expected)
    }

    /// A directory named `x.md` is still a directory: it reveals in Finder rather than opening a panel on
    /// something the renderer cannot read. Same for a Markdown path that does not exist at all.
    @Test func markdownDirectoryAndMissingMarkdownReveal() {
        let probe = Self.probe(files: [], directories: ["/work/x.md"])
        guard case let .reveal(dir) = LinkPolicy.disposition(for: "file:///work/x.md", localHosts: Self.localHosts,
                                                             probe: probe) else {
            Issue.record("expected .reveal for a directory named x.md"); return
        }
        #expect(dir.path(percentEncoded: false) == "/work/x.md")
        // a `file://` link to a MISSING .md still reveals (Finder reports it), it does not open an empty panel
        #expect(LinkPolicy.disposition(for: "file:///work/gone.md", localHosts: Self.localHosts,
                                       probe: probe) == .reveal(URL(fileURLWithPath: "/work/gone.md")))
    }

    /// A bare path that does not resolve to anything is ignored — a click on prose must not open a panel or
    /// bounce Finder. Includes the case that made the unknown-scheme fall-through safe (`javascript:` is not
    /// a file) and a relative path with no cwd to resolve against (no OSC 7 yet).
    @Test(arguments: [
        "plan.md",                       // no such file (empty filesystem)
        "javascript:alert(1)",           // parses as a scheme; falls through to the path branch and finds nothing
        "example.com",
        "src/foo.ts:42",
    ])
    func unresolvableBarePathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, cwd: "/work", localHosts: Self.localHosts, home: "/Users/me",
                                       probe: Self.probe(files: [])) == .ignore)
        // and with NO cwd, a relative path has nothing to resolve against — never the process working directory
        #expect(LinkPolicy.disposition(for: raw, cwd: nil, localHosts: Self.localHosts, home: "/Users/me",
                                       probe: Self.probe(files: ["/work/plan.md"])) == .ignore)
    }

    /// The automount denial holds for bare paths too, and it is decided BEFORE the probe runs — a `stat` inside
    /// autofs would itself trigger the mount this policy exists to avoid. The probe records every path it sees.
    @Test func automountBarePathsIgnoredWithoutProbing() {
        nonisolated(unsafe) var probed: [String] = []
        let recording: (String) -> LinkPolicy.FileProbe? = { probed.append($0); return .file }
        for raw in ["/net/server/share/x.md", "../net/host/x.md", "~/../../net/host/x.md", "/home/someone/x.md"] {
            #expect(LinkPolicy.disposition(for: raw, cwd: "/net", localHosts: Self.localHosts, home: "/Users/me",
                                           probe: recording) == .ignore)
        }
        #expect(probed.isEmpty)   // never stat'ed an automount path
    }

    // MARK: strippingLineSuffix

    @Test(arguments: [
        ("src/foo.ts:42", "src/foo.ts"),
        ("src/foo.ts:42:10", "src/foo.ts"),
        ("plan.md", "plan.md"),                  // nothing to strip
        ("/tmp/12:30/notes.md", "/tmp/12:30/notes.md"),   // a colon MID-path is not a line suffix
        ("weird:", "weird:"),                    // trailing colon with no digits — left alone
        ("foo:٤٢", "foo:٤٢"),                    // non-ASCII digits are not a line number
        (":42", ""),                             // degenerate: strips to empty, and the caller ignores it
    ])
    func lineSuffixStripping(_ raw: String, _ expected: String) {
        #expect(LinkPolicy.strippingLineSuffix(raw) == expected)
    }

    // MARK: localHostNames / expandedHostNames (the default-parameter source)

    @Test func expandedHostNamesNormalizesAndAddsLocalShortForm() {
        let out = LinkPolicy.expandedHostNames(from: ["MyMac.local", "Box.", "localhost", "", ".local"])
        #expect(out.contains("mymac.local"))
        #expect(out.contains("mymac"))          // .local short form added alongside
        #expect(out.contains("box"))            // trailing FQDN dot dropped + lowercased
        #expect(out.contains("localhost"))
        #expect(!out.contains(""))              // empty name skipped, and a bare ".local" adds no empty short form
    }

    @Test func localHostNamesAlwaysHasLocalhostAndIsNonEmpty() {
        #expect(LinkPolicy.localHostNames.contains("localhost"))
        #expect(!LinkPolicy.localHostNames.isEmpty)
    }

    /// Smoke test on the DEFAULT `localHosts` parameter: without injection the decision must reach
    /// `localHostNames`, so an empty-host / localhost file link still reveals (host-stripped).
    @Test(arguments: ["file:///tmp/x.txt", "file://localhost/tmp/x.txt"])
    func defaultLocalHostsRevealLocalFiles(_ raw: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == "file:///tmp/x.txt")
    }
}
