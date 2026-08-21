import Foundation

/// Checks GitHub for a newer release, and only when the user asks.
///
/// This is the app's single network request. It fires on a button press, never
/// on a timer and never at launch, and it sends nothing but the request itself —
/// no identifier, no version, no usage. Everything else in ClipBar stays offline,
/// which is a promise worth keeping literally rather than approximately.
///
/// It deliberately stops at *telling* you. Downloading and swapping a running
/// app in place is how an updater becomes the most dangerous code in the
/// project, and this one is neither notarised nor able to verify what it
/// downloaded — so it hands you the release page instead.
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
}
