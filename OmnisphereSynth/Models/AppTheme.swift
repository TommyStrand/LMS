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

// MARK: - Pitch snapping (pure — unit-tested in SuperNovaPadTests)

/// The keyboard's continuous-pitch maths, factored out of `PianoKeyboardView` so
/// the snap-after-slide behaviour can be verified without touch input.
enum PitchSnap {
    /// Semitones of pitch per white-key width of horizontal travel. 12 chromatic
    /// semitones are spread across 7 white keys per octave, so this is the
    /// average piano ratio (≈1.714).
    static let semitonesPerWhiteKey = 12.0 / 7.0

    /// Continuous bend for a horizontal finger displacement.
    static func semitones(dx: Double, keyWidth: Double) -> Double {
        guard keyWidth > 0 else { return 0 }
        return dx / keyWidth * semitonesPerWhiteKey
    }

    /// Nearest MIDI note belonging to `scale` (rooted at `rootNote`'s pitch class)
    /// to a fractional pitch. For the chromatic scale this is plain rounding.
    /// Ties resolve to the LOWER note (first candidate wins on equal distance).
    static func nearestScaleMidi(to pitch: Double, rootNote: Int, scale: MusicalScale) -> Int {
        let rootPc    = ((rootNote % 12) + 12) % 12
        let intervals = Set(scale.intervals)
        let center    = Int(pitch.rounded())
        var best      = center
        var bestDist  = Double.infinity
        for cand in (center - 6)...(center + 6) {
            let pc = (((cand - rootPc) % 12) + 12) % 12
            guard intervals.contains(pc) else { continue }
            let d = abs(Double(cand) - pitch)
            if d < bestDist { bestDist = d; best = cand }
        }
        return min(127, max(0, best))
    }
}

// MARK: - Finger vibrato (pure — unit-tested in SuperNovaPadTests)

/// MorphWiz-style "Finger Vibrato Effect": while a note is locked (a tap, or a
/// slide that has snapped to the scale), small side-to-side wiggles bend the
/// pitch around the locked note instead of releasing it into a free slide.
/// Moving further than `captureRadius` key-widths breaks the lock.
enum FingerVibrato {
    /// Lock radius in white-key widths. Equal to the keyboard's slide threshold,
    /// so leaving the lock always counts as a real slide.
    static let captureRadius = 0.4
    /// The voices smooth pitch bend with a ~75 ms time constant, which passes only
    /// about a third of a 5–6 Hz wiggle. This gain compensates for that.
    static let gain = 2.5
    /// Clamp on the requested bend (semitones, before voice smoothing). After
    /// smoothing this lands around ±25 cents — a natural vibrato depth.
    static let maxDepth = 0.75

    /// Pitch-bend target (semitones relative to the touch's original note) for a
    /// finger at `x` locked onto `lockedTarget` around `anchorX`, or nil when the
    /// finger has left the capture radius and should become a free slide.
    static func bend(lockedTarget: Double, anchorX: Double, x: Double, keyWidth: Double) -> Double? {
        guard keyWidth > 0 else { return nil }
        let dxKeys = (x - anchorX) / keyWidth
        guard abs(dxKeys) <= captureRadius else { return nil }
        let raw = dxKeys * PitchSnap.semitonesPerWhiteKey * gain
        return lockedTarget + min(maxDepth, max(-maxDepth, raw))
    }
}

// MARK: - Pitch colour (pure — unit-tested in SuperNovaPadTests)

