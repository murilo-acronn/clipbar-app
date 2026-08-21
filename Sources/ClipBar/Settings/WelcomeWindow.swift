import AppKit
import SwiftUI

/// Shown once, on the first launch after install.
///
/// It exists for one concrete reason: without the Accessibility permission the
/// Return-to-paste does nothing, and someone who just downloaded the app has no
/// way to know that is a permission and not a bug. Everything else here is
/// secondary to getting that grant done while the user is still paying attention.
final class WelcomeController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let openPreferences: () -> Void

    init(openPreferences: @escaping () -> Void) {
        self.openPreferences = openPreferences
    }

    func showIfFirstLaunch() {
        guard !Preferences.hasSeenWelcome else { return }
        show()
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bem-vindo ao ClipBar"
        window.contentViewController = NSHostingController(
            rootView: WelcomeView(
                openPreferences: { [weak self] in
                    self?.finish()
                    self?.openPreferences()
                },
                close: { [weak self] in self?.finish() }
            )
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        Preferences.hasSeenWelcome = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing with the red button counts as seen; nobody wants this twice.
        Preferences.hasSeenWelcome = true
        window = nil
    }
}

struct WelcomeView: View {
    let openPreferences: () -> Void
    let close: () -> Void

    @State private var trusted = AXIsProcessTrusted()

    /// Polled rather than checked once: the user grants the permission in System
    /// Settings, in another window, and nothing notifies us when they do.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ClipBar").font(.system(size: 26, weight: .bold))
                Text("Seu histórico de área de transferência, guardado localmente e cifrado em repouso.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            step(number: 1, title: "Abra a barra com \(Preferences.hotKeyLabel)") {
                Text("Aparece na base da tela. Setas navegam, ⏎ cola, e é só digitar para buscar em tudo o que você guardou.")
            }

            step(number: 2, title: "Autorize a Acessibilidade") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sem ela o ⏎ coloca o item na área de transferência, mas não aperta ⌘V por você. É a única permissão que o ClipBar pede.")

                    HStack(spacing: 10) {
                        Label(
                            trusted ? "Autorizada" : "Ainda não autorizada",
                            systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .foregroundStyle(trusted ? .green : .orange)
                        .font(.system(size: 12, weight: .medium))

                        if !trusted {
                            Button("Autorizar…") {
                                Paster.requestAccessibility()
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                }
            }

            step(number: 3, title: "Organize em pastas") {
                Text("⌘N cria uma pasta, ⌘P move um item para ela e ⌘R dá um nome ao item — o nome que você usaria para procurá-lo depois. O botão direito abre as mesmas ações.")
            }

            Spacer(minLength: 0)

            HStack {
                Button("Abrir preferências") { openPreferences() }
                Spacer()
                Button("Começar") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 500)
        .onReceive(tick) { _ in
            let now = AXIsProcessTrusted()
            if now != trusted { trusted = now }
        }
    }

    @ViewBuilder
    private func step<Content: View>(number: Int,
                                     title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.22), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content()
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
