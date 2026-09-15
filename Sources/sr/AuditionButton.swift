import SwiftUI

/// The little round play control that fronts every audition in Settings.
///
/// Its three states — idle, fetching, playing — all occupy the same fixed
/// square. Swapping a spinner in for a glyph of a different size is exactly
/// the kind of thing that makes a row (and the toolbar above it) twitch, so
/// the frame is set once and only the contents change.
struct AuditionButton: View {
    var isLoading = false
    var isPlaying = false
    var size: CGFloat = 22
    var help: String = "Play a sample"
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isPlaying
                          ? AnyShapeStyle(Color.accentColor)
                          : hovering && isEnabled ? AnyShapeStyle(.quaternary)
                                                  : AnyShapeStyle(.clear))
                Circle()
                    .strokeBorder(Color.secondary.opacity(isPlaying ? 0 : 0.35),
                                  lineWidth: 1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(size / 32)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(isPlaying ? AnyShapeStyle(.white)
                                                   : AnyShapeStyle(.primary))
                        // Optical centring: a play triangle's visual mass
                        // sits left of its bounding box.
                        .offset(x: isPlaying ? 0 : size * 0.04)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}
