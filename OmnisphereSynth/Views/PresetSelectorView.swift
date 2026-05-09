import SwiftUI

struct PresetSelectorView: View {
    @Binding var selectedIndex: Int
    @EnvironmentObject var themeManager: ThemeManager
    let onSelect: (SynthPreset) -> Void

    var body: some View {
        let theme = themeManager.current
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(SynthPreset.presets.enumerated()), id: \.offset) { idx, preset in
                    PresetChip(
                        preset: preset,
                        isSelected: idx == selectedIndex,
                        theme: theme
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedIndex = idx
                        }
                        onSelect(preset)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }
}

struct PresetChip: View {
    let preset: SynthPreset
    let isSelected: Bool
    let theme: AppTheme

    private var accentColor: Color { theme.accent(for: Color(hex: preset.color)) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                    .fill(isSelected ? accentColor.opacity(0.85) : theme.panelBackground)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                            .strokeBorder(accentColor.opacity(isSelected ? 1 : 0.4),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                    .shadow(color: isSelected ? accentColor.opacity(0.5) : .clear, radius: 10)

                PresetIcon(iconStyle: preset.iconStyle,
                           color: isSelected ? theme.primaryText : accentColor)
                    .frame(width: 38, height: 38)
            }

            Text(preset.name)
                .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                .foregroundColor(isSelected ? accentColor : theme.secondaryText)
                .lineLimit(1)
                .frame(width: 72)
        }
        .scaleEffect(isSelected ? 1.05 : 1.0)
    }
}

// MARK: - Preset icon (one per instrument type)