/// Maps a (possibly fractional) MIDI pitch onto a 0..<1 colour-wheel position by
/// pitch class: every C is red, and the 12 semitones walk once round the wheel.
/// Fractional pitches land between hues, so a glide sweeps colour smoothly.
enum PitchColor {
    static func hue(for pitch: Double) -> Double {
        let pc = pitch.truncatingRemainder(dividingBy: 12)
        let h  = (pc < 0 ? pc + 12 : pc) / 12
        return h >= 1 ? 0 : h   // a tiny negative remainder can round up to exactly 1.0
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

    /// The same theme with see-through surfaces, used while an instrument backdrop
    /// is showing behind the UI. Panels keep their tint but let the scene through;
    /// borders and text are untouched so everything stays legible.
    ///
    /// With a `palette` (colours sampled from the scene) the whole UI is re-tinted
    /// to match it: the scene's glow becomes the accent for every preset, and
    /// panels take a dark version of its ambient colour — so a warm, vintage scene
    /// doesn't sit next to cool neon chrome.
    func glass(palette: BackdropPalette? = nil) -> AppTheme {
        if let p = palette {
            return AppTheme(id: id, name: name, icon: icon,
                            appBackground: p.ambient.scaled(toMax: 0.10).color.opacity(0.30),
                            panelBackground: p.ambient.scaled(toMax: 0.17).color.opacity(0.62),
                            panelBorder: p.key.color.opacity(0.18),
                            knobBody: p.ambient.scaled(toMax: 0.20).color.opacity(0.85),
                            knobTrackBg: p.key.color.opacity(0.10),
                            accentOverride: p.key.color,
                            primaryText: primaryText,
                            secondaryText: secondaryText,
                            fontDesign: fontDesign,
                            colorScheme: colorScheme,
                            scanlines: scanlines,
                            cornerRadius: cornerRadius)
        }
        return AppTheme(id: id, name: name, icon: icon,
                 appBackground: appBackground.opacity(0.30),
                 panelBackground: panelBackground.opacity(0.55),
                 panelBorder: panelBorder,
                 knobBody: knobBody.opacity(0.75),
                 knobTrackBg: knobTrackBg,
                 accentOverride: accentOverride,
                 primaryText: primaryText,
                 secondaryText: secondaryText,
                 fontDesign: fontDesign,
                 colorScheme: colorScheme,
                 scanlines: scanlines,
                 cornerRadius: cornerRadius)
    }
}

// MARK: - Backdrop palette (pure — unit-tested in SuperNovaPadTests)

/// Two colours sampled from a backdrop scene: `ambient` (its overall cast) and
/// `key` (its brightest saturated light — lamp glow, fire, moonlight).
struct BackdropPalette: Equatable {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double

        /// Same hue and saturation, brightness set so the largest channel is `v`.
        func scaled(toMax v: Double) -> RGB {
            let m = max(r, g, b)
            guard m > 0.0001 else { return RGB(r: v, g: v, b: v) }
            return RGB(r: r / m * v, g: g / m * v, b: b / m * v)
        }
        var color: Color { Color(red: r, green: g, blue: b) }

        /// "#RRGGBB" (the "#" is optional). Anything unparsable gives mid grey.
        init(hex: String) {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let v = UInt32(digits, radix: 16) else {
                self.init(r: 0.5, g: 0.5, b: 0.5); return
            }
            self.init(r: Double((v >> 16) & 0xFF) / 255,
                      g: Double((v >> 8) & 0xFF) / 255,
                      b: Double(v & 0xFF) / 255)
        }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

        /// The colour with its hue rotated by `turns` (1 = full circle); saturation
        /// and brightness are kept. Greys are returned unchanged.
        func rotated(byTurns turns: Double) -> RGB {
            guard let h = BackdropPalette.hue(self) else { return self }
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            var nh = (h + turns).truncatingRemainder(dividingBy: 1)
            if nh < 0 { nh += 1 }
            let i = Int(nh * 6), f = nh * 6 - Double(i)
            let p = mx * (1 - sat), q = mx * (1 - f * sat), t = mx * (1 - (1 - f) * sat)
            switch i % 6 {
            case 0:  return RGB(r: mx, g: t,  b: p)
            case 1:  return RGB(r: q,  g: mx, b: p)
            case 2:  return RGB(r: p,  g: mx, b: t)
            case 3:  return RGB(r: p,  g: q,  b: mx)
            case 4:  return RGB(r: t,  g: p,  b: mx)
            default: return RGB(r: mx, g: p,  b: q)
            }
        }
    }

