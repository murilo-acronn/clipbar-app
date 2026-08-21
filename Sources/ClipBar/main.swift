import AppKit

if CommandLine.arguments.contains("--check") {
    Diagnostics.checkPermissions()
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    do { try Diagnostics.selfTest(); exit(0) }
    catch { FileHandle.standardError.write(Data("Autoteste falhou: \(error)\n".utf8)); exit(1) }
}

if let i = CommandLine.arguments.firstIndex(of: "--find"),
   i + 1 < CommandLine.arguments.count {
    do { try Diagnostics.find(CommandLine.arguments[i + 1]); exit(0) }
    catch { FileHandle.standardError.write(Data("Falha: \(error)\n".utf8)); exit(1) }
}

if CommandLine.arguments.contains("--verify") {
    do { try Verify.run(); exit(0) }
    catch { FileHandle.standardError.write(Data("Falha: \(error)\n".utf8)); exit(1) }
}

// `ClipBar --import-paste [--dry-run]` runs the migration and exits.
if CommandLine.arguments.contains("--import-paste") {
    do {
        try PasteImporter.run(dryRun: CommandLine.arguments.contains("--dry-run"))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Falha na importação: \(error)\n".utf8))
        exit(1)
    }
}

// No @main / NSApplicationMain here: we want .accessory set before the app
// finishes launching so no Dock icon ever flashes on screen.
// Anything left starting with "--" is a typo, not a request to launch: every
// real flag above exits. Falling through would open the GUI, which from a
// terminal looks exactly like a hang, because the app never returns.
if let unknown = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("--") }) {
    FileHandle.standardError.write(Data("""
        Opção desconhecida: \(unknown)

        Uso: ClipBar [opção]
          --check                      estado das permissões
          --verify                     integridade dos dados
          --self-test                  autoteste interno
          --find <termo>               depura a busca
          --import-paste [--dry-run]   migra as pastas do app Paste

        Sem opção, abre o app.

        """.utf8))
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
