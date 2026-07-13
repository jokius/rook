import Foundation

/// Decides what rook does when a terminal hyperlink is clicked (`GHOSTTY_ACTION_OPEN_URL`). A terminal
/// renders UNTRUSTED program output, so an escape-sequence link can carry any scheme. `disposition(for:)`
/// maps a raw link to one of four actions: OPEN a web/mail URL (`NSWorkspace.open`), PREVIEW a local
/// Markdown file in rook's built-in panel, REVEAL any other LOCAL file in Finder
/// (`NSWorkspace.activateFileViewerSelecting`), or IGNORE anything else. A local file is revealed, never
/// opened: opening it goes through LaunchServices (the Finder double-click path), so a click on
/// `file:///…/X.app` or `.command` would LAUNCH it — reveal only selects it, executing nothing. `.preview`
/// does not weaken that boundary: a Markdown file is PARSED by `MarkdownDocument` and drawn by rook's own
/// panel, so LaunchServices never sees it and there is nothing to execute — which is why the preview
/// allow-list is Markdown ONLY (`markdownExtensions`), never a deny-list. A `file://` whose host is NOT this
/// machine is ignored: `activateFileViewerSelecting` on a remote host can trigger a Finder network/SMB mount.
///
/// The BARE-PATH case is what makes a click on agent output work: libghostty's own link regex matches
/// `plan.md`, `./src/foo.ts`, `~/x` and even `src/foo.ts:42` (`:` is one of its path chars), and hands the
/// raw match to us — but it only resolves a relative match against the OSC 7 pwd when that path EXISTS, so
/// `src/foo.ts:42` arrives as unresolved text. Stripping the `:line[:col]` suffix (the number itself is
/// dropped — it only has to stop the path from resolving), tilde-expanding, and resolving against the
/// session cwd is therefore ours to do.
///
/// Host-free (Foundation-only) so it is unit-tested — the local host names, the home directory, the cwd, and
/// the filesystem probe are all injected into the decision; the app-side glue just calls `NSWorkspace` and
/// opens the panel (same split as `ShellEscape`).
public enum LinkPolicy {
    /// The schemes safe to hand to the system opener — web + mail only, none that hands off to a local
    /// executable/handler.
    public static let permittedSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// The only extensions that open INSIDE rook. Markdown is the one thing worth reading in a terminal
    /// window, and rook renders it itself — everything else goes to Finder, so this stays an allow-list.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]

    /// What a link click should do. Carries the target URL for `.open`/`.preview`/`.reveal`.
    public enum LinkDisposition: Equatable {
        case open(URL)
        case preview(URL)
        case reveal(URL)
        case ignore
    }

    /// What a path points at, as seen by the injected probe. `nil` (no such path) and `.directory` both keep
    /// a click out of the preview panel — the panel renders a FILE, and a directory belongs in Finder.
    public enum FileProbe: Equatable, Sendable {
        case file
        case directory
    }

