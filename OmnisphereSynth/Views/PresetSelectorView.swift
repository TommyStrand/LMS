import SwiftUI

struct PresetSelectorView: View {
    @Binding var selectedIndex: Int
    var engine: AudioEngine
    @Environment(ThemeManager.self) var themeManager
    let onSelect: (SynthPreset) -> Void

    var body: some View {
        let theme = themeManager.current
        VStack(spacing: 0) {
            chipRow(theme: theme)
            if engine.isLayeringMode && !engine.activeLayerIndices.isEmpty {
                layerGainRow(theme: theme)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Chip row

    private func chipRow(theme: AppTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if engine.isLayeringMode {
                    exitLayerButton(theme: theme)
                }
                ForEach(Array(SynthPreset.presets.enumerated()), id: \.offset) { idx, preset in
                    PresetChip(
                        preset: preset,
                        isSelected: idx == selectedIndex,
                        isLayeringMode: engine.isLayeringMode,
                        isActiveLayer: engine.activeLayerIndices.contains(idx),
                        isPrimaryLayer: engine.primaryLayerIndex == idx,
                        theme: theme
                    )
                    .onTapGesture {
                        handleTap(idx: idx, preset: preset)
                    }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        handleLongPress(idx: idx, preset: preset)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Exit button

    private func exitLayerButton(theme: AppTheme) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3)) { engine.exitLayerMode() }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                        .fill(theme.panelBackground)
                        .frame(width: 52, height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                                .strokeBorder(theme.panelBorder, lineWidth: 1)
                        )
                    VStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                        Text("LAYER")
                            .font(.system(size: 7, weight: .bold, design: theme.fontDesign))
                            .foregroundColor(theme.secondaryText)
                            .kerning(1)
                    }
                }
                Color.clear.frame(width: 52, height: 14) // align with chip labels
            }
        }
    }

    // MARK: - Gain knob row

    private func layerGainRow(theme: AppTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(engine.activeLayerIndices, id: \.self) { idx in
                    let preset = SynthPreset.presets[idx]
                    let accent = theme.accent(for: Color(hex: preset.color))
                    VStack(spacing: 3) {
                        Text(preset.name)
                            .font(.system(size: 8, weight: .semibold, design: theme.fontDesign))
                            .foregroundColor(accent)
                            .lineLimit(1)
                            .frame(width: 64)
                        KnobView(
                            label: "VOL",
                            value: engine.layerGain(for: idx),
                            color: accent
                        ) { engine.setLayerGain($0, for: idx) }
                        .frame(width: 56, height: 56)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Gesture handlers

    private func handleTap(idx: Int, preset: SynthPreset) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if engine.isLayeringMode {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                engine.toggleLayer(presetIndex: idx)
            }
            // Controls follow whichever preset is now primary
            if let primary = engine.primaryLayerIndex {
                selectedIndex = primary
                onSelect(SynthPreset.presets[primary])
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedIndex = idx
            }
            onSelect(preset)
        }
    }

    private func handleLongPress(idx: Int, preset: SynthPreset) {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if engine.isLayeringMode {
            withAnimation(.spring(response: 0.3)) { engine.exitLayerMode() }
        } else {
            withAnimation(.spring(response: 0.3)) {
                engine.enterLayerMode(startingWith: idx)
                selectedIndex = idx
            }
            onSelect(preset)
        }
    }
}

// MARK: - Preset chip

struct PresetChip: View {
    let preset: SynthPreset
    let isSelected: Bool
    let isLayeringMode: Bool
    let isActiveLayer: Bool
    let isPrimaryLayer: Bool
    let theme: AppTheme

    private var accentColor: Color { theme.accent(for: Color(hex: preset.color)) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                        .fill(fillColor)
                        .frame(width: 64, height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadius * 0.8)
                                .strokeBorder(borderColor, lineWidth: borderWidth)
                        )
                        .shadow(color: shadowColor, radius: 10)

