import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What the preferences window needs the rest of the app to do when a setting
/// changes. Passed in as closures so this file never reaches for AppDelegate.
struct PreferencesActions {
    var reregisterHotKey: () -> Void = {}
    var applyBlockedApps: () -> Void = {}
    var pruneHistory: () -> Void = {}
    /// How many loose (unfiled) items exist right now — used to say what a
    /// destructive setting is about to destroy, before it does it.
    var looseItemCount: () -> Int = { 0 }
    var clearHistory: () -> Void = {}
}

final class PreferencesController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let actions: PreferencesActions

    init(actions: PreferencesActions) {
        self.actions = actions
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferências do ClipBar"
        window.contentViewController = NSHostingController(rootView: PreferencesView(actions: actions))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        // The app runs as .accessory, so it is not frontmost by default and the
        // window would open unable to take key events — which would break the
        // shortcut recorder in particular.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - View

struct PreferencesView: View {
    let actions: PreferencesActions

    private enum Pane: String, CaseIterable, Identifiable {
        case geral, privacidade, atalhos
        var id: String { rawValue }

        var title: String {
            switch self {
            case .geral:       return "Geral"
            case .privacidade: return "Privacidade"
            case .atalhos:     return "Atalhos"
            }
        }

        var icon: String {
            switch self {
            case .geral:       return "gearshape"
            case .privacidade: return "hand.raised"
            case .atalhos:     return "keyboard"
            }
        }
    }

    @State private var pane: Pane = .geral

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchError: String?
    @State private var soundEnabled = Preferences.captureSoundEnabled
    @State private var soundName = Preferences.captureSoundName
    @State private var pasteSoundEnabled = Preferences.pasteSoundEnabled
    @State private var pasteSoundName = Preferences.pasteSoundName
    @State private var autoPaste = Preferences.autoPasteEnabled
    @State private var historyLimit = Preferences.historyLimit
    @State private var retentionIndex = PreferencesView.index(forDays: Preferences.historyRetentionDays)
    @State private var retentionDraft = Double(PreferencesView.index(forDays: Preferences.historyRetentionDays))
    @State private var ignoreConcealed = Preferences.ignoreConcealedContent
    @State private var ignoreTransient = Preferences.ignoreTransientContent
    @State private var linkPreviews = Preferences.linkPreviewsEnabled
    @State private var hotKeyLabel = Preferences.hotKeyLabel
    @State private var blocked = Preferences.blockedBundleIDs
    @State private var blockedSelection: String?
    @State private var isRecording = false
    @State private var recorderError: String?
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var updateStatus: String?
    @State private var updateURL: URL?
    @State private var checkingUpdate = false

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { entry in
                Label(entry.title, systemImage: entry.icon).tag(entry)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(spacing: 0) {
                Form {
                    switch pane {
                    case .geral:       geralPane
                    case .privacidade: privacidadePane
                    case .atalhos:     atalhosPane
                    }
                }
                .formStyle(.grouped)

                Divider()
                updateBar
            }
        }
        .frame(width: 680, height: 600)
        .onAppear { normalizeRetentionPreference() }
        .onDisappear { applyHistoryLimit() }
    }

    // MARK: - Atualizações

    private var updateBar: some View {
        HStack(spacing: 10) {
            if let updateStatus {
                Text(updateStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let updateURL, Updater.canApplyUpdate() {
                Button(checkingUpdate ? "Atualizando…" : "Atualizar agora") {
                    confirmAndApplyUpdate(url: updateURL)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(checkingUpdate)
            } else if let updateURL {
                Button("Abrir") { NSWorkspace.shared.open(updateURL) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else {
                Button(checkingUpdate ? "Verificando…" : "Verificar atualizações") {
                    checkForUpdate()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(checkingUpdate)
            }

            Text("v\(Updater.currentVersion)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func checkForUpdate() {
        checkingUpdate = true
        updateStatus = nil
        updateURL = nil

        Task {
            let result = await Updater.check()
            await MainActor.run {
                checkingUpdate = false
                switch result {
                case .upToDate:
                    updateStatus = "Você está na versão mais recente."
                case let .available(version, url):
                    updateStatus = "Versão \(version) disponível."
                    updateURL = url
                case let .failed(reason):
                    updateStatus = reason
                }
            }
        }
    }

    /// Applying is a one-way trip: this app quits partway through, so the user
    /// gets one clear heads-up before it happens rather than a surprise.
    private func confirmAndApplyUpdate(url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Atualizar o ClipBar?"
        alert.informativeText = "Vai buscar o código novo, recompilar e reabrir sozinho — leva alguns segundos. Nada disso acontece sem essa confirmação."
        alert.addButton(withTitle: "Atualizar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        checkingUpdate = true
        Task {
            let result = await Updater.applyUpdate()
            // Reached only on failure — success replaces this very process.
            await MainActor.run {
                checkingUpdate = false
                if case let .failed(reason) = result {
                    updateStatus = reason
                }
            }
        }
    }

    // MARK: - Geral

    @ViewBuilder
    private var geralPane: some View {
        Section {
            Toggle("Abrir no login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, new in
                    do {
                        try LoginItem.set(new)
                        launchError = nil
                    } catch {
                        // Registration fails for a copy running outside /Applications.
                        // Saying so beats a switch that silently springs back.
                        launchAtLogin = !new
                        launchError = "Não foi possível: \(error.localizedDescription)"
                    }
                }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.red)
            }
        }

        Section("Sons") {
            Toggle("Ao copiar", isOn: $soundEnabled)
                .onChange(of: soundEnabled) { _, new in Preferences.captureSoundEnabled = new }
            soundPicker(selection: $soundName, enabled: soundEnabled) {
                Preferences.captureSoundName = $0
            }

            Toggle("Ao colar", isOn: $pasteSoundEnabled)
                .onChange(of: pasteSoundEnabled) { _, new in Preferences.pasteSoundEnabled = new }
            soundPicker(selection: $pasteSoundName, enabled: pasteSoundEnabled) {
                Preferences.pasteSoundName = $0
            }
        }

        Section("Colar itens") {
            Picker("", selection: $autoPaste) {
                Text("Para o aplicativo ativo").tag(true)
                Text("Para a área de transferência").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: autoPaste) { _, new in Preferences.autoPasteEnabled = new }

            Text(autoPaste
                 ? "O ⏎ cola direto no app em que você estava. Precisa da permissão de Acessibilidade."
                 : "O ⏎ só coloca o item na área de transferência; você cola com ⌘V quando quiser.")
                .font(.caption).foregroundStyle(.secondary)
        }

        historySection
    }

    private var historySection: some View {
        Section("Manter histórico") {
            retentionSlider

            LabeledContent("Guardar no máximo") {
                HStack(spacing: 8) {
                    // Applied on commit, never per keystroke: pruning deletes rows
                    // for good, and "500" passes through "5" on the way in.
                    TextField("", value: $historyLimit, format: .number)
                        .labelsHidden()
                        .frame(width: 70)
                        .onSubmit { applyHistoryLimit() }
                    Stepper("", value: Binding(
                        get: { historyLimit },
                        set: { historyLimit = $0; applyHistoryLimit() }
                    ), in: 50...5000, step: 50)
                        .labelsHidden()
                    Text("itens").foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top) {
                Text("As duas regras valem só para o histórico solto. O que está numa pasta nunca é apagado.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apagar histórico…") { clearHistory() }
            }
        }
        .onDisappear { applyHistoryLimit() }
    }

    // MARK: - Privacidade

    @ViewBuilder
    private var privacidadePane: some View {
        Section("Acessibilidade") {
            LabeledContent("Colar automático") {
                HStack(spacing: 8) {
                    Text(accessibilityTrusted ? "autorizado" : "não autorizado")
                        .foregroundStyle(accessibilityTrusted ? Color.green : Color.red)
                    if !accessibilityTrusted {
                        Button("Abrir Ajustes") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Verificar") { accessibilityTrusted = AXIsProcessTrusted() }
                        .buttonStyle(.borderless)
                }
            }

            // This reading is the trustworthy one: it comes from the running GUI
            // app, not from `--check` run as a child of a terminal, where TCC
            // answers for the terminal instead and reports a false negative.
            Text("É a única permissão que o ClipBar pede, e serve só para apertar ⌘V por você.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Não capturar") {
            Toggle("Conteúdo confidencial", isOn: $ignoreConcealed)
                .onChange(of: ignoreConcealed) { _, new in Preferences.ignoreConcealedContent = new }
            Text("Gerenciadores de senha marcam o que copiam como sigiloso. Desligar isto faz suas senhas entrarem no histórico.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Conteúdo transitório", isOn: $ignoreTransient)
                .onChange(of: ignoreTransient) { _, new in Preferences.ignoreTransientContent = new }
            Text("Dados temporários que outros apps deixam na área de transferência para uso próprio.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Links") {
            Toggle("Buscar título e imagem dos links", isOn: $linkPreviews)
                .onChange(of: linkPreviews) { _, new in Preferences.linkPreviewsEnabled = new }
            Text("Desligado por padrão. Quando ligado, copiar um link consulta aquele site para montar a prévia; o endereço pode aparecer nos logs do servidor visitado.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Ignorar aplicativos") {
            if blocked.isEmpty {
                Text("Nenhum. Nada é descartado por causa do app de origem.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                List(selection: $blockedSelection) {
                    ForEach(blocked, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            Image(nsImage: icon(for: bundleID))
                                .resizable().frame(width: 16, height: 16)
                            Text(name(for: bundleID))
                            Spacer()
                            Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(bundleID)
                    }
                }
                .frame(height: 120)
            }

            HStack(spacing: 8) {
                Button("Adicionar…") { addApp() }
                Button("Remover") { removeSelected() }
                    .disabled(blockedSelection == nil)
                Spacer()
            }

            Text("Nada copiado nesses apps entra no histórico, marcado como sigiloso ou não.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Atalhos

    @ViewBuilder
    private var atalhosPane: some View {
        Section("Global") {
            LabeledContent("Abrir a barra") {
                HStack(spacing: 8) {
                    Button(isRecording ? "Digite o atalho…" : hotKeyLabel) {
                        isRecording.toggle()
                        recorderError = nil
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 120)

                    Button("Padrão") {
                        Preferences.resetHotKeyToDefault()
                        hotKeyLabel = Preferences.hotKeyLabel
                        isRecording = false
                        recorderError = nil
                        actions.reregisterHotKey()
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let recorderError {
                Text(recorderError).font(.caption).foregroundStyle(.red)
            } else if isRecording {
                Text("Aperte a combinação. Precisa incluir ⌘, ⌥ ou ⌃. Esc cancela.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Este é o único atalho que vale fora do app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .background(ShortcutRecorder(isRecording: $isRecording, onCapture: record))

        Section("Dentro da barra") {
            ForEach(PreferencesView.barShortcuts, id: \.0) { entry in
                LabeledContent(entry.1) {
                    Text(entry.0)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Fixos por enquanto. O botão direito num card abre as mesmas ações.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static let barShortcuts: [(String, String)] = [
        ("← →", "Navegar entre os cards"),
        ("⇥ · ↑ ↓", "Trocar de pasta"),
        ("⏎", "Colar no app anterior"),
        ("⌘1–⌘9", "Colar direto o card N"),
        ("⌘C", "Copiar sem colar"),
        ("⌃C", "Mover para os recentes"),
        ("⌘R", "Dar um nome ao card"),
        ("⌘P", "Mover para outra pasta"),
        ("⌘N", "Criar pasta"),
        ("⌫", "Apagar o item"),
        ("esc", "Fechar"),
    ]

    // MARK: - Retenção

    /// What the slider is showing right now, which during a drag is ahead of the
    /// committed value — the readout has to follow the thumb, not the setting.
    private var liveRetentionIndex: Int {
        min(max(Int(retentionDraft.rounded()), 0), PreferencesView.retentionStops.count - 1)
    }

    private var retentionSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Apagar itens soltos após")
                Spacer()
                Text(PreferencesView.retentionStops[liveRetentionIndex].label)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }

            // Confirmation happens on release, not on every step: dragging from
            // "para sempre" to "1 dia" crosses two dozen stops, and asking at each
            // one would bury the user in alerts.
            Slider(
                value: $retentionDraft,
                in: 0...Double(PreferencesView.retentionStops.count - 1),
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    applyRetention(index: Int(retentionDraft.rounded()))
                }
            )

            // Placed by fraction of the usable track rather than spread by layout:
            // a Slider puts stop N at N/(count-1) of the track, inset by half the
            // knob at each end, and an HStack of labels lines up with none of it.
            GeometryReader { geometry in
                let knob: CGFloat = 11
                let usable = max(geometry.size.width - knob * 2, 1)
                ForEach(PreferencesView.retentionMarks, id: \.index) { mark in
                    let fraction = Double(mark.index) / Double(PreferencesView.retentionStops.count - 1)
                    Text(mark.label)
                        .font(.caption2)
                        .foregroundStyle(liveRetentionIndex >= mark.index ? Color.primary : Color.secondary)
                        .fixedSize()
                        .position(x: knob + usable * fraction, y: 7)
                }
            }
            .frame(height: 16)
        }
    }

    /// Fine steps inside each unit, the way Paste does it: days 1–6, weeks 1–4,
    /// months 1–12, years 1–4, then never.
    private static let retentionStops: [(label: String, days: Int)] = {
        var stops: [(String, Int)] = []
        for day in 1...6 { stops.append((day == 1 ? "1 dia" : "\(day) dias", day)) }
        for week in 1...4 { stops.append((week == 1 ? "1 semana" : "\(week) semanas", week * 7)) }
        for month in 1...12 { stops.append((month == 1 ? "1 mês" : "\(month) meses", month * 30)) }
        for year in 1...4 { stops.append((year == 1 ? "1 ano" : "\(year) anos", year * 365)) }
        stops.append(("Para sempre", 0))
        return stops
    }()

    /// Where each unit starts, for the ruler under the track.
    private static let retentionMarks: [(index: Int, label: String)] = [
        (0, "Dia"), (6, "Semana"), (10, "Mês"), (22, "Ano"),
        (retentionStops.count - 1, "Sempre"),
    ]

    private static func index(forDays days: Int) -> Int {
        guard days > 0 else { return retentionStops.count - 1 }
        return retentionStops.dropLast().firstIndex { $0.days >= days }
            ?? retentionStops.count - 1
    }

    /// Old builds offered values such as 10 days. Round those upward so opening
    /// preferences never makes retention stricter than the UI says it is, then
    /// persist the displayed stop so the hourly prune uses the same value.
    private func normalizeRetentionPreference() {
        let index = PreferencesView.index(forDays: Preferences.historyRetentionDays)
        let days = PreferencesView.retentionStops[index].days
        retentionIndex = index
        retentionDraft = Double(index)
        if Preferences.historyRetentionDays != days {
            Preferences.historyRetentionDays = days
        }
    }

    private func applyRetention(index: Int) {
        let clamped = min(max(index, 0), PreferencesView.retentionStops.count - 1)
        guard clamped != retentionIndex else {
            retentionDraft = Double(retentionIndex)
            return
        }

        let days = PreferencesView.retentionStops[clamped].days
        guard confirmRetention(days: days) else {
            retentionDraft = Double(retentionIndex)  // snap back to what still applies
            return
        }

        retentionIndex = clamped
        Preferences.historyRetentionDays = days
        actions.pruneHistory()
    }

    /// Shortening the window deletes rows immediately and there is no undo.
    private func confirmRetention(days: Int) -> Bool {
        guard days > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apagar itens soltos com mais de \(PreferencesView.describe(days: days))?"
        alert.informativeText = "Vale já, para os itens que hoje passam desse prazo, e não há como desfazer.\n\nNada que esteja dentro de uma pasta é afetado."
        alert.addButton(withTitle: "Apagar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func describe(days: Int) -> String {
        retentionStops.first { $0.days == days }?.label.lowercased() ?? "\(days) dias"
    }

    private func applyHistoryLimit() {
        let clamped = min(max(historyLimit, 50), 5000)
        if clamped != historyLimit { historyLimit = clamped }
        guard clamped != Preferences.historyLimit else { return }

        let loose = actions.looseItemCount()
        if loose > clamped {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Apagar \(loose - clamped) itens do histórico?"
            alert.informativeText = "Você tem \(loose) itens soltos e está baixando o limite para \(clamped). Os mais antigos serão apagados e não há como desfazer.\n\nNada que esteja dentro de uma pasta é afetado."
            alert.addButton(withTitle: "Apagar")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else {
                historyLimit = Preferences.historyLimit
                return
            }
        }

        Preferences.historyLimit = clamped
        actions.pruneHistory()
    }

    private func clearHistory() {
        let loose = actions.looseItemCount()
        guard loose > 0 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apagar os \(loose) itens soltos?"
        alert.informativeText = "Não há como desfazer.\n\nSuas pastas e tudo que está dentro delas continuam intactos."
        alert.addButton(withTitle: "Apagar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actions.clearHistory()
    }

    // MARK: - Sons

    private func soundPicker(selection: Binding<String>,
                             enabled: Bool,
                             store: @escaping (String) -> Void) -> some View {
        LabeledContent("Som") {
            HStack(spacing: 8) {
                Picker("", selection: selection) {
                    ForEach(Feedback.availableSounds(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                .onChange(of: selection.wrappedValue) { _, new in
                    store(new)
                    Feedback.preview(new)
                }

                Button("Testar") { Feedback.preview(selection.wrappedValue) }
                    .buttonStyle(.borderless)
            }
        }
        .disabled(!enabled)
    }

    // MARK: - Atalho global

    private func record(keyCode: UInt32, modifiers: UInt32, label: String) {
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            recorderError = "Um atalho global sem ⌘, ⌥ ou ⌃ engoliria a tecla no sistema inteiro."
            isRecording = false
            return
        }

        if let owner = PreferencesView.reserved[label] {
            // Carbon happily lets two apps register the same combination, so a
            // successful registration is no proof the shortcut was free. Refuse
            // the known ones instead of quietly shadowing them.
            recorderError = "\(label) pertence a \(owner). Escolha outra combinação."
            isRecording = false
            return
        }

        let previous = (Preferences.hotKeyCode, Preferences.hotKeyModifiers, Preferences.hotKeyLabel)

        Preferences.hotKeyCode = keyCode
        Preferences.hotKeyModifiers = modifiers
        Preferences.hotKeyLabel = label
        hotKeyLabel = label
        isRecording = false
        recorderError = nil
        actions.reregisterHotKey()

        // Registration fails when another app already owns the combination. Put
        // back exactly what was working before — not the factory default, which
        // would silently discard a shortcut chosen earlier.
        if !HotKey.lastRegistrationSucceeded {
            Preferences.hotKeyCode = previous.0
            Preferences.hotKeyModifiers = previous.1
            Preferences.hotKeyLabel = previous.2
            hotKeyLabel = previous.2
            actions.reregisterHotKey()
            recorderError = "Outro app já usa \(label). Continua valendo \(previous.2)."
        }
    }

    /// Combinations the system owns. Taking one of these breaks something the
    /// user relies on somewhere else, silently.
    private static let reserved: [String: String] = [
        "⌘⇧3": "captura de tela do macOS",
        "⌘⇧4": "captura de tela do macOS",
        "⌘⇧5": "captura de tela do macOS",
        "⌘⇧6": "captura de tela do macOS",
        "⌃⌘⇧3": "captura de tela do macOS",
        "⌃⌘⇧4": "captura de tela do macOS",
        "⌘Espaço": "Spotlight",
        "⌃Espaço": "troca de teclado do macOS",
        "⌘⇥": "troca de aplicativo",
        "⌘Q": "encerrar aplicativo",
        "⌘W": "fechar janela",
        "⌘A": "selecionar tudo",
        "⌘C": "copiar",
        "⌘S": "salvar",
        "⌘V": "colar",
        "⌘X": "recortar",
        "⌘Z": "desfazer",
    ]

    // MARK: - Apps ignorados

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignorar"

        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !ids.isEmpty else { return }

        blocked = Array(Set(blocked).union(ids)).sorted { name(for: $0) < name(for: $1) }
        Preferences.blockedBundleIDs = blocked
        actions.applyBlockedApps()
    }

    private func removeSelected() {
        guard let blockedSelection else { return }
        blocked.removeAll { $0 == blockedSelection }
        self.blockedSelection = nil
        Preferences.blockedBundleIDs = blocked
        actions.applyBlockedApps()
    }

    private func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func name(for bundleID: String) -> String {
        guard let url = url(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func icon(for bundleID: String) -> NSImage {
        guard let url = url(for: bundleID) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Gravador de atalho

/// Captures one key combination. It is an NSView rather than a SwiftUI gesture
/// because we need the raw key code for Carbon, and because the keystroke has to
/// be swallowed — otherwise recording ⌘W would also close the window.
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (UInt32, UInt32, String) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.setRecording(isRecording) { isRecording = false }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let view = NSView(frame: .zero)
        var onCapture: ((UInt32, UInt32, String) -> Void)?
        private var monitor: Any?

        func setRecording(_ recording: Bool, cancel: @escaping () -> Void) {
            if recording, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }

                    if event.keyCode == 53 {  // Escape
                        self.stop()
                        cancel()
                        return nil
                    }

                    let modifiers = Coordinator.carbonModifiers(event.modifierFlags)
                    let label = Coordinator.label(for: event)
                    self.stop()
                    self.onCapture?(UInt32(event.keyCode), modifiers, label)
                    return nil  // swallow it, or the window acts on the shortcut too
                }
            } else if !recording {
                stop()
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }

        static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
            var result: UInt32 = 0
            if flags.contains(.control) { result |= UInt32(controlKey) }
            if flags.contains(.option)  { result |= UInt32(optionKey) }
            if flags.contains(.shift)   { result |= UInt32(shiftKey) }
            if flags.contains(.command) { result |= UInt32(cmdKey) }
            return result
        }

        /// Keep the same order used by the default label and reserved-shortcut
        /// table, whatever order the physical keys were pressed in.
        static func label(for event: NSEvent) -> String {
            var result = ""
            if event.modifierFlags.contains(.control) { result += "⌃" }
            if event.modifierFlags.contains(.command) { result += "⌘" }
            if event.modifierFlags.contains(.option)  { result += "⌥" }
            if event.modifierFlags.contains(.shift)   { result += "⇧" }
            return result + keyName(for: event)
        }

        private static func keyName(for event: NSEvent) -> String {
            switch Int(event.keyCode) {
            case kVK_Space:      return "Espaço"
            case kVK_Return:     return "⏎"
            case kVK_Tab:        return "⇥"
            case kVK_Delete:     return "⌫"
            case kVK_LeftArrow:  return "←"
            case kVK_RightArrow: return "→"
            case kVK_UpArrow:    return "↑"
            case kVK_DownArrow:  return "↓"
            default:
                let characters = event.charactersIgnoringModifiers ?? ""
                return characters.isEmpty ? "tecla \(event.keyCode)" : characters.uppercased()
            }
        }
    }
}