    /// The default filesystem probe. Injected (rather than called directly) so the decision stays host-free
    /// and testable without touching the disk. Callers must have already denied automount paths — a `stat`
    /// inside autofs can itself trigger the mount this policy exists to avoid.
    public static func probeFileSystem(_ path: String) -> FileProbe? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Lowercased host names that count as "this machine" for a `file://` link: `localhost` and the
    /// `gethostname()` name (what GNU `ls --hyperlink` emits, e.g. `file://<host>/…`; `eza` uses an empty
    /// host, covered separately by the empty-host rule). Deliberately does NOT consult `Host.current()` or
    /// `ProcessInfo.hostName`: those resolve names via mDNS/Bonjour, which trips the macOS "find devices on
    /// local networks" permission prompt on first click — `gethostname()` is a pure syscall that touches no
    /// network. Computed ONCE and used as the default for `disposition`.
    public static let localHostNames: Set<String> = {
        var raw: Set<String> = ["localhost"]
        var buffer = [CChar](repeating: 0, count: 256)   // gethostname() — the name GNU ls uses, no network
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }   // trim at NUL, then decode
            raw.insert(String(decoding: bytes, as: UTF8.self))
        }
        return expandedHostNames(from: raw)
    }()

    /// Normalize each raw host name and add the `.local`-stripped short form next to the full one. Pure (no
    /// syscalls), so the normalization + `.local` expansion feeding `localHostNames` stays unit-testable.
    static func expandedHostNames(from raw: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for name in raw {
            let norm = normalizedHost(name)
            guard !norm.isEmpty else { continue }
            out.insert(norm)
            if norm.hasSuffix(".local") {
                let short = String(norm.dropLast(6))                               // add the short form too,
                if !short.isEmpty { out.insert(short) }                            // but a bare ".local" → "" is skipped
            }
        }
        return out
    }

    /// Lowercase a host and drop a trailing FQDN dot so matching is stable.
    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    /// The macOS auto-mount roots where a Finder reveal can trigger an NFS/SMB automount: `/net` (`-hosts`),
    /// `/Network` (`/Network/Servers`), and `/home` (`auto_home`), PLUS their canonical Data-volume paths
    /// under `/System/Volumes/Data/…`. On modern macOS `/home` is a firmlink/symlink and `auto_home` is
    /// actually mounted at `/System/Volumes/Data/home`, so a LITERAL `/System/Volumes/Data/home/<user>` link
    /// would otherwise slip past the `/home` entry and still trip the mount. Matched against the EXACT root or
    /// a `<root>/…` child, case-insensitively (the boot volume is case-insensitive, so `/NET/…` mounts too),
    /// so a sibling like `/networkx` is NOT caught; the broad Data root `/System/Volumes/Data` itself is
    /// deliberately NOT listed (it backs every real file, e.g. `/System/Volumes/Data/Users/…`). The path must
    /// already be dot-normalized (see `disposition`).
    static func isAutomountPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["/net", "/network", "/home",
                "/system/volumes/data/home",
                "/system/volumes/data/net",
                "/system/volumes/data/network/servers"].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    /// Collapse `.`/`..` segments in an ABSOLUTE path with a purely LEXICAL, string-only normalizer — no
    /// filesystem access (unlike `URL.standardizedFileURL`, which stats the target) and no symlink resolution,
    /// so the classifier never touches the very automount path it may be about to deny (a `stat` of a path
    /// inside autofs could itself trigger the mount). A leading `..` at the root is dropped. The caller
    /// guarantees an absolute input (`hasPrefix("/")`).
    static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        var out: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(comp)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Maps a raw terminal link to an action: a permitted web/mail scheme → `.open`; a local `file://` link or
    /// a BARE PATH → `.preview` (Markdown) / `.reveal` (anything else); a non-local host, an empty/relative
    /// `file://` path, a UNC-style `//`-path, an auto-mount path, a path that does not exist, or unparseable
    /// input → `.ignore`. `localHosts`, `cwd`, `home` and `probe` are injected (defaults: this machine) so the
    /// decision stays host-free and unit-testable.
    ///
    /// An UNKNOWN scheme deliberately falls through to the bare-path branch instead of bailing out: `foo.ts:42`
    /// parses as a URL whose "scheme" is `foo.ts` (a dot is legal in a scheme name), and that is a real click
    /// target in agent output. The fall-through is safe because the branch ends in a filesystem probe —
    /// `javascript:alert(1)` is simply not a file, so it lands on `.ignore` all the same.
    public static func disposition(
        for raw: String,
        cwd: String? = nil,
        localHosts: Set<String> = localHostNames,
        home: String = NSHomeDirectory(),
        probe: (String) -> FileProbe? = probeFileSystem
    ) -> LinkDisposition {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            if permittedSchemes.contains(scheme) { return .open(url) }
            if scheme == "file" { return fileDisposition(url, localHosts: localHosts, probe: probe) }
        }
        return barePathDisposition(raw, cwd: cwd, home: home, probe: probe)
    }

    /// The `file://` branch: a LOCAL host (empty, or in `localHosts`) resolves to the HOST-STRIPPED,
    /// dot-normalized path, so Finder only ever sees a plain `/…` path and never leans on the original
    /// authority for host handling.
    static func fileDisposition(_ url: URL, localHosts: Set<String>, probe: (String) -> FileProbe?) -> LinkDisposition {
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        guard host.isEmpty || localHosts.contains(host) else { return .ignore }
        // reject an empty/relative path (an empty path would make `URL(fileURLWithPath:)` the process CWD) and
        // a UNC-style `//` path (a remote target hidden in the path where the host check can't see it).
        let rawPath = url.path(percentEncoded: false)
        guard rawPath.hasPrefix("/"), !rawPath.hasPrefix("//") else { return .ignore }
        // an explicit `file://` link is a DELIBERATE reference by the program that printed it, so a
        // non-Markdown (or missing) target still reveals, exactly as it did before previews existed — Finder
        // reports a path that is gone. Only the Markdown candidate is probed, to decide panel vs Finder.
        return localPathDisposition(rawPath, mustExist: false, probe: probe)
    }

    /// The bare-path branch — what a click on `plan.md`, `./docs/x.md`, `~/notes.md` or `src/foo.ts:42` in
    /// agent output lands on. A relative path needs the session cwd (OSC 7); without one there is nothing to
    /// resolve against, so it is ignored rather than guessed against the process working directory.
    static func barePathDisposition(_ raw: String, cwd: String?, home: String,
                                    probe: (String) -> FileProbe?) -> LinkDisposition {
        let path = strippingLineSuffix(raw.trimmingCharacters(in: .whitespaces))
        guard !path.isEmpty, !path.hasPrefix("//") else { return .ignore }   // `//` is a UNC target, not a path
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else if path == "~" || path.hasPrefix("~/") {
            absolute = home + path.dropFirst()
        } else if let cwd, cwd.hasPrefix("/") {
            absolute = cwd + "/" + path
        } else {
            return .ignore
        }
        // a bare path is a GUESS made from prose (libghostty's regex fires on any dotted word), so it only
        // acts when it resolves to something real — otherwise a click on ordinary text would bounce Finder.
        return localPathDisposition(absolute, mustExist: true, probe: probe)
    }

    /// The shared tail of both local branches: normalize, deny automounts, then ask the filesystem. Collapses
    /// `.`/`..` with a purely LEXICAL normalizer (string only) so `/tmp/../net/x` can't sneak past the
    /// automount check AND the classifier never stats — and so never risks triggering — the automount path it
    /// is about to deny. It also never resolves symlinks: a `/tmp/link -> /net` link reveals the link itself,
    /// never the target (do NOT swap in `standardizedFileURL`/`resolvingSymlinksInPath()`, which touch the
    /// filesystem).
    ///
    /// `mustExist` is the difference between the two callers: a bare path has to hit a real file (it was
    /// guessed from text), while a `file://` link reveals regardless (the program meant it). Either way a
    /// panel only ever opens on a Markdown path the probe confirms is a readable FILE — a directory named
    /// `x.md` reveals like any other directory.
    static func localPathDisposition(_ path: String, mustExist: Bool,
                                     probe: (String) -> FileProbe?) -> LinkDisposition {
        let normalized = lexicallyNormalizedAbsolutePath(path)
        guard !isAutomountPath(normalized) else { return .ignore }
        let url = URL(fileURLWithPath: normalized, isDirectory: false)
        guard mustExist || isMarkdown(normalized) else { return .reveal(url) }   // `file://` non-Markdown: no stat
        switch probe(normalized) {
        case .file: return isMarkdown(normalized) ? .preview(url) : .reveal(url)
        case .directory: return .reveal(url)
        case nil: return mustExist ? .ignore : .reveal(url)
        }
    }

    /// Drops a trailing `:line` (and `:line:column`) from a click target: `src/foo.ts:42` is one of libghostty's
    /// link matches, and the suffix is exactly what stops the path from resolving. The NUMBER is discarded —
    /// nothing rook opens can act on it (Markdown renders whole, Finder reveals whole).
    static func strippingLineSuffix(_ path: String) -> String {
        var out = path[...]
        for _ in 0..<2 {                                            // at most `:line:column`
            guard let colon = out.lastIndex(of: ":") else { break }
            let digits = out[out.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { break }
            out = out[..<colon]
        }
        return String(out)
    }

    /// Whether a path is one rook renders itself (`markdownExtensions`) rather than handing to Finder.
    static func isMarkdown(_ path: String) -> Bool {
        markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
