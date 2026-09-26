import Foundation
import UIKit

struct LocusRelease: Equatable {
    let version: String
    let notes: String
    let ipaURL: URL
    let pageURL: URL?
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var latestRelease: LocusRelease?
    @Published private(set) var isChecking = false
    @Published var errorMessage: String?

    private let repo = "xuxingzhong/Locus"
    private let lastCheckKey = "locus.update.lastCheck"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var hasUpdate: Bool {
        guard let latestRelease else { return false }
        return latestRelease.version.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    func checkIfDue() async {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 6 * 60 * 60 else { return }
        await check()
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease else { return }
            guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }) else {
                throw UpdateError.missingIPA
            }
            let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard let ipaURL = URL(string: asset.browserDownloadURL) else { throw UpdateError.invalidURL }
            latestRelease = LocusRelease(
                version: version,
                notes: release.body ?? "",
                ipaURL: ipaURL,
                pageURL: URL(string: release.htmlURL)
            )
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sideStoreInstallURL(for release: LocusRelease) -> URL? {
        var components = URLComponents()
        components.scheme = "sidestore"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: release.ipaURL.absoluteString)]
        return components.url
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let body: String?
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case draft, prerelease, assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    private enum UpdateError: LocalizedError {
        case missingIPA, invalidURL
        var errorDescription: String? {
            switch self {
            case .missingIPA: return String(localized: "The latest release does not contain an IPA.")
            case .invalidURL: return String(localized: "The update download URL is invalid.")
            }
        }
    }
}
