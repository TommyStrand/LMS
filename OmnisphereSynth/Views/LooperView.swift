import SwiftUI
import Combine

/// Compact looper strip — record a phrase and loop it back.
/// Sits below the play surface. The looper fires note-on/off events through
/// AudioEngine so all presets and expression (X/Y) are captured faithfully.
struct LooperView: View {
    var looper: LooperEngine
    let theme: AppTheme
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {

            // ── Label ──────────────────────────────────────────────────────
            Text("LOOP")
                .font(.system(size: 9, weight: .bold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
                .kerning(1.5)

            // ── Record ─────────────────────────────────────────────────────
            looperButton(
                icon: looper.isRecording ? "stop.fill" : "record.circle",
                color: looper.isRecording ? .red : theme.secondaryText,
                border: looper.isRecording ? Color.red.opacity(0.5) : theme.panelBorder
            ) {
                if looper.isRecording { looper.stopRecording() }
                else                  { looper.startRecording() }
            }

            // ── Play / Pause ────────────────────────────────────────────────
            looperButton(
                icon: looper.isPlaying ? "pause.fill" : "play.fill",
                color: looper.isPlaying ? accent : (looper.hasLoop ? theme.primaryText : theme.secondaryText.opacity(0.3)),
                border: looper.isPlaying ? accent.opacity(0.5) : theme.panelBorder
            ) {
                looper.togglePlayback()
            }
            .disabled(!looper.hasLoop)

            // ── Progress bar ───────────────────────────────────────────────
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.panelBackground)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(theme.panelBorder, lineWidth: 1))

                    // Fill
                    if looper.isPlaying && looper.progress > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(accent.opacity(0.65))
                            .frame(width: geo.size.width * looper.progress)
                            .animation(.linear(duration: 0.033), value: looper.progress)
                    }

                    // Status text
                    Text(statusLabel)
                        .font(.system(size: 8, weight: .semibold, design: theme.fontDesign))
                        .foregroundColor(looper.isRecording ? .red : theme.secondaryText.opacity(0.7))
                        .kerning(1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30)

            // ── Clear ──────────────────────────────────────────────────────
            looperButton(
                icon: "trash",
                color: looper.hasLoop ? theme.secondaryText : theme.secondaryText.opacity(0.25),
                border: theme.panelBorder
            ) {
                looper.clear()
            }
            .disabled(!looper.hasLoop)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var statusLabel: String {
        if looper.isRecording { return "REC" }
        if looper.isPlaying   { return "PLAYING" }
        if looper.hasLoop     { return "READY" }
        return "EMPTY"
    }

    private func looperButton(icon: String, color: Color, border: Color,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(theme.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(border, lineWidth: 1))
        }
    }
}
