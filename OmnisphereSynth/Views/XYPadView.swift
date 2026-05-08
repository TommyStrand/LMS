import SwiftUI

struct TouchPoint: Identifiable {
    let id: Int
    var location: CGPoint
    var note: Int
    var velocity: Float
}

struct XYPadView: View {
    @ObservedObject var engine: AudioEngine
    let preset: SynthPreset

    @State private var activeTouches: [Int: TouchPoint] = [:]
    @State private var gridOpacity: Double = 0.15

    private let notes = [48, 50, 52, 53, 55, 57, 59, 60, 62, 64, 65, 67, 69, 71, 72]  // C major + octave

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color(hex: preset.color).opacity(0.25),
                        Color.black.opacity(0.85)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Grid lines
                gridOverlay(size: geo.size)

                // Active touch ripples
                ForEach(Array(activeTouches.values), id: \.id) { touch in
                    TouchRipple(color: Color(hex: preset.color))
                        .position(touch.location)
                }

                // Labels
                VStack {
                    HStack {
                        Text("← Brightness")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Modulation ↑")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                            .rotationEffect(.degrees(-90))
                            .offset(x: 10)
                    }
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { _ in }
            )
            .onAppear { animateGrid() }
            .simultaneousGesture(
                touchGesture(in: geo.size)
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color(hex: preset.color).opacity(0.5), lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func gridOverlay(size: CGSize) -> some View {
        let cols = 8
        let rows = 6
        Canvas { context, canvasSize in
            let colW = canvasSize.width / CGFloat(cols)
            let rowH = canvasSize.height / CGFloat(rows)
            var path = Path()
            for i in 1..<cols {
                let x = colW * CGFloat(i)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            }
            for i in 1..<rows {
                let y = rowH * CGFloat(i)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(gridOpacity)), lineWidth: 0.5)
        }
    }

    private func touchGesture(in size: CGSize) -> some Gesture {
        SimultaneousTouchGesture { events in
            for event in events {
                let loc = event.location
                let x = Float(loc.x / size.width)
                let y = Float(1 - loc.y / size.height)
                let noteIndex = Int(x * Float(notes.count - 1))
                let note = notes[max(0, min(noteIndex, notes.count - 1))]

                if event.phase == .began {
                    activeTouches[event.id] = TouchPoint(id: event.id, location: loc, note: note, velocity: 0.7 + y * 0.3)
                    engine.noteOn(touchID: event.id, note: note, velocity: 0.7 + y * 0.3, x: x, y: y)
                } else if event.phase == .moved {
                    activeTouches[event.id]?.location = loc
                    engine.updateTouch(touchID: event.id, x: x, y: y)
                } else if event.phase == .ended || event.phase == .cancelled {
                    activeTouches.removeValue(forKey: event.id)
                    engine.noteOff(touchID: event.id)
                }
            }
        }
    }

    private func animateGrid() {
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            gridOpacity = 0.3
        }
    }
}

// MARK: - Touch Ripple

struct TouchRipple: View {
    let color: Color
    @State private var scale: CGFloat = 0.5
    @State private var opacity: Double = 0.8

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 60, height: 60)
                .scaleEffect(scale)
            Circle()
                .strokeBorder(color.opacity(opacity), lineWidth: 2)
                .frame(width: 80, height: 80)
                .scaleEffect(scale)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).repeatForever(autoreverses: false)) {
                scale = 1.4
                opacity = 0
            }
        }
    }
}

// MARK: - Multi-touch Gesture

struct TouchEvent {
    let id: Int
    let location: CGPoint
    let phase: UITouch.Phase
}

struct SimultaneousTouchGesture: UIViewRepresentable {
    let handler: ([TouchEvent]) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.handler = handler
        return v
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
        let events = touches.map { t in
            TouchEvent(id: t.hash, location: t.location(in: self), phase: phase)
        }
        handler?(events)
    }

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) { send(t, phase: .began) }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { send(t, phase: .moved) }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { send(t, phase: .ended) }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { send(t, phase: .cancelled) }
}