    /// Palette for a generated (image-less) scene: the preset's own colour is both
    /// the light and the cast.
    init(presetColor: RGB) {
        let bright = presetColor.scaled(toMax: 0.92)
        let soft = 0.15
        self.init(ambient: presetColor,
                  key: RGB(r: bright.r + (0.92 - bright.r) * soft,
                           g: bright.g + (0.92 - bright.g) * soft,
                           b: bright.b + (0.92 - bright.b) * soft))
    }
    init(ambient: RGB, key: RGB) { self.ambient = ambient; self.key = key }

    var ambient: RGB
    var key: RGB

    /// Hue on 0..<1 (0 = red), or nil for a grey.
    static func hue(_ c: RGB) -> Double? {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 0.0001 else { return nil }
        var h: Double
        if mx == c.r      { h = (c.g - c.b) / d }
        else if mx == c.g { h = (c.b - c.r) / d + 2 }
        else              { h = (c.r - c.g) / d + 4 }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    /// Shortest distance between two hues on the colour wheel (0...0.5).
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    /// `rgba`: 8-bit RGBA pixels of a small thumbnail of the scene.
    /// Ambient = mean colour. Key = the scene's dominant light: pixels are ranked
    /// by saturation × brightness; among the top 10 % the ±30° hue family with the
    /// most total weight wins and is averaged (so two different lights — an orange
    /// beam in a teal cave — never blend into a muddy in-between colour). It is
    /// then lifted to a bright accent and softened 15 % toward white so it reads as warm light rather than neon.
    /// A scene with no saturated light falls back to a lightened ambient.
    static func extract(rgba: [UInt8]) -> BackdropPalette {
        let n = rgba.count / 4
        guard n > 0 else {
            let grey = RGB(r: 0.5, g: 0.5, b: 0.5)
            return BackdropPalette(ambient: grey, key: grey.scaled(toMax: 0.9))
        }
        var sum = (0.0, 0.0, 0.0)
        var scored: [(score: Double, rgb: RGB)] = []
        scored.reserveCapacity(n)
        for i in 0..<n {
            let c = RGB(r: Double(rgba[i * 4]) / 255,
                        g: Double(rgba[i * 4 + 1]) / 255,
                        b: Double(rgba[i * 4 + 2]) / 255)
            sum.0 += c.r; sum.1 += c.g; sum.2 += c.b
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            scored.append((sat * mx, c))
        }
        let ambient = RGB(r: sum.0 / Double(n), g: sum.1 / Double(n), b: sum.2 / Double(n))
        scored.sort { $0.score > $1.score }
        let top = scored.prefix(max(1, n / 10)).filter { $0.score > 0.05 }
        // Pick the hue family (±30°) carrying the most total score — the scene's
        // dominant light, not just its single most saturated pixel.
        // (Explicit types and plain loops: keeps the type checker fast and unambiguous.)
        var hued: [(score: Double, rgb: RGB, hue: Double)] = []
        for t in top {
            if let h = BackdropPalette.hue(t.rgb) { hued.append((score: t.score, rgb: t.rgb, hue: h)) }
        }
        func familyScore(_ h: Double) -> Double {
            var total = 0.0
            for t in hued where hueDistance(t.hue, h) <= 1.0 / 12 { total += t.score }
            return total
        }
        guard let lead = hued.max(by: { familyScore($0.hue) < familyScore($1.hue) }) else {
            return BackdropPalette(ambient: ambient, key: ambient.scaled(toMax: 0.9))
        }
        let family = hued.filter { hueDistance($0.hue, lead.hue) <= 1.0 / 12 }
        var k = (0.0, 0.0, 0.0)
        for t in family { k.0 += t.rgb.r; k.1 += t.rgb.g; k.2 += t.rgb.b }
        let c = Double(family.count)
        let bright = RGB(r: k.0 / c, g: k.1 / c, b: k.2 / c).scaled(toMax: 0.92)
        let soft = 0.15
        let key = RGB(r: bright.r + (0.92 - bright.r) * soft,
                      g: bright.g + (0.92 - bright.g) * soft,
                      b: bright.b + (0.92 - bright.b) * soft)
        return BackdropPalette(ambient: ambient, key: key)
    }
}

// MARK: - Instrument backdrops

/// Per-preset background scenes. Images live in Resources/Backgrounds (a folder
/// reference, bundled as "Backgrounds/") and are named after the preset:
/// "Suitcase '73" → suitcase_73.webp, "Str. Ensemble" → str_ensemble.webp.
/// A preset without a matching image simply shows the plain theme background.
enum Backdrop {
    /// File-name slug for a preset name (pure — unit-tested): lowercase ASCII
    /// letters/digits, every other run of characters collapsed to one "_".
    static func slug(for presetName: String) -> String {
        var out = ""
        var pendingSeparator = false
        for ch in presetName.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                if pendingSeparator && !out.isEmpty { out.append("_") }
                pendingSeparator = false
                out.append(ch)
            } else {
                pendingSeparator = true
            }
        }
        return out
    }

    static let imageExtensions: Set<String> = ["webp", "png", "jpg", "jpeg", "heic"]

    /// slug → image URL. One shallow directory listing (no whole-bundle walk), so
    /// it is cheap enough to build on the main thread on first use.
    static let library: [String: URL] = {
        let fm   = FileManager.default
        let root = Bundle.main.bundleURL
        for dir in [root.appendingPathComponent("Backgrounds"),
                    root.appendingPathComponent("Resources/Backgrounds")] {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            var map: [String: URL] = [:]
            for url in files where imageExtensions.contains(url.pathExtension.lowercased()) {
                map[url.deletingPathExtension().lastPathComponent.lowercased()] = url
            }
            return map
        }
        return [:]
    }()

    /// Presets without their own image borrow a related instrument's scene
    /// (preset slug → image slug). Anything not listed here and without its own
    /// file — the synth pads, the flute — gets a generated `AbstractScene`.
    static let borrowed: [String: String] = [
        "church_organ":     "pipe_organ",
        "vox_humana":       "pipe_organ",
        "choir_ahs":        "pipe_organ",
        "harmonium":        "musette_accordion",
        "mellotron":        "vintage_studio",
        "mellotron_flutes": "vintage_studio",
        "tape_strings":     "vintage_studio",
        "solina_strings":   "vintage_studio",
        "ondes_martenot":   "vintage_studio",
        "str_ensemble":     "grand_piano",
        "bowed_psaltery":   "hurdy_gurdy",
        "glass_harmonica":  "cristal_baschet",
    ]

    /// Image slug for a preset: its own name, else the scene it borrows.
    static func imageSlug(for presetName: String, available: Set<String>) -> String? {
        let own = slug(for: presetName)
        if available.contains(own) { return own }
        if let lent = borrowed[own], available.contains(lent) { return lent }
        return nil
    }

    static func url(for presetName: String) -> URL? {
        imageSlug(for: presetName, available: Set(library.keys)).flatMap { library[$0] }
    }
}

