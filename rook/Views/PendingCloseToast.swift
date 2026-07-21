import rookCore
import SwiftUI

/// The undo toast shown after a grace-period close: "Closed <title>" with a Reopen button and a live
/// countdown bar to the grace expiry.
///
/// Themed to the terminal (an opaque `terminalColor` panel with `chromeText` text) rather than system
/// chrome, so it reads as part of rook under every theme — the theme mismatch was one of the three reasons
/// the original pill was dropped upstream. Hovering PAUSES the finalize timer (`onPause`) and freezes the
/// bar at full; leaving RESUMES it with a fresh full grace (`onResume`), so the bar restarts full — which
/// matches what the store actually does (resume reschedules the whole grace window).
struct PendingCloseToast: View {
    let summary: PendingCloseSummary
    let terminalColor: Color
    let chromeText: Color
    let onReopen: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    /// The countdown bar's remaining fraction (1 = full grace, 0 = expired), animated linearly over the
    /// grace window; snapped to full and frozen while hovering.
    @State private var fraction: CGFloat = 1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: summary.kind == .workspace ? "rectangle.stack" : "terminal")
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 5) {
                Text("Closed \(summary.title)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                countdownBar
            }
            Button(action: onReopen) {
                Text("Reopen")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(chromeText.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pending-close-reopen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .foregroundStyle(chromeText)
        .frame(maxWidth: 360)
        // opaque themed panel (like a floating overlay's backing) so it stays legible over the translucent
        // window backing, with a hairline theme border + a soft shadow for contrast against the terminal.
        .background(terminalColor, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(chromeText.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        .onAppear(perform: restart)
        .onHover { hovering in
            if hovering {
                onPause()
                freeze()
            } else {
                onResume()
                restart()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-close-toast")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// A slim capsule that depletes left-to-right as the grace window elapses. Decorative (the Reopen
    /// button carries the action), so hidden from accessibility.
    private var countdownBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(chromeText.opacity(0.15))
                Capsule().fill(chromeText.opacity(0.8))
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    /// Snap the bar to full, then count it down linearly over the grace window.
    private func restart() {
        fraction = 1
        withAnimation(.linear(duration: summary.graceInterval)) { fraction = 0 }
    }

    /// Freeze the bar at full while hovering — the finalize timer is paused, and leaving grants a fresh
    /// full grace, so full is the honest state to show.
    private func freeze() {
        withAnimation(.linear(duration: 0)) { fraction = 1 }
    }
}
