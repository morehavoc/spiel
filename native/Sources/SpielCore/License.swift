import Foundation

/// 2.6 — the license gate for the OFFICIAL build (sold on Gumroad; the source stays
/// public). A plain source build has no gate: `LicenseBuild.isOfficial` is false
/// unless the build passed `-Xswiftc -DOFFICIAL_BUILD` (scripts/release.sh does).
///
/// Everything that decides anything lives here, network-free, so `spiel-cli
/// selftest` covers it: the trial clock, Gumroad's response, activation, and the
/// weekly re-check. The app and the `spiel` tool only load, ask and save.
public enum LicenseBuild {
    #if OFFICIAL_BUILD
    public static let isOfficial = true
    #else
    public static let isOfficial = false
    #endif

    /// Info.plist keys, written by scripts/bundle.sh from the environment.
    public static let productIDKey = "SpielGumroadProductID"
    public static let purchaseURLKey = "SpielPurchaseURL"
}

public enum LicensePolicy {
    public static let trialDays = 14
    public static let maxMacs = 2
    /// "Re-validate at most weekly."
    public static let revalidateEvery: TimeInterval = 7 * 86_400
    /// After a check that could not reach Gumroad, wait this long before trying
    /// again. Not a validation, so it does not count toward the week.
    public static let retryAfterUnavailable: TimeInterval = 86_400
    /// A revocation must be seen on this many consecutive checks.
    public static let strikesToRevoke = 2

    public enum Status: Equatable, Sendable {
        case trial(daysLeft: Int)
        case trialEnded
        case licensed
        case revoked
    }

    public static func status(_ s: LicenseState, now: Date) -> Status {
        if s.revoked { return .revoked }
        if s.key != nil { return .licensed }
        let end = s.trialStart.addingTimeInterval(Double(trialDays) * 86_400)
        if now >= end { return .trialEnded }
        // A clock set back before the trial began reads as a full trial, not more.
        let left = Int((end.timeIntervalSince(max(now, s.trialStart)) / 86_400).rounded(.up))
        return .trial(daysLeft: min(left, trialDays))
    }

    public static func allowsUse(_ status: Status) -> Bool {
        switch status {
        case .trial, .licensed: return true
        case .trialEnded, .revoked: return false
        }
    }

    /// One line for the menu; nil when there is nothing to say (licensed).
    public static func menuLine(_ status: Status) -> String? {
        switch status {
        case .trial(let d): return d == 1 ? "Trial: 1 day left" : "Trial: \(d) days left"
        case .trialEnded: return "Trial ended"
        case .revoked: return "License revoked"
        case .licensed: return nil
        }
    }

    public static func revalidationDue(_ s: LicenseState, now: Date) -> Bool {
        guard s.key != nil, !s.revoked else { return false }
        let last = s.lastValidation ?? s.activatedAt ?? .distantPast
        guard now.timeIntervalSince(last) >= revalidateEvery else { return false }
        if let a = s.lastAttempt, now.timeIntervalSince(a) < retryAfterUnavailable { return false }
        return true
    }

    /// Folds one background re-check into the state. Offline, Gumroad down, or any
    /// answer that is not a revocation never revokes; a refund, chargeback or
    /// disabled key revokes only on the second consecutive check that says so.
    public static func applyRevalidation(_ s: LicenseState, _ verdict: GumroadVerdict, now: Date) -> LicenseState {
        var n = s
        n.lastAttempt = now
        switch verdict {
        case .valid:
            n.lastValidation = now
            n.revokeStrikes = 0
        case .revoked(let reason):
            n.lastValidation = now
            n.revokeStrikes += 1
            if n.revokeStrikes >= strikesToRevoke {
                n.revoked = true
                n.revokeReason = reason.rawValue
            }
        case .rejected:
            // A key Gumroad no longer recognises is not one of the three revocation
            // answers. Counted as a check (so it is not retried daily), never a strike.
            n.lastValidation = now
        case .unavailable:
            break
        }
        return n
    }

    // MARK: Activation

    public enum ActivationError: Error, Equatable, Sendable {
        case empty
        case tooManyMacs
        case revoked(GumroadVerdict.RevokeReason)
        case rejected(GumroadVerdict.RejectReason)
        case unavailable
        case noProductID