/// What is drawn behind the main screen.
enum BackdropSource: Equatable {
    case image(URL)
    /// Generated scene for presets with no image: `seed` (the preset slug) fixes
    /// the layout, `color` is the preset colour.
    case abstract(seed: String, color: BackdropPalette.RGB)
}

/// Layout of a generated scene (pure — unit-tested): a few soft glows in hues
/// around the preset colour, in the upper part of the frame like the painted
/// scenes, plus a sprinkle of stars. Deterministic per seed, so a preset always
/// gets the same scene (Swift's own `hashValue` changes every launch).
enum AbstractScene {
    struct Glow: Equatable {
        var x: Double, y: Double          // centre, 0...1 of the frame
        var radius: Double                // in frame widths
        var hueTurns: Double              // hue offset from the preset colour
        var opacity: Double
    }
    struct Star: Equatable { var x: Double, y: Double, size: Double, opacity: Double }

    /// 64-bit FNV-1a, then a SplitMix64 stream.
    struct Random {
        private var state: UInt64
        init(seed: String) {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in seed.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            state = h
        }
        /// Uniform in 0..<1.
        mutating func next() -> Double {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    static func layout(seed: String) -> (glows: [Glow], stars: [Star]) {
        var rng = Random(seed: seed)
        var glows: [Glow] = []
        for i in 0..<4 {
            glows.append(Glow(x: 0.15 + rng.next() * 0.7,
                              y: 0.05 + rng.next() * 0.45,
                              radius: 0.28 + rng.next() * 0.27,
                              hueTurns: i == 0 ? 0 : (rng.next() - 0.5) * 0.24,
                              opacity: 0.45 + rng.next() * 0.3))
        }
        var stars: [Star] = []
        for _ in 0..<36 {
            stars.append(Star(x: rng.next(), y: rng.next() * 0.7,
                              size: 1 + rng.next() * 1.6,
                              opacity: 0.25 + rng.next() * 0.55))
        }
        return (glows, stars)
    }
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
    /// Vertical pad axis: false = brightness + modulation (default), true = wave morph.
    var yAxisMorph: Bool {
        didSet { defaults.set(yAxisMorph, forKey: "yAxisMorph") }
    }
    /// Show the playing instrument's scene behind the UI (dark themes only).
    var backdropEnabled: Bool {
        didSet { defaults.set(backdropEnabled, forKey: "backdropEnabled") }
    }
    /// How dark the scene is drawn: 0.6 = clearly visible, 0.95 = a faint hint.
    /// iPad play-testing showed anything under ~80 % is too busy behind the grid.
    var backdropDim: Double {
        didSet { defaults.set(backdropDim, forKey: "backdropDimV2") }
    }
    static let backdropDimRange: ClosedRange<Double> = 0.6...0.95
    /// Name and colour ("#RRGGBB") of the preset on the play surface — set by
    /// ContentView. Not persisted.
    var activePresetName: String = ""
    var activePresetColor: String = "#8B5CF6"
    /// Colours sampled from each scene loaded so far (filled in by BackdropView),
    /// plus the most recent one. A scene seen before is tinted instantly; a new
    /// one borrows the previous scene's colours for the moment it takes to load —
    /// falling back to the theme's own neon for that moment showed as a flash.
    private var palettes: [URL: BackdropPalette] = [:]
    private var lastPalette: BackdropPalette? = nil

    func setPalette(_ palette: BackdropPalette, for url: URL) {
        palettes[url] = palette
        lastPalette   = palette
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
        yAxisMorph      = d.bool(forKey: "yAxisMorph")      // missing key → false
        backdropEnabled = d.object(forKey: "backdropEnabled") == nil ? true : d.bool(forKey: "backdropEnabled")
        // New key: the first build defaulted to 35 %, far too bright — start everyone at 80 %.
        backdropDim     = d.object(forKey: "backdropDimV2") == nil ? 0.8
                        : min(Self.backdropDimRange.upperBound,
                              max(Self.backdropDimRange.lowerBound, d.double(forKey: "backdropDimV2")))
    }

    /// The selected theme as designed (opaque surfaces). Use for screens that sit
    /// on their own background, e.g. the Settings sheet.
    var base: AppTheme {
        AppTheme.all.first { $0.id == storedId } ?? .cosmos
    }

    /// What to draw behind the main screen, or nil (backdrops off, a light theme,
    /// or no preset yet). A preset's own image, else a related one, else a
    /// generated scene in the preset's colour.
    var backdrop: BackdropSource? {
        guard backdropEnabled, base.colorScheme == .dark, !activePresetName.isEmpty else { return nil }
        if let url = Backdrop.url(for: activePresetName) { return .image(url) }
        return .abstract(seed: Backdrop.slug(for: activePresetName),
                         color: BackdropPalette.RGB(hex: activePresetColor))
    }

    private var activePalette: BackdropPalette? {
        guard let source = backdrop else { return nil }
        switch source {
        case .image(let url):         return palettes[url] ?? lastPalette
        case .abstract(_, let color): return BackdropPalette(presetColor: color)
        }
    }

    /// The theme the main screen draws with: glass surfaces, tinted to the scene,
    /// while a backdrop shows.
    var current: AppTheme {
        backdrop == nil ? base : base.glass(palette: activePalette)
    }

    /// Opaque colour behind everything on the main screen: a very dark version of
    /// the scene's ambient colour while a backdrop shows, else the theme's own.
    var screenBackground: Color {
        activePalette.map { $0.ambient.scaled(toMax: 0.07).color } ?? base.appBackground
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
