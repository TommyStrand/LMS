import SwiftUI

@main
struct SuperNovaPadApp: App {
    // App-lifetime model objects live here, not in ContentView.
    //
    // With @Observable, `@State var x = Model()` evaluates `Model()` every time the
    // owning View struct is initialised (unlike the old @StateObject autoclosure,
    // which ran once). The App struct is instantiated exactly once per process, so
    // this is the one place an eager `AudioEngine()` (AVAudioSession activation +
    // AVAudioEngine graph) or `MIDIController()` (CoreMIDI client/port) can safely
    // be created inline. They reach the view tree through the environment.
    @State private var engine       = AudioEngine()
    @State private var themeManager = ThemeManager()
    @State private var midi         = MIDIController()
    @State private var drum         = DrumEngine()
    @State private var favorites    = FavoritesStore()
    @State private var recorder     = AudioRecorder()
    @State private var looper       = LooperEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .environment(themeManager)
                .environment(midi)
                .environment(drum)
                .environment(favorites)
                .environment(recorder)
                .environment(looper)
        }
    }
}