        public var message: String {
            switch self {
            case .empty: return "Enter a license key."
            case .tooManyMacs: return "This key is already used on \(LicensePolicy.maxMacs) Macs."
            case .revoked(.refunded): return "This purchase was refunded."
            case .revoked(.chargebacked): return "This purchase was charged back."
            case .revoked(.disabled): return "This key has been disabled."
            case .rejected(.unknownKey): return "That key is not valid for Spiel."
            case .rejected(.wrongProduct): return "That key is for a different product."
            case .rejected(.other(let m)): return m
            case .unavailable: return "Could not reach Gumroad. Try again."
            case .noProductID: return "This build has no Gumroad product ID."
            }
        }
    }

    /// Two calls: a check that does NOT count a use, then — only if the key has a
    /// free seat — the one that does. Checking first means a key already on two
    /// Macs is refused without being pushed to three. Gumroad counts a use when
    /// `increment_uses_count` is omitted, so `verify` must always send it.
    public static func activate(
        key raw: String, productID: String?, state: LicenseState, now: Date,
        verify: @Sendable (_ key: String, _ incrementUses: Bool) async -> GumroadVerdict
    ) async -> Result<LicenseState, ActivationError> {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.empty) }
        guard let productID, !productID.isEmpty else { return .failure(.noProductID) }
        // Re-entering the key this Mac already holds must not spend a second seat.
        if state.key == key && !state.revoked { return .success(state) }

        func failure(_ v: GumroadVerdict) -> ActivationError {
            switch v {
            case .valid: return .tooManyMacs
            case .revoked(let r): return .revoked(r)
            case .rejected(let r): return .rejected(r)
            case .unavailable: return .unavailable
            }
        }
        let first = await verify(key, false)
        guard case .valid(let used) = first else { return .failure(failure(first)) }
        if used >= maxMacs { return .failure(.tooManyMacs) }
        let second = await verify(key, true)
        guard case .valid(let nowUsed) = second else { return .failure(failure(second)) }
        // Two Macs activating at once can both pass the first check.
        if nowUsed > maxMacs { return .failure(.tooManyMacs) }

        var n = state
        n.key = key
        n.activatedAt = now
        n.lastValidation = now
        n.lastAttempt = now
        n.revokeStrikes = 0
        n.revoked = false
        n.revokeReason = nil
        return .success(n)
    }
}

// MARK: - State

public struct LicenseState: Codable, Equatable, Sendable {
    public var trialStart: Date
    public var key: String?
    public var activatedAt: Date?
    /// Last time Gumroad gave a definitive answer.
    public var lastValidation: Date?
    /// Last time a check was tried, answered or not.
    public var lastAttempt: Date?
    public var revokeStrikes: Int
    public var revoked: Bool
    public var revokeReason: String?

    public init(trialStart: Date, key: String? = nil, activatedAt: Date? = nil, lastValidation: Date? = nil,
                lastAttempt: Date? = nil, revokeStrikes: Int = 0, revoked: Bool = false, revokeReason: String? = nil) {
        self.trialStart = trialStart
        self.key = key
        self.activatedAt = activatedAt
        self.lastValidation = lastValidation
        self.lastAttempt = lastAttempt
        self.revokeStrikes = revokeStrikes
        self.revoked = revoked
        self.revokeReason = revokeReason
    }

    /// For logs: never the whole key.
    public var maskedKey: String {
        guard let key else { return "none" }
        return key.count <= 4 ? "****" : "****" + key.suffix(4)
    }
}