                    PresetIcon(iconStyle: preset.iconStyle,
                               color: iconColor)
                        .frame(width: 38, height: 38)
                }

                // Active-layer badge (dot in top-right corner)
                if isLayeringMode && isActiveLayer {
                    Circle()
                        .fill(isPrimaryLayer ? accentColor : accentColor.opacity(0.7))
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle().strokeBorder(theme.panelBackground, lineWidth: 1.5)
                        )
                        .offset(x: 3, y: -3)
                }
            }
            .frame(width: 64, height: 64)

            Text(preset.name)
                .font(.system(size: 9, weight: .medium, design: theme.fontDesign))
                .foregroundColor(labelColor)
                .lineLimit(1)
                .frame(width: 72)
        }
        .scaleEffect(scaleAmount)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPrimaryLayer)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActiveLayer)
    }

    private var fillColor: Color {
        if isPrimaryLayer { return accentColor.opacity(0.85) }
        if isActiveLayer  { return accentColor.opacity(0.22) }
        if !isLayeringMode && isSelected { return accentColor.opacity(0.85) }
        return theme.panelBackground
    }

    private var borderColor: Color {
        if isPrimaryLayer || (!isLayeringMode && isSelected) { return accentColor }
        if isActiveLayer { return accentColor.opacity(0.65) }
        return accentColor.opacity(isLayeringMode ? 0.2 : 0.4)
    }

    private var borderWidth: CGFloat {
        if isPrimaryLayer || (!isLayeringMode && isSelected) { return 2 }
        if isActiveLayer { return 1.5 }
        return 1
    }

    private var shadowColor: Color {
        if isPrimaryLayer || (!isLayeringMode && isSelected) { return accentColor.opacity(0.5) }
        if isActiveLayer { return accentColor.opacity(0.2) }
        return .clear
    }

    private var iconColor: Color {
        if isPrimaryLayer || (!isLayeringMode && isSelected) { return theme.primaryText }
        if isActiveLayer { return accentColor }
        return accentColor.opacity(isLayeringMode ? 0.4 : 1.0)
    }

    private var labelColor: Color {
        if isPrimaryLayer || (!isLayeringMode && isSelected) { return accentColor }
        if isActiveLayer { return accentColor.opacity(0.85) }
        return isLayeringMode ? theme.secondaryText.opacity(0.5) : theme.secondaryText
    }

    private var scaleAmount: CGFloat {
        if isPrimaryLayer { return 1.05 }
        if isActiveLayer  { return 1.02 }
        if !isLayeringMode && isSelected { return 1.05 }
        return isLayeringMode ? 0.95 : 1.0
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
            case .pianoKeys:        Self.drawPianoKeys(ctx, size, color)
            case .stringBow:        Self.drawStringBow(ctx, size, color)
            case .fluteShape:       Self.drawFluteShape(ctx, size, color)
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
        let pipeW  = size.width / (CGFloat(heights.count) + 1.8)
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
        let pw  = w * 0.24

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

    // MARK: Piano Keys – 4 white keys + 3 black keys

    private static func drawPianoKeys(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let w = size.width, h = size.height
        let keyW: CGFloat = w * 0.20
        let keyH: CGFloat = h * 0.80
        let gap:  CGFloat = 1.5
        let startX = (w - keyW * 4 - gap * 3) / 2
        let keyY   = (h - keyH) / 2

        for i in 0..<4 {
            let x = startX + CGFloat(i) * (keyW + gap)
            var key = Path()
            key.addRoundedRect(in: CGRect(x: x, y: keyY, width: keyW, height: keyH),
                               cornerSize: CGSize(width: 2, height: 2))
            ctx.stroke(key, with: .color(color), lineWidth: 1.4)
        }
        // Black keys over gaps 0-1, 1-2, 2-3
        let bkW = keyW * 0.6
        let bkH = keyH * 0.55
        let bkXs: [CGFloat] = [
            startX + keyW + gap - bkW / 2,
            startX + (keyW + gap) * 2 - bkW / 2,
            startX + (keyW + gap) * 3 - bkW / 2,
        ]
        for bx in bkXs {
            var bk = Path()
            bk.addRoundedRect(in: CGRect(x: bx, y: keyY, width: bkW, height: bkH),
                              cornerSize: CGSize(width: 2, height: 2))
            ctx.fill(bk, with: .color(color.opacity(0.9)))
        }
    }

    // MARK: String Bow – two curved string arcs + bow stick

    private static func drawStringBow(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let w = size.width, h = size.height
        let mid = h / 2

        // Two string arcs (slightly offset vertically)
        for dy in [-h * 0.12, h * 0.12] as [CGFloat] {
            var path = Path()
            path.move(to: CGPoint(x: w * 0.08, y: mid + dy))
            path.addCurve(
                to:         CGPoint(x: w * 0.92, y: mid + dy),
                control1:   CGPoint(x: w * 0.3,  y: mid + dy - h * 0.2),
                control2:   CGPoint(x: w * 0.7,  y: mid + dy + h * 0.2)
            )
            ctx.stroke(path, with: .color(color.opacity(0.75)),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        // Bow stick (diagonal line)
        var bow = Path()
        bow.move(to:    CGPoint(x: w * 0.15, y: h * 0.25))
        bow.addLine(to: CGPoint(x: w * 0.85, y: h * 0.75))
        ctx.stroke(bow, with: .color(color),
                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        // Hair (parallel to stick, offset)
        var hair = Path()
        hair.move(to:    CGPoint(x: w * 0.22, y: h * 0.18))
        hair.addLine(to: CGPoint(x: w * 0.92, y: h * 0.68))
        ctx.stroke(hair, with: .color(color.opacity(0.4)),
                   style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    // MARK: Flute Shape – horizontal tube + tone holes

    private static func drawFluteShape(_ ctx: GraphicsContext, _ size: CGSize, _ color: Color) {
        let w = size.width, h = size.height
        let tubeY  = h * 0.38
        let tubeH: CGFloat = h * 0.24
        let tubeX: CGFloat = w * 0.08
        let tubeW  = w * 0.84
        // Tube body
        var tube = Path()
        tube.addRoundedRect(in: CGRect(x: tubeX, y: tubeY, width: tubeW, height: tubeH),
                            cornerSize: CGSize(width: tubeH / 2, height: tubeH / 2))
        ctx.stroke(tube, with: .color(color), lineWidth: 1.6)
        // Embouchure hole (slightly larger oval at left)
        let emX = tubeX + tubeW * 0.12
        let emR: CGFloat = tubeH * 0.5
        var emb = Path()
        emb.addEllipse(in: CGRect(x: emX - emR * 1.3, y: tubeY + tubeH * 0.5 - emR * 0.9,
                                  width: emR * 2.6, height: emR * 1.8))
        ctx.fill(emb, with: .color(color.opacity(0.7)))
        // Tone holes (five small circles)
        let holeXs: [CGFloat] = [0.35, 0.47, 0.57, 0.66, 0.75]
        let holeR: CGFloat = tubeH * 0.26
        for hx in holeXs {
            var hole = Path()
            hole.addEllipse(in: CGRect(
                x: tubeX + tubeW * hx - holeR,
                y: tubeY + tubeH * 0.5 - holeR,
                width: holeR * 2, height: holeR * 2
            ))
            ctx.fill(hole, with: .color(color.opacity(0.5)))
        }
    }
}
