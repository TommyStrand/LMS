import SwiftUI

// MARK: - Play mode

enum PlayMode: String, CaseIterable, Identifiable {
    case grid        = "grid"
    case glissando   = "glissando"
    case keyboard    = "keyboard"
    case isomorphic  = "isomorphic"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid:       return "Grid"
        case .glissando:  return "Glissando"
        case .keyboard:   return "Keyboard"
        case .isomorphic: return "Fretboard"
        }
    }

    var icon: String {
        switch self {
        case .grid:       return "square.grid.3x3"
        case .glissando:  return "hand.draw"
        case .keyboard:   return "pianokeys"
        case .isomorphic: return "rectangle.grid.3x2"
        }
    }
}

// MARK: - Musical scale

enum MusicalScale: String, CaseIterable, Identifiable {
    case major         = "major"
    case minor         = "minor"
    case dorian        = "dorian"
    case phrygian      = "phrygian"
    case lydian        = "lydian"
    case mixolydian    = "mixolydian"
    case locrian       = "locrian"
    case harmonicMinor = "harmonicMinor"
    case pentatonic    = "pentatonic"
    case blues         = "blues"
    case chromatic     = "chromatic"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .major:         return "Major"
        case .minor:         return "Minor"
        case .dorian:        return "Dorian"
        case .phrygian:      return "Phrygian"
        case .lydian:        return "Lydian"
        case .mixolydian:    return "Mixolydian"
        case .locrian:       return "Locrian"
        case .harmonicMinor: return "Harm. Minor"
        case .pentatonic:    return "Pentatonic"
        case .blues:         return "Blues"
        case .chromatic:     return "Chromatic"
        }
    }

    var intervals: [Int] {
        switch self {
        case .major:         return [0, 2, 4, 5, 7, 9, 11]
        case .minor:         return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:        return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian:      return [0, 1, 3, 5, 7, 8, 10]
        case .lydian:        return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian:    return [0, 2, 4, 5, 7, 9, 10]
        case .locrian:       return [0, 1, 3, 5, 6, 8, 10]
        case .harmonicMinor: return [0, 2, 3, 5, 7, 8, 11]
        case .pentatonic:    return [0, 2, 4, 7, 9]
        case .blues:         return [0, 3, 5, 6, 7, 10]
        case .chromatic:     return Array(0...11)
        }
    }

    func notes(rootMidi: Int, octaves: Int) -> [Int] {
        var result: [Int] = []
        for oct in 0..<octaves {
            for interval in intervals {
                let note = rootMidi + oct * 12 + interval
                if note >= 0 && note <= 127 { result.append(note) }
            }
        }
        return result
    }
}

// MARK: - Control style

enum ControlStyle: String, CaseIterable, Identifiable {
    case rotary  = "rotary"
    case ledRing = "ledRing"
    case fader   = "fader"
    case flatArc = "flatArc"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rotary:  return "Rotary"
        case .ledRing: return "LED Ring"
        case .fader:   return "Fader"
        case .flatArc: return "Flat Arc"
        }
    }

    var icon: String {
        switch self {
        case .rotary:  return "dial.medium"
        case .ledRing: return "circle.dotted"
        case .fader:   return "slider.vertical.3"
        case .flatArc: return "circle.dashed"
        }
    }
}

// MARK: - Theme definition

struct AppTheme: Identifiable {
    let id: String
    let name: String
    let icon: String            // SF Symbol

    let appBackground: Color
    let panelBackground: Color
    let panelBorder: Color
    let knobBody: Color
    let knobTrackBg: Color      // arc background ring
    let accentOverride: Color?  // nil = use preset colour
    let primaryText: Color
    let secondaryText: Color
    let fontDesign: Font.Design
    let colorScheme: ColorScheme
    let scanlines: Bool         // CRT scanline overlay
    let cornerRadius: CGFloat

    func accent(for presetColor: Color) -> Color {
        accentOverride ?? presetColor
    }

    // MARK: - 5 built-in themes

    static let cosmos = AppTheme(
        id: "cosmos", name: "Dark Cosmos", icon: "sparkles",
        appBackground: Color(hex: "#080814"),
        panelBackground: Color(hex: "#0E0E22"),
        panelBorder: Color.white.opacity(0.08),
        knobBody: Color(hex: "#12122A"),
        knobTrackBg: Color.white.opacity(0.05),
        accentOverride: nil,
        primaryText: .white,
        secondaryText: Color.white.opacity(0.45),
        fontDesign: .default,
        colorScheme: .dark,
        scanlines: false,
        cornerRadius: 12
    )

    static let radio = AppTheme(
        id: "radio", name: "Analog Radio", icon: "radio",
        appBackground: Color(hex: "#1A0C06"),
        panelBackground: Color(hex: "#E8D0A0"),
        panelBorder: Color(hex: "#7A4F28"),
        knobBody: Color(hex: "#C4A070"),
        knobTrackBg: Color(hex: "#7A4F28").opacity(0.25),
        accentOverride: Color(hex: "#D4821A"),
        primaryText: Color(hex: "#2C1408"),
        secondaryText: Color(hex: "#6B3A18"),
        fontDesign: .rounded,
        colorScheme: .light,
        scanlines: false,
        cornerRadius: 8
    )

