import Foundation

/// The update check.
///
/// A menu-bar app is the kind of thing you install once and then stop thinking about, which
/// makes it exactly the kind of thing that keeps a fixed bug for months. 1.1.6 fixed a keychain
/// prompt storm and 50% idle CPU; without this, every copy already installed keeps both faults
/// until its owner happens to type `brew upgrade` — and most of the people this is for have no
/// reason to know that command exists.
///
/// **What it sends is the whole of it: the product, this build's version, and the macOS
/// version.** No machine fingerprint, no account, no provider tokens, no quota figures. PWE Loan
/// Bar's equivalent does send a fingerprint because it counts seats against a licence; this app
/// has no licence and therefore nothing to count, so it asks for nothing it cannot use.
///
/// The check is off until the reader says yes, asked once, and changeable in Settings after
/// that. Failure is silent: someone on a plane or behind a corporate proxy must never see an
/// error from a convenience.
/// **This file is duplicated in four apps, deliberately, and the duplication is checked.**
/// PWE AI Bar, PWE Monitor, PWE Lumen Bar and PWE Screen Encore each carry a copy differing only in `product`, in
/// `downloadPage`, and in which function answers "is the interface in Chinese".
///
/// A shared package was designed and then measured against what it would buy. Three repositories
/// and three build systems -- SwiftPM, a raw `swiftc` line, and an Xcode project -- mean a package
/// costs a fourth repository, a build-system migration for one app, and "edit, tag, bump three
/// dependents" on every change: the same work moved somewhere else, plus a mechanism to learn.
/// What the duplication actually costs is one thing, and only one: nobody being told when a fix
/// reaches one copy and not the others.
///
/// `07 TOOLS/check-shared-sources.py` is that one thing. It compares the five functions carrying
/// the behaviour, ignores the configuration that is supposed to differ, and all three release
/// scripts run it. **Change all three -- and the release will tell you if you did not.**
@MainActor
final class UpdateCheck: ObservableObject {

    /// What the server answers with. Decoded leniently, because a field added next year must not
    /// break a copy shipped this year — and that old copy is precisely the one that needs to
    /// hear there is a new one.
    struct Release: Decodable, Equatable {
        let version: String
        var published: String?
        var notes_en: String?
        var notes_cn: String?
        var download: String?

        /// The reader's language first, the other one rather than nothing.
        var notes: String? {
            let (own, other) = L10n.isChinese ? (notes_cn, notes_en) : (notes_en, notes_cn)
            return own?.isEmpty == false ? own : other
        }
    }

    /// What one check found. "Answered" is not "up to date": the site answers a product it has
    /// not been told about with the caller's own version and nothing else (`site/functions/app/
    /// check.js`), and reading that echo as "you are current" claims a certainty nobody has.
    enum Outcome: Equatable {
        /// No answer: offline, a proxy, a timeout, something that was not a release.
        case unreachable
        /// An answer with no release information in it — the echo described above.
        case unknown
        /// This build is the newest the site knows of.
        case current
        /// A newer version exists, whether or not its reminder was dismissed.
        case newer(Release)
    }

    /// The reminder: a newer version the reader has not dismissed — or, after a check they asked
    /// for, a newer version at all. Dismissing quiets the reminder; it never changes what the
    /// newest version is.
    @Published private(set) var available: Release?

    /// Where someone goes to get it. A page rather than the file itself: the page states the
    /// checksum and what the download contains, and a download that starts with no explanation
    /// is the thing a careful person cancels.
    nonisolated static let downloadPage = URL(string: "https://github.com/kenshinice-ai/pwe-imac-display/releases/latest")!

    private let endpoint = URL(string: "https://pwestudio.site/app/check")!
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    private let lastCheckKey = "updateLastCheck"
    private let dismissedKey = "updateDismissedVersion"

    /// Once a day. The app runs for weeks at a time and a release happens a few times a month at
    /// the very most, so anything more frequent spends someone else's bandwidth to learn nothing.
    nonisolated static let interval: TimeInterval = 24 * 60 * 60

    /// Which product is asking. The endpoint serves every PWE app, so the answer depends on it.
    nonisolated static let product = "screenencore"

    nonisolated static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    nonisolated static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         }) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
    }

    // MARK: - Checking

    /// Runs at most once a day, does nothing without consent, and fails silently.
    func checkIfDue(enabled: Bool?, version: String = UpdateCheck.currentVersion) async {
        guard enabled == true else { return }
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           now().timeIntervalSince(last) < Self.interval { return }
        await check(version: version)
    }

    /// The check itself, with no "is it due" gate: someone who asks to check now means now.
    ///
    /// `manual` is a check the reader asked for. It shows a newer version even if they once said
    /// "Later" to it — they asked what the newest version is, and the answer does not depend on
    /// what they dismissed. The daily check is a reminder, and a reminder respects "Later".
    @discardableResult
    func check(version: String = UpdateCheck.currentVersion, manual: Bool = false) async -> Outcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.payload(version: version))

        guard let (data, response) = try? await fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return .unreachable }

        // Only a round trip that answered counts as "checked today". A failure should be retried
        // on the next launch rather than parked for twenty-four hours.
        defaults.set(now(), forKey: lastCheckKey)

        guard Self.isNewer(release.version, than: version) else {
            available = nil
            // Every release the site announces carries a date and a download; the echo for an
            // unknown product carries neither.
            return release.published == nil && release.download == nil ? .unknown : .current
        }
        available = manual || defaults.string(forKey: dismissedKey) != release.version ? release : nil
        return .newer(release)
    }

    /// Everything that leaves the machine, in one place so that reading this function is the
    /// whole audit. Kept as a function rather than inlined for exactly that reason — and there
    /// is a test that fails if a key is ever added to it.
    nonisolated static func payload(version: String) -> [String: String] {
        ["product": product, "version": version, "os": osVersion]
    }

    /// Hides the banner for this version only. A later release says so again.
    func dismiss() {
        if let version = available?.version { defaults.set(version, forKey: dismissedKey) }
        available = nil
    }

    /// Numeric, component by component, so 1.10 is correctly newer than 1.9 — which a string
    /// comparison gets backwards, and which this project will reach.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
