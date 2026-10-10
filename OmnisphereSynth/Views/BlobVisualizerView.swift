import SwiftUI

/// Audio-reactive "Blobby" visualizer inspired by MorphWiz 2.
///
/// Draws the 128-sample waveform buffer as a closed polar curve: each sample
/// index maps to an angle (0–2π) and its amplitude sets the radial offset from
/// a base circle. The result is an organic, pulsing blob that reacts in real
/// time to whatever is playing through the engine.
///
/// Used as a full-bleed background layer behind the play surface — the play
/// surface remains fully interactive on top of it. Observes `engine` directly
/// so only the canvas re-renders at ~30 Hz, not the whole ContentView.
///
/// Pitch-reactive (MorphWiz's particles "contain real-time pitch information"):
/// the blob ROTATES to the sounding pitch class on every theme, and on themes
/// without a fixed accent colour it is also TINTED by pitch class (C = red,
/// walking once round the colour wheel per octave). A glide sweeps both smoothly.
struct BlobVisualizerView: View {
    var engine: AudioEngine   // @Observable: only waveformSamples/soundingPitch reads are tracked
    let color:  Color
    let theme:  AppTheme

    @State private var idlePulse: CGFloat = 1.0

    var body: some View {
        let samples = engine.waveformSamples
        let peak    = Float(samples.map { abs($0) }.max() ?? 0)
        let pitch   = engine.soundingPitch
        let hue     = pitch.map(PitchColor.hue(for:))
        // Respect themes with a fixed accent (Radar, Cyber, …) — keep their colour
        // and let rotation alone carry the pitch.
        let tint    = (hue != nil && theme.accentOverride == nil)
            ? Color(hue: hue!, saturation: 0.7, brightness: 0.95)
            : color
        let rotation = (hue ?? 0) * 2 * Double.pi

        Canvas { ctx, size in
            drawBlob(ctx: ctx, size: size, samples: samples, peak: peak,
                     color: tint, rotation: rotation)
        }
        .onAppear {
            // Idle breathing animation when no audio is playing
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                idlePulse = 1.08
            }
        }
    }

    // MARK: - Drawing

    private func drawBlob(ctx: GraphicsContext, size: CGSize,
                          samples: [Float], peak: Float,
                          color: Color, rotation: Double) {
        let n    = samples.count
        guard n > 1 else { return }

        let cx   = size.width  / 2
        let cy   = size.height / 2
        let minD = min(size.width, size.height)

        // Idle scale breathes even with silence; audio overrides it
        let audioScale = CGFloat(peak)
        let baseR  = minD * (0.22 + 0.06 * CGFloat(idlePulse - 1.0))
        let waveR  = minD * 0.22 * (audioScale + 0.04)   // 4% idle flutter

        // ── Build polar path ─────────────────────────────────────────────
        var path = Path()
        for i in 0...n {
            let idx   = i % n
            let angle = (2 * Double.pi * Double(i)) / Double(n) - Double.pi / 2 + rotation
            let r     = baseR + CGFloat(samples[idx]) * waveR
            let px    = cx + r * CGFloat(cos(angle))
            let py    = cy + r * CGFloat(sin(angle))
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else       { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()

        // ── Outer glow (blur pass) ────────────────────────────────────────
        let glowR = 14.0 + 28.0 * CGFloat(audioScale)
        ctx.drawLayer { c in
            c.addFilter(.blur(radius: glowR))
            c.fill(path, with: .color(color.opacity(0.22 + 0.18 * CGFloat(audioScale))))
        }

        // ── Transparent fill ──────────────────────────────────────────────
        ctx.fill(path, with: .color(color.opacity(0.06 + 0.10 * CGFloat(audioScale))))

        // ── Main outline ──────────────────────────────────────────────────
        ctx.stroke(path,
                   with: .color(color.opacity(0.45 + 0.45 * CGFloat(audioScale))),
                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

        // ── Inner ring — faint reference circle ───────────────────────────
        let rr = baseR * 0.45
        ctx.stroke(
            Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
            with: .color(color.opacity(0.12 + 0.08 * CGFloat(audioScale))),
            lineWidth: 0.7
        )
    }
}