struct PresetIcon: View {
    let iconStyle: SynthPreset.IconStyle
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            switch iconStyle {
            case .hammondTonewheel: Self.drawHammond(ctx, size, color)
            case .rhodesTine:       Self.drawRhodes(ctx, size, color)
            case .churchPipes:      Self.drawChurchPipes(ctx, size, color)
            case .mysticWave:       Self.drawMysticWave(ctx, size, color)
            case .darkVortex:       Self.drawDarkVortex(ctx, size, color)
            case .celestialDots:    Self.drawCelestialDots(ctx, size, color)
            case .pulseBolt:        Self.drawPulseBolt(ctx, size, color)
            case .voidHole:         Self.drawVoidHole(ctx, size, color)
            case .solarRadial:      Self.drawSolarRadial(ctx, size, color)
            }
        }
    }

    // MARK: Hammond – tonewheel with spokes and outer ring

    private static func drawHammond(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let cx = size.width / 2, cy = size.height / 2
        let r  = min(cx, cy) * 0.82

        var outerRing = Path()
        outerRing.addEllipse(in: CGRect(x: cx-r, y: cy-r, width: r*2, height: r*2))
        ctx.stroke(outerRing, with: .color(color), lineWidth: 1.6)

        var innerRing = Path()
        let r2 = r * 0.42
        innerRing.addEllipse(in: CGRect(x: cx-r2, y: cy-r2, width: r2*2, height: r2*2))
        ctx.stroke(innerRing, with: .color(color.opacity(0.55)), lineWidth: 1)

        for i in 0..<8 {
            let angle = Double(i) / 8.0 * .pi * 2
            let tx = cx + CGFloat(cos(angle)) * r
            let ty = cy + CGFloat(sin(angle)) * r
            var spoke = Path()
            spoke.move(to: CGPoint(x: cx, y: cy))
            spoke.addLine(to: CGPoint(x: tx, y: ty))
            ctx.stroke(spoke, with: .color(color.opacity(0.3)), lineWidth: 1)
            let dotR: CGFloat = 3
            var dot = Path()
            dot.addEllipse(in: CGRect(x: tx-dotR, y: ty-dotR, width: dotR*2, height: dotR*2))
            ctx.fill(dot, with: .color(color))
        }

        var ctr = Path()
        ctr.addEllipse(in: CGRect(x: cx-3.5, y: cy-3.5, width: 7, height: 7))
        ctx.fill(ctr, with: .color(color))
    }

    // MARK: Rhodes – piano keys (3 white + 2 black)

    private static func drawRhodes(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let keyW: CGFloat = size.width  * 0.26
        let keyH: CGFloat = size.height * 0.82
        let gap:  CGFloat = 2
        let startX = (size.width - keyW*3 - gap*2) / 2
        let keyY   = (size.height - keyH) / 2

        for i in 0..<3 {
            let x = startX + CGFloat(i) * (keyW + gap)
            var key = Path()
            key.addRoundedRect(in: CGRect(x: x, y: keyY, width: keyW, height: keyH),
                               cornerSize: CGSize(width: 2, height: 2))
            ctx.stroke(key, with: .color(color), lineWidth: 1.5)
        }

        let bkW  = keyW * 0.62
        let bkH  = keyH * 0.56
        let bkXs = [startX + keyW + gap - bkW/2,
                    startX + 2*(keyW+gap) - bkW/2]
        for bx in bkXs {
            var bkey = Path()
            bkey.addRoundedRect(in: CGRect(x: bx, y: keyY, width: bkW, height: bkH),
                                cornerSize: CGSize(width: 2, height: 2))
            ctx.fill(bkey, with: .color(color.opacity(0.95)))
        }
    }

    // MARK: Church organ – 5 vertical pipes

    private static func drawChurchPipes(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let heights: [CGFloat] = [0.42, 0.64, 0.90, 0.64, 0.42]
        let pipeW  = size.width / CGFloat(heights.count + 1.8)
        let gap    = pipeW * 0.22
        let totalW = CGFloat(heights.count) * pipeW + CGFloat(heights.count - 1) * gap
        let startX = (size.width - totalW) / 2

        for (i, h) in heights.enumerated() {
            let x      = startX + CGFloat(i) * (pipeW + gap)
            let height = size.height * h
            let y      = size.height - height + 1
            var pipe = Path()
            pipe.addRoundedRect(
                in: CGRect(x: x, y: y, width: pipeW, height: height - 1),
                cornerSize: CGSize(width: pipeW * 0.28, height: pipeW * 0.28)
            )
            ctx.fill(pipe, with: .color(color.opacity(0.8)))

            // Pipe mouth opening (small rectangle near top)
            let mouthW = pipeW * 0.55
            let mouthH: CGFloat = pipeW * 0.22
            var mouth = Path()
            mouth.addRect(CGRect(x: x + (pipeW-mouthW)/2, y: y + pipeW*0.55,
                                 width: mouthW, height: mouthH))
            ctx.fill(mouth, with: .color(color.opacity(0.3)))
        }
    }

    // MARK: Mystic Pad – layered sine waves

    private static func drawMysticWave(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let mid = size.height / 2
        for w in 0..<3 {
            let amp    = size.height * 0.22 * CGFloat(3 - w) / 3
            let phase  = Double(w) * .pi / 2.8
            let opac   = 1.0 - Double(w) * 0.3
            var path   = Path()
            var first  = true
            for xi in stride(from: 0.0, through: Double(size.width), by: 1.5) {
                let y  = Double(mid) + Double(amp) * sin(xi / Double(size.width) * 2.8 * .pi + phase)
                let pt = CGPoint(x: xi, y: y)
                if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(color.opacity(opac)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    // MARK: Dark Matter – inward spiral arcs

    private static func drawDarkVortex(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let cx = size.width / 2, cy = size.height / 2
        for i in 1...4 {
            let r        = min(cx, cy) * CGFloat(i) / 4.0 * 0.9
            let startDeg = Double(i) * 55
            let endDeg   = startDeg + 230
            var arc = Path()
            arc.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                       startAngle: .degrees(startDeg), endAngle: .degrees(endDeg),
                       clockwise: false)
            ctx.stroke(arc, with: .color(color.opacity(1.0 - Double(i-1) * 0.2)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
    }

    // MARK: Celestial – star constellation

    private static func drawCelestialDots(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let w = size.width, h = size.height
        let stars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.18, 0.18, 3.5), (0.82, 0.14, 2.5),
            (0.50, 0.48, 4.5), (0.14, 0.76, 3.0),
            (0.78, 0.72, 3.5), (0.92, 0.44, 2.0)
        ]
        let edges: [(Int,Int)] = [(0,2),(2,3),(2,4),(1,4),(4,5)]

        for (a, b) in edges {
            var line = Path()
            line.move(to:    CGPoint(x: stars[a].0*w, y: stars[a].1*h))
            line.addLine(to: CGPoint(x: stars[b].0*w, y: stars[b].1*h))
            ctx.stroke(line, with: .color(color.opacity(0.32)), lineWidth: 1)
        }
        for (sx, sy, sr) in stars {
            var dot = Path()
            dot.addEllipse(in: CGRect(x: sx*w-sr, y: sy*h-sr, width: sr*2, height: sr*2))
            ctx.fill(dot, with: .color(color))
        }
    }

    // MARK: Pulse Drive – narrow PWM pulse wave

    private static func drawPulseBolt(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let w = size.width, h = size.height
        let mid = h * 0.5
        let top = h * 0.08
        let bot = h * 0.92
        let pw  = w * 0.24   // pulse width

        var wave = Path()
        wave.move(to:    CGPoint(x: 0,          y: mid))
        wave.addLine(to: CGPoint(x: w*0.14,      y: mid))
        wave.addLine(to: CGPoint(x: w*0.14,      y: top))
        wave.addLine(to: CGPoint(x: w*0.14 + pw, y: top))
        wave.addLine(to: CGPoint(x: w*0.14 + pw, y: bot))
        wave.addLine(to: CGPoint(x: w*0.62,      y: bot))
        wave.addLine(to: CGPoint(x: w*0.62,      y: mid))
        wave.addLine(to: CGPoint(x: w,           y: mid))
        ctx.stroke(wave, with: .color(color),
                   style: StrokeStyle(lineWidth: 1.7, lineCap: .square, lineJoin: .miter))

        // Voltage-spike tick
        var tick = Path()
        tick.move(to:    CGPoint(x: w*0.14, y: top - 2))
        tick.addLine(to: CGPoint(x: w*0.14, y: top + 5))
        ctx.stroke(tick, with: .color(color.opacity(0.6)), lineWidth: 1)
    }

    // MARK: Void Walker – black hole rings

    private static func drawVoidHole(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let cx = size.width / 2, cy = size.height / 2
        let maxR = min(cx, cy) * 0.88

        for i in 1...5 {
            let t      = CGFloat(i) / 5.0
            let r      = maxR * t
            let squish = 1.0 - (1.0 - t) * 0.35
            var ellipse = Path()
            ellipse.addEllipse(in: CGRect(x: cx-r, y: cy-r*squish,
                                          width: r*2, height: r*squish*2))
            ctx.stroke(ellipse, with: .color(color.opacity((1.0 - t * 0.55) * 0.85)),
                       lineWidth: 1.1)
        }

        let cR: CGFloat = maxR * 0.25
        var core = Path()
        core.addEllipse(in: CGRect(x: cx-cR, y: cy-cR, width: cR*2, height: cR*2))
        ctx.fill(core, with: .color(color))
    }

    // MARK: Solar Wind – radial rays from centre

    private static func drawSolarRadial(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let cx = size.width / 2, cy = size.height / 2
        let coreR: CGFloat = min(cx, cy) * 0.26
        let rayLens: [CGFloat] = [0.68, 0.44, 0.62, 0.40, 0.68, 0.44, 0.62, 0.40,
                                   0.54, 0.36, 0.54, 0.36]

        for (i, len) in rayLens.enumerated() {
            let angle  = Double(i) / Double(rayLens.count) * .pi * 2
            let innerR = coreR + 3
            let outerR = min(cx, cy) * len
            var ray = Path()
            ray.move(to:    CGPoint(x: cx + CGFloat(cos(angle)) * innerR,
                                    y: cy + CGFloat(sin(angle)) * innerR))
            ray.addLine(to: CGPoint(x: cx + CGFloat(cos(angle)) * outerR,
                                    y: cy + CGFloat(sin(angle)) * outerR))
            ctx.stroke(ray, with: .color(color.opacity(0.9)), lineWidth: 1.5)
        }

        var core = Path()
        core.addEllipse(in: CGRect(x: cx-coreR, y: cy-coreR, width: coreR*2, height: coreR*2))
        ctx.fill(core, with: .color(color))
    }
}
