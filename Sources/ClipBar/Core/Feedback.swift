import AppKit

enum Feedback {
    /// Keyed by name: copy and paste use different sounds, so a single-slot
    /// cache would reload one of them on every alternation.
    private static var cache: [String: NSSound] = [:]

    /// The bundled sounds only exist on builds that ship them; everyone else
    /// falls back to a system sound rather than to silence.
    static var defaultCaptureSound: String {
        bundledSounds().first { $0.hasSuffix("Copiar") } ?? "Tink"
    }

    static var defaultPasteSound: String {
        bundledSounds().first { $0.hasSuffix("Colar") } ?? "Pop"
    }

    static func captured() {
        guard Preferences.captureSoundEnabled else { return }
        play(Preferences.captureSoundName)
    }

    static func pasted() {
        guard Preferences.pasteSoundEnabled else { return }
        play(Preferences.pasteSoundName)
    }

    /// Deliberately skips the enabled check: the preferences window plays this
    /// to audition a sound, including while the toggle is off.
    static func preview(_ name: String) {
        play(name)
    }

    /// Bundled sounds first, then the system ones. Read from disk instead of
    /// hardcoded — the old fixed list of eight hid six of the system sounds,
    /// including whichever one the user actually wants.
    static func availableSounds() -> [String] {
        bundledSounds() + systemSounds()
    }

    private static func bundledSounds() -> [String] {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Sounds"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    private static func systemSounds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds"))?
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted()
        return names?.isEmpty == false ? names! : ["Tink"]
    }

    private static func play(_ name: String) {
        guard let sound = sound(named: name) ?? sound(named: "Tink") else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Bundle before system, so a bundled name always wins. Returns nil rather
    /// than substituting another sound: a wrong noise is worse than silence.
    private static func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }

        var loaded: NSSound?
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("Sounds")
            .appendingPathComponent(name + ".aiff"),
           FileManager.default.fileExists(atPath: url.path) {
            loaded = NSSound(contentsOf: url, byReference: true)
        }
        if loaded == nil { loaded = NSSound(named: name) }

        if let loaded { cache[name] = loaded }
        return loaded
    }
}
