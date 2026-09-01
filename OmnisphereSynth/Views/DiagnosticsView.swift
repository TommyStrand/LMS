import SwiftUI
import Combine   // Timer.publish(...).autoconnect() returns Combine publisher types

/// On-device troubleshooting panel: live CPU / memory / voice-count meters and a
/// scrolling event log. Reached from Settings. Sampling runs only while visible.
///
/// `engine` is deliberately only touched in onReceive/onAppear, never in `body` — the
/// engine republishes its waveform buffer hundreds of times a second, and we do
/// not want that to thrash this view. Voice counts are polled on a slow timer
/// instead; meters and the log come from the `Diagnostics` singleton.
struct DiagnosticsView: View {
    let engine: AudioEngine
    private let diag = Diagnostics.shared
    @Environment(ThemeManager.self) var themeManager

    @State private var synthVoices   = 0
    @State private var samplerVoices = 0

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let theme = themeManager.current
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    // MARK: Meters
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                        spacing: 12
                    ) {
                        meter("CPU", value: String(format: "%.0f%%", diag.cpuPercent),
                              warn: diag.cpuPercent > 80, theme: theme)
                        meter("Memory", value: String(format: "%.0f MB", diag.memoryMB),
                              warn: diag.memoryMB > 300, theme: theme)
                        meter("Synth voices", value: "\(synthVoices)",
                              warn: synthVoices > 24, theme: theme)
                        meter("Sampler voices", value: "\(samplerVoices)",
                              warn: false, theme: theme)
                    }

                    // MARK: Event log
                    HStack {
                        Text("EVENT LOG")
                            .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                            .foregroundColor(theme.secondaryText)
                            .kerning(2.5)
                        Spacer()
                        Button("Clear") { diag.clear() }
                            .font(.system(size: 12, weight: .semibold, design: theme.fontDesign))
                            .foregroundColor(theme.accentOverride ?? .accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(diag.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(diag.timestamp(entry))
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                                Text(entry.message)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                        if diag.entries.isEmpty {
                            Text("No events yet.")
                                .font(.system(size: 11, design: theme.fontDesign))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.panelBackground)
                    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(theme.panelBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                .padding(20)
            }
            .onChange(of: diag.entries.count) {
                if let last = diag.entries.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .background(theme.appBackground.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(pollTimer) { _ in
            synthVoices   = engine.voices.count
            samplerVoices = engine.samplerActiveVoiceCount
        }
        .onAppear {
            diag.startSampling()   // idempotent; the header meter keeps it running
            synthVoices   = engine.voices.count
            samplerVoices = engine.samplerActiveVoiceCount
        }
    }

    private func meter(_ label: String, value: String, warn: Bool, theme: AppTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: theme.fontDesign))
                .foregroundColor(theme.secondaryText)
                .kerning(1.5)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundColor(warn ? .red : theme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(warn ? Color.red.opacity(0.6) : theme.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
    }
}
