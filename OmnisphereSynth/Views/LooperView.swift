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

            // ── Sync to drums ──────────────────────────────────────────────
            Button {
                looper.syncToDrums.toggle()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "metronome")
                        .font(.system(size: 12, weight: .semibold))
                    Text("SYNC")
                        .font(.system(size: 9, weight: .bold, design: theme.fontDesign))
                        .kerning(1)
                }
                .foregroundColor(looper.syncToDrums ? accent : theme.secondaryText.opacity(0.55))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .panelSurface(theme, radius: 7,
                              border: looper.syncToDrums ? accent.opacity(0.5) : theme.panelBorder)
            }
            .accessibilityLabel("Sync loop to drums")
            .accessibilityValue(looper.syncToDrums ? "On" : "Off")

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
        // A loop recorded with the drums shows its length: "PLAYING · 2 BARS".
        let bars = looper.syncedBars > 0
            ? " · \(looper.syncedBars) BAR\(looper.syncedBars == 1 ? "" : "S")" : ""
        if looper.isRecording { return "REC" }
        if looper.isPlaying   { return "PLAYING" + bars }
        if looper.hasLoop     { return "READY" + bars }
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
                .panelSurface(theme, radius: 7, border: border)
        }
    }
}
