import SwiftUI

struct TouchPoint: Identifiable {
    let id: Int
    var location: CGPoint
    var note: Int
    var velocity: Float
}

struct XYPadView: View {
    @ObservedObject var engine: AudioEngine
    @EnvironmentObject var themeManager: ThemeManager
    let preset: SynthPreset

    @State private var activeTouches: [Int: TouchPoint] = [:]
    @State private var gridOpacity: Double = 0.12

    private var notes: [Int] {
        let root = themeManager.rootNote + themeManager.transposeOctave * 12
        let clamped = max(0, min(root, 108))
        return themeManager.scale.notes(rootMidi: clamped, octaves: 2)
    }

    var body: some View {
        let theme = themeManager.current
        let accent = theme.accent(for: Color(hex: preset.color))

        GeometryReader { geo in
            ZStack {
                // Background
                padBackground(theme: theme, accent: accent)

                // Grid
                gridOverlay(size: geo.size, theme: theme, accent: accent)

                // Ripples + note names
                ForEach(Array(activeTouches.values), id: \.id) { touch in
                    TouchRipple(color: accent)
                        .position(touch.location)
                    Text(midiToNoteName(touch.note))
                        .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                        .foregroundColor(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.panelBackground.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .position(x: touch.location.x,
                                  y: max(20, touch.location.y - 54))
                        .allowsHitTesting(false)
                }

                // Labels
                padLabels(theme: theme)
            }
            .contentShape(Rectangle())
            .onAppear { animateGrid() }
            .overlay(
                SimultaneousTouchGesture { events in
                    let currentNotes = notes
                    guard !currentNotes.isEmpty else { return }
                    for event in events {
                        let loc = event.location
                        let x   = Float(loc.x / geo.size.width)
                        let y   = Float(1 - loc.y / geo.size.height)
                        let ni  = Int(x * Float(currentNotes.count - 1))
                        let note = currentNotes[max(0, min(ni, currentNotes.count - 1))]
                        switch event.phase {
                        case .began:
                            activeTouches[event.id] = TouchPoint(id: event.id, location: loc,
                                                                  note: note, velocity: 0.7 + y * 0.3)
                            engine.noteOn(touchID: event.id, note: note,
                                          velocity: 0.7 + y * 0.3, x: x, y: y)
                        case .moved:
                            activeTouches[event.id]?.location = loc
                            engine.updateTouch(touchID: event.id, x: x, y: y)
                        default:
                            activeTouches.removeValue(forKey: event.id)
                            engine.noteOff(touchID: event.id)
                        }
                    }
                }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius * 1.4))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius * 1.4)
                .strokeBorder(accent.opacity(0.6), lineWidth: 1.5)
        )
        .shadow(color: accent.opacity(theme.id == "radar" || theme.id == "cyber" ? 0.3 : 0.1),
                radius: 12)
    }

    // MARK: Background

    private func padBackground(theme: AppTheme, accent: Color) -> some View {
        Group {
            if theme.id == "radio" {
                LinearGradient(colors: [Color(hex: "#2C1A0C"), Color(hex: "#1A0C06")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else if theme.id == "ivory" {
                LinearGradient(colors: [Color(hex: "#D8D0C0"), Color(hex: "#C8C0B0")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                LinearGradient(
                    colors: [accent.opacity(0.18), theme.appBackground.opacity(0.9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
    }

    // MARK: Grid

    private func gridOverlay(size: CGSize, theme: AppTheme, accent: Color) -> some View {
        Canvas { context, _ in
            let cols = 8, rows = 6
            let colW = size.width  / CGFloat(cols)
            let rowH = size.height / CGFloat(rows)
            var path = Path()
            for i in 1..<cols {
                let x = colW * CGFloat(i)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for i in 1..<rows {
                let y = rowH * CGFloat(i)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(accent.opacity(gridOpacity)), lineWidth: 0.6)
        }
    }

    // MARK: Labels

    @ViewBuilder
    private func padLabels(theme: AppTheme) -> some View {
        let root = midiToNoteName(themeManager.rootNote + themeManager.transposeOctave * 12)
            .components(separatedBy: CharacterSet.decimalDigits).joined()
        VStack {
            HStack {
                Text("← Brightness")
                    .font(.system(size: 10, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText.opacity(0.35))
                Spacer()
                Text("\(root) \(themeManager.scale.label)")
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText.opacity(0.45))
            }
            Spacer()
            HStack {
                Spacer()
                Text("Modulation ↑")
                    .font(.system(size: 10, design: theme.fontDesign))
                    .foregroundColor(theme.primaryText.opacity(0.35))
                    .rotationEffect(.degrees(-90))
                    .offset(x: 12)
            }
        }
        .padding(14)
    }

    private func animateGrid() {
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            gridOpacity = 0.28
        }
    }

    private func midiToNoteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (midi / 12) - 1
        return "\(names[midi % 12])\(octave)"
    }
}

// MARK: - Touch Ripple

struct TouchRipple: View {
    let color: Color
    @State private var scale: CGFloat = 0.4
    @State private var opacity: Double = 0.9

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 64, height: 64).scaleEffect(scale)
            Circle().strokeBorder(color.opacity(opacity), lineWidth: 2).frame(width: 88, height: 88).scaleEffect(scale)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.65).repeatForever(autoreverses: false)) {
                scale = 1.5; opacity = 0
            }
        }
    }
}

// MARK: - Multi-touch

struct TouchEvent {
    let id: Int
    let location: CGPoint
    let phase: UITouch.Phase
}

struct SimultaneousTouchGesture: UIViewRepresentable {
    let handler: ([TouchEvent]) -> Void
    func makeUIView(context: Context) -> TouchView {
        let v = TouchView(); v.handler = handler; return v
    }
    func updateUIView(_ v: TouchView, context: Context) { v.handler = handler }
}

final class TouchView: UIView {
    var handler: (([TouchEvent]) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    private func send(_ touches: Set<UITouch>, phase: UITouch.Phase) {
        handler?(touches.map { TouchEvent(id: $0.hash, location: $0.location(in: self), phase: phase) })
    }
    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?)    { send(t, phase: .began) }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?)    { send(t, phase: .moved) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?)    { send(t, phase: .ended) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { send(t, phase: .cancelled) }
}