    static let radar = AppTheme(
        id: "radar", name: "Radar", icon: "scope",
        appBackground: Color(hex: "#010A04"),
        panelBackground: Color(hex: "#020F06"),
        panelBorder: Color(hex: "#00FF41").opacity(0.35),
        knobBody: Color(hex: "#021A08"),
        knobTrackBg: Color(hex: "#00FF41").opacity(0.08),
        accentOverride: Color(hex: "#00FF41"),
        primaryText: Color(hex: "#00FF41"),
        secondaryText: Color(hex: "#00FF41").opacity(0.55),
        fontDesign: .monospaced,
        colorScheme: .dark,
        scanlines: true,
        cornerRadius: 4
    )

    static let cyber = AppTheme(
        id: "cyber", name: "Neon Cyber", icon: "bolt.fill",
        appBackground: Color(hex: "#080010"),
        panelBackground: Color(hex: "#10001A"),
        panelBorder: Color(hex: "#FF006E").opacity(0.45),
        knobBody: Color(hex: "#180025"),
        knobTrackBg: Color(hex: "#FF006E").opacity(0.08),
        accentOverride: Color(hex: "#FF006E"),
        primaryText: Color(hex: "#FF006E"),
        secondaryText: Color(hex: "#00F5FF").opacity(0.75),
        fontDesign: .default,
        colorScheme: .dark,
        scanlines: false,
        cornerRadius: 2
    )

    static let ivory = AppTheme(
        id: "ivory", name: "Warm Ivory", icon: "pianokeys",
        appBackground: Color(hex: "#EAE4D8"),
        panelBackground: Color(hex: "#D4CABC"),
        panelBorder: Color(hex: "#8B7355"),
        knobBody: Color(hex: "#BEB4A4"),
        knobTrackBg: Color(hex: "#8B7355").opacity(0.2),
        accentOverride: Color(hex: "#C02020"),
        primaryText: Color(hex: "#1E1208"),
        secondaryText: Color(hex: "#5A3A1A"),
        fontDesign: .rounded,
        colorScheme: .light,
        scanlines: false,
        cornerRadius: 8
    )

    static let all: [AppTheme] = [.cosmos, .radio, .radar, .cyber, .ivory]
}

// MARK: - Manager

/// User-selected theme / control style / play mode / scale / root / transpose.
///
/// `@Observable` (iOS 17): views re-render only for the properties they actually
/// read — e.g. changing the scale no longer invalidates views that only read the
/// theme colours. Persistence is plain UserDefaults via `didSet` (the `@AppStorage`
/// wrapper is a SwiftUI DynamicProperty and does not work inside an @Observable
/// class). Keys are unchanged, so existing users keep their settings.
@Observable
final class ThemeManager {
    private let defaults = UserDefaults.standard   // `let`s are never tracked

    private var storedId: String {
        didSet { defaults.set(storedId, forKey: "selectedThemeId") }
    }
    private var storedControlStyle: String {
        didSet { defaults.set(storedControlStyle, forKey: "controlStyle") }
    }
    private var storedPlayMode: String {
        didSet { defaults.set(storedPlayMode, forKey: "playMode") }
    }
    private var storedScaleId: String {
        didSet { defaults.set(storedScaleId, forKey: "scaleId") }
    }
    var rootNote: Int {
        didSet { defaults.set(rootNote, forKey: "rootNote") }
    }
    var transposeOctave: Int {
        didSet { defaults.set(transposeOctave, forKey: "transposeOctave") }
    }

    init() {
        let d = UserDefaults.standard
        storedId           = d.string(forKey: "selectedThemeId") ?? "cosmos"
        storedControlStyle = d.string(forKey: "controlStyle")    ?? ControlStyle.rotary.rawValue
        storedPlayMode     = d.string(forKey: "playMode")        ?? PlayMode.grid.rawValue
        storedScaleId      = d.string(forKey: "scaleId")         ?? MusicalScale.major.rawValue
        // integer(forKey:) returns 0 for a missing key, so check presence to keep
        // the historical default root of C3 (48) on first launch.
        rootNote        = d.object(forKey: "rootNote") == nil ? 48 : d.integer(forKey: "rootNote")
        transposeOctave = d.integer(forKey: "transposeOctave")
    }

    var current: AppTheme {
        AppTheme.all.first { $0.id == storedId } ?? .cosmos
    }

    var controlStyle: ControlStyle {
        ControlStyle(rawValue: storedControlStyle) ?? .rotary
    }

    var playMode: PlayMode {
        PlayMode(rawValue: storedPlayMode) ?? .grid
    }

    var scale: MusicalScale {
        MusicalScale(rawValue: storedScaleId) ?? .major
    }

    // Mutating the backing storage is itself the change notification under
    // @Observable — no manual objectWillChange.send() needed.
    func select(_ theme: AppTheme)                 { storedId = theme.id }
    func selectControlStyle(_ style: ControlStyle) { storedControlStyle = style.rawValue }
    func selectPlayMode(_ mode: PlayMode)          { storedPlayMode = mode.rawValue }
    func selectScale(_ scale: MusicalScale)        { storedScaleId = scale.rawValue }
    func selectRootNote(_ midi: Int)               { rootNote = midi }
}
