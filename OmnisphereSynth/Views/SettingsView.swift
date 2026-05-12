import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let theme = themeManager.current
        NavigationView {
            ZStack {
                theme.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {

                        // MARK: Theme picker
                        sectionHeader("THEME", theme: theme)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                            spacing: 14
                        ) {
                            ForEach(AppTheme.all) { t in
                                ThemeCard(theme: t, isSelected: t.id == themeManager.current.id)
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.3)) {
                                            themeManager.select(t)
                                        }
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    }
                            }
                        }

                        // MARK: Control style
                        sectionHeader("CONTROLS", theme: theme)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2),
                            spacing: 14
                        ) {
                            ForEach(ControlStyle.allCases) { style in
                                ControlStyleCard(
                                    style: style,
                                    isSelected: themeManager.controlStyle == style,
                                    theme: theme
                                )
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3)) {
                                        themeManager.selectControlStyle(style)
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                        }

                        // MARK: Play mode
                        sectionHeader("PLAY MODE", theme: theme)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2),
                            spacing: 14
                        ) {
                            ForEach(PlayMode.allCases) { mode in
                                PlayModeCard(
                                    mode: mode,
                                    isSelected: themeManager.playMode == mode,
                                    theme: theme
                                )
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3)) {
                                        themeManager.selectPlayMode(mode)
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                        }

                        // MARK: Scale
                        sectionHeader("SCALE", theme: theme)

                        // Root note picker
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Root Note")
                                .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                                .foregroundColor(theme.secondaryText)

                            let noteNames = ["C", "C#", "D", "D#", "E", "F",
                                             "F#", "G", "G#", "A", "A#", "B"]
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                                spacing: 8
                            ) {
                                ForEach(0..<12, id: \.self) { i in
                                    let isSelected = (themeManager.rootNote % 12) == i
                                    let accent: Color = theme.accentOverride ?? Color(hex: "#8B5CF6")
                                    Button {
                                        // Keep same octave, change pitch class
                                        let octave = themeManager.rootNote / 12
                                        themeManager.selectRootNote(octave * 12 + i)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(noteNames[i])
                                            .font(.system(size: 13, weight: .semibold,
                                                          design: theme.fontDesign))
                                            .foregroundColor(isSelected ? .white : theme.primaryText)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(isSelected ? accent : theme.panelBackground)
                                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius * 0.7))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: theme.cornerRadius * 0.7)
                                                    .strokeBorder(isSelected
                                                                  ? accent
                                                                  : theme.panelBorder, lineWidth: 1)
                                            )
                                    }
                                }
                            }

                            Text("Scale Type")
                                .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                                .foregroundColor(theme.secondaryText)
                                .padding(.top, 4)

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                                spacing: 8
                            ) {
                                ForEach(MusicalScale.allCases) { sc in
                                    let isSelected = themeManager.scale == sc
                                    let accent: Color = theme.accentOverride ?? Color(hex: "#8B5CF6")
                                    Button {
                                        themeManager.selectScale(sc)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(sc.label)
                                            .font(.system(size: 12, weight: isSelected ? .bold : .regular,
                                                          design: theme.fontDesign))
                                            .foregroundColor(isSelected ? .white : theme.primaryText)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(isSelected ? accent : theme.panelBackground)
                                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius * 0.7))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: theme.cornerRadius * 0.7)
                                                    .strokeBorder(isSelected
                                                                  ? accent
                                                                  : theme.panelBorder, lineWidth: 1)
                                            )
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .background(theme.panelBackground)
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(theme.panelBorder, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))

                        // MARK: About
                        sectionHeader("ABOUT", theme: theme)

                        VStack(alignment: .leading, spacing: 6) {
                            infoRow("App",     value: "SuperNovaPad 1.0",                theme: theme)
                            infoRow("Voices",  value: "Synth · Hammond · Rhodes · Organ", theme: theme)
                            infoRow("Effects", value: "Lo-Fi · S.Echo · B.Tape · Grit · Bloom · Phaser · A.Wah · Waver", theme: theme)
                        }
                        .padding(16)
                        .background(theme.panelBackground)
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                            .strokeBorder(theme.panelBorder, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(theme.accentOverride ?? .accentColor)
                        .font(.system(size: 15, weight: .semibold, design: theme.fontDesign))
                }
            }
            .preferredColorScheme(theme.colorScheme)
        }
    }

    private func sectionHeader(_ text: String, theme: AppTheme) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
            .foregroundColor(theme.secondaryText)
            .kerning(2.5)
    }

    private func infoRow(_ key: String, value: String, theme: AppTheme) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 13, weight: .medium, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .regular, design: theme.fontDesign))
                .foregroundColor(theme.primaryText)
        }
    }
}

// MARK: - Theme card

struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.appBackground)
                    .frame(height: 80)

                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.panelBackground)
                    .frame(width: 70, height: 32)
                    .overlay(
                        HStack(spacing: 6) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle()
                                    .fill(theme.accentOverride ?? Color(hex: "#8B5CF6"))
                                    .frame(width: 10, height: 10)
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.panelBorder, lineWidth: 1)
                    )

                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.accentOverride ?? .white, lineWidth: 2.5)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accentOverride ?? .white)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 5) {
                Image(systemName: theme.icon)
                    .font(.system(size: 10))
                Text(theme.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected
                ? (theme.accentOverride ?? .accentColor)
                : Color.primary.opacity(0.6))
        }
    }
}

// MARK: - Play mode card

struct PlayModeCard: View {
    let mode: PlayMode
    let isSelected: Bool
    let theme: AppTheme

    private var accent: Color { theme.accentOverride ?? Color(hex: "#8B5CF6") }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.panelBackground)
                    .frame(height: 72)

                Image(systemName: mode.icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(isSelected ? accent : theme.secondaryText)

                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accent, lineWidth: 2.5)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(accent)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.panelBorder, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(mode.label)
                .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
                .foregroundColor(isSelected ? accent : Color.primary.opacity(0.6))
        }
    }
}

// MARK: - Control style card

struct ControlStyleCard: View {
    let style: ControlStyle
    let isSelected: Bool
    let theme: AppTheme

    private var accent: Color { theme.accentOverride ?? Color(hex: "#8B5CF6") }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.panelBackground)
                    .frame(height: 72)

                Image(systemName: style.icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(isSelected ? accent : theme.secondaryText)

                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accent, lineWidth: 2.5)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(accent)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.panelBorder, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(style.label)
                .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
                .foregroundColor(isSelected ? accent : Color.primary.opacity(0.6))
        }
    }
}
