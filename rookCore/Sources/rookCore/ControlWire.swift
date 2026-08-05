/// 1 MiB cap on a request line (newline excluded), far above any realistic `session.type` payload. Over it
/// the server rejects the line and closes the connection, so a bad client can't grow the buffer unbounded;
/// the client checks the same cap before writing, so an oversized request fails with a readable error
/// instead of a write to a closing peer. Shared so the two sides cannot drift.
public enum ControlWire {
    public static let maxRequestLineBytes = 1 << 20
}
