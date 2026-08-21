import AppKit
import Foundation

/// Checks GitHub for a newer release, and only when the user asks.
///
/// The version check is the app's only unconditional network request. It fires
/// on a button press, never on a timer and never at launch, and it sends
/// nothing but the request itself — no identifier, no version, no usage.
///
/// Applying an update is a second, separate step the user also has to trigger
/// explicitly (`applyUpdate()` below). It does not download a prebuilt binary
/// from anywhere — that really would be the most dangerous code in an
/// unnotarised project, since there'd be nothing to verify what arrived. What
/// it does instead is `git pull` the clone the app was installed from, then
/// rebuild and reinstall on this machine under its own signing identity —
/// exactly the two commands the README already tells you to run by hand.
enum Updater {
    static let repository = "murilo-acronn/clipbar-app"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var releasesURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    enum Result {
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    static func check() async -> Result {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                return .failed("Nenhuma versão publicada ainda.")
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failed("O GitHub respondeu \(code).")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return .failed("Resposta do GitHub em formato inesperado.") }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL

            return isNewer(latest, than: currentVersion)
                ? .available(version: latest, url: page)
                : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// SemVer comparison, including prereleases: 0.2.0 is newer than
    /// 0.2.0-beta, while 1.2 and 1.2.0 remain equivalent.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(Version(candidate), Version(current)) > 0
    }

    private struct Version {
        var numbers: [Int]
        var prerelease: [String]?

        init(_ raw: String) {
            let withoutPrefix = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            let withoutBuild = withoutPrefix.split(separator: "+", maxSplits: 1).first.map(String.init) ?? withoutPrefix
            let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            numbers = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : nil
        }
    }

    private static func compare(_ left: Version, _ right: Version) -> Int {
        for position in 0..<max(left.numbers.count, right.numbers.count) {
            let a = position < left.numbers.count ? left.numbers[position] : 0
            let b = position < right.numbers.count ? right.numbers[position] : 0
            if a != b { return a > b ? 1 : -1 }
        }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil): return 0
        case (nil, _):   return 1
        case (_, nil):   return -1
        case let (a?, b?):
            for position in 0..<max(a.count, b.count) {
                guard position < a.count else { return -1 }
                guard position < b.count else { return 1 }

                let leftNumber = Int(a[position])
                let rightNumber = Int(b[position])
                switch (leftNumber, rightNumber) {
                case let (x?, y?) where x != y: return x > y ? 1 : -1
                case (_?, nil): return -1
                case (nil, _?): return 1
                default:
                    if a[position] != b[position] {
                        return a[position] > b[position] ? 1 : -1
                    }
                }
            }
            return 0
        }
    }

    // MARK: - Applying an update

    /// Where `install.sh` recorded the clone it ran from. Nil for installs that
    /// predate this — those fall back to opening the release page instead.
    static var sourcePath: URL? {
        let marker = Paths.support.appendingPathComponent("source-path.txt")
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True only when the recorded clone still looks like this project — it
    /// exists, it's a git checkout, and it has the install script. Anything
    /// less and we refuse rather than shell out blind at an arbitrary path.
    static func canApplyUpdate() -> Bool {
        guard let path = sourcePath else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: path.appendingPathComponent(".git").path)
            && fm.fileExists(atPath: path.appendingPathComponent("scripts/install.sh").path)
    }

    enum ApplyResult {
        case succeeded
        case failed(String)
    }

    /// Clones whose origin we're willing to pull and execute. The marker file is
    /// plain text any user-level process can rewrite; without this check, that's
    /// enough to make "Atualizar" run an attacker's install.sh as a child of an
    /// app holding the Accessibility grant. Requiring the remote to be ours means
    /// hijacking also requires push access to these repositories.
    private static let trustedRemotePrefixes = [
        "https://github.com/murilo-acronn/",
        "git@github.com:murilo-acronn/",
    ]

    /// `git pull` in the recorded clone, then re-run `install.sh`. `install.sh`
    /// ends by killing the running app and reopening the freshly built one, so
    /// on the happy path the caller does not survive to see this finish.
    ///
    /// Output goes to a temp file, not a Pipe: nothing reads a pipe until
    /// termination, so a chatty failing build would fill the 64KB buffer, block
    /// the child on write, and hang "Atualizando…" forever. A file has no such
    /// backpressure, and on failure we read its tail for the error message.
    ///
    /// Plain `bash -c`, not `-lc`: login shells source the user's profile, which
    /// is one more place code could be injected from, and everything install.sh
    /// needs lives in the default PATH anyway.
    static func applyUpdate() async -> ApplyResult {
        guard canApplyUpdate(), let path = sourcePath else {
            return .failed("Não achei o clone original — atualize com git pull manual.")
        }

        let allowed = trustedRemotePrefixes
            .map { "\"${REMOTE}\" == \(shellQuote($0))*" }
            .joined(separator: " || ")
        let script = """
            cd \(shellQuote(path.path)) || exit 66
            REMOTE=$(git remote get-url origin) || exit 66
            if ! [[ \(allowed) ]]; then
                echo "remoto não reconhecido: ${REMOTE}"
                exit 66
            fi
            git pull && JOBS=2 ./scripts/install.sh
            """

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipbar-update-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            return .failed("Não consegui criar o log da atualização.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardOutput = log
        process.standardError = log

        do {
            try process.run()
        } catch {
            return .failed("Não consegui iniciar a atualização: \(error.localizedDescription)")
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                try? log.close()
                defer { try? FileManager.default.removeItem(at: logURL) }

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: .succeeded)
                } else {
                    let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                    let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                    continuation.resume(returning: .failed(tail.isEmpty ? "git pull ou o build falharam." : tail))
                }
            }
        }
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
