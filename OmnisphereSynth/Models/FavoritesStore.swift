import Foundation
import Observation

@Observable
final class FavoritesStore {
    private let key = "drum.favorites.v1"

    private(set) var names: Set<String>

    init() {
        names = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func toggle(_ name: String) {
        if names.contains(name) { names.remove(name) } else { names.insert(name) }
        UserDefaults.standard.set(Array(names), forKey: key)
    }

    func contains(_ name: String) -> Bool { names.contains(name) }

    var patterns: [DrumPattern] {
        DrumPattern.all.filter { names.contains($0.name) }
    }
}