/// The trial start lives in TWO places, UserDefaults and a file in Application
/// Support, and the earlier of the two wins, so deleting one does not restart the
/// trial. Not tamper-proof and not meant to be.
public struct LicenseStore {
    public static let defaultsKey = "SpielTrialStart"
    public static let appDefaultsSuite = "com.morehavoc.spiel"

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Spiel", isDirectory: true)
            .appendingPathComponent("license.json")
    }

    public let url: URL
    public let defaults: UserDefaults

    public init(url: URL = LicenseStore.defaultURL, defaults: UserDefaults = .standard) {
        self.url = url
        self.defaults = defaults
    }

    /// Never fails: an unreadable file loses the stored key (he re-enters it) but
    /// never the trial start while UserDefaults still has it. Records the trial
    /// start on first call.
    public func load(now: Date) -> LicenseState {
        let fromFile: LicenseState? = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(LicenseState.self, from: $0) }
        let fromDefaults = defaults.object(forKey: Self.defaultsKey) as? Date
        let starts = [fromFile?.trialStart, fromDefaults].compactMap { $0 }
        var state = fromFile ?? LicenseState(trialStart: now)
        state.trialStart = starts.min() ?? now
        if fromDefaults != state.trialStart { defaults.set(state.trialStart, forKey: Self.defaultsKey) }
        if fromFile?.trialStart != state.trialStart { try? save(state) }
        return state
    }

    public func save(_ s: LicenseState) throws {
        defaults.set(s.trialStart, forKey: Self.defaultsKey)
        try DictationHistory.atomicWrite(try Self.encoder.encode(s), to: url)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Gumroad

/// What one `POST /v2/licenses/verify` said. Shape read from Gumroad's own server
/// (antiwork/gumroad, Api::V2::LicensesController, 2026-10-03):
///   ok          200 {"success":true,"uses":N,"purchase":{…,"product_id":…,"refunded":bool,"chargebacked":bool}}
///   disabled    404 {"success":false,"message":"This license key has been disabled."}
///   no such key 404 {"success":false,"message":"That license does not exist for the provided product."}
/// A refunded or charged-back purchase still answers `success:true`, with the flag set.
public enum GumroadVerdict: Equatable, Sendable {
    public enum RevokeReason: String, Equatable, Sendable { case refunded, chargebacked, disabled }
    public enum RejectReason: Equatable, Sendable { case unknownKey, wrongProduct, other(String) }

    case valid(uses: Int)
    case revoked(RevokeReason)
    case rejected(RejectReason)
    /// No answer that says anything about the key: offline, timeout, 5xx, not JSON.
    case unavailable(String)

    public static func parse(httpStatus: Int?, body: Data?, productID: String) -> GumroadVerdict {
        guard let httpStatus, let body else { return .unavailable("no response") }
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .unavailable("HTTP \(httpStatus), body is not JSON")
        }
        guard let success = obj["success"] as? Bool else { return .unavailable("HTTP \(httpStatus), no success field") }
        if success {
            let purchase = obj["purchase"] as? [String: Any] ?? [:]
            if purchase["refunded"] as? Bool == true { return .revoked(.refunded) }
            if purchase["chargebacked"] as? Bool == true { return .revoked(.chargebacked) }
            if let p = purchase["product_id"] as? String, p != productID { return .rejected(.wrongProduct) }
            guard let uses = obj["uses"] as? Int else { return .unavailable("HTTP \(httpStatus), no uses count") }
            return .valid(uses: uses)
        }
        // Server trouble that happens to wear the failure shape is not a verdict.
        if httpStatus >= 500 { return .unavailable("HTTP \(httpStatus)") }
        let message = (obj["message"] as? String) ?? ""
        let lower = message.lowercased()
        if lower.contains("disabled") { return .revoked(.disabled) }
        if lower.contains("does not exist") { return .rejected(.unknownKey) }
        return .rejected(.other(message.isEmpty ? "Gumroad refused the key (HTTP \(httpStatus))." : message))
    }

    /// `increment_uses_count` is ALWAYS sent: Gumroad treats it as true unless it
    /// is the string "false".
    public static func formBody(productID: String, key: String, incrementUses: Bool) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "product_id=\(enc(productID))&license_key=\(enc(key))&increment_uses_count=\(incrementUses ? "true" : "false")"
    }
}

public enum GumroadClient {
    public static let verifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    public static func verify(productID: String, key: String, incrementUses: Bool) async -> GumroadVerdict {
        var req = URLRequest(url: verifyURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(GumroadVerdict.formBody(productID: productID, key: key, incrementUses: incrementUses).utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return GumroadVerdict.parse(httpStatus: (resp as? HTTPURLResponse)?.statusCode, body: data, productID: productID)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
