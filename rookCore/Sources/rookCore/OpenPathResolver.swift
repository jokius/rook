import Foundation

/// Resolves a Finder / `open -a rook <path>` odoc URL to the directory a new session should start in.
/// A folder URL resolves to its own path; a regular-file URL to its parent directory; anything that is not
/// an existing file-system path (a non-file URL, or a path that no longer exists) resolves to nil so the
/// caller can skip it. Host-free so it is unit-tested without the app.
public enum OpenPathResolver {
    public static func directory(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
    }
}
