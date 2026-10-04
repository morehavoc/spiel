import Foundation
import SpielCore

/// 2.6 — the license gate (official build) and the release plumbing around it.
/// Network-free: Gumroad is a fixture, the clock is a parameter.
extension SelfTest {

    static func tests26() async {
        licenseStatusTests()
        gumroadParseTests()
        await activationTests()
        revalidationTests()
        licenseStoreTests()
        releaseSourceRules26()
    }

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static func days(_ d: Double) -> Date { t0.addingTimeInterval(d * 86_400) }

    // MARK: Trial clock

    static func licenseStatusTests() {
        print("\n2.6 — license status and the 14-day trial")
        expect(String(LicenseBuild.isOfficial), "false", "a source build (no -DOFFICIAL_BUILD) has no gate")
        let fresh = LicenseState(trialStart: t0)
        func st(_ s: LicenseState, _ now: Date) -> String { "\(LicensePolicy.status(s, now: now))" }
        expect(st(fresh, t0), "trial(daysLeft: 14)", "first launch: 14 days left")
        expect(st(fresh, days(13.5)), "trial(daysLeft: 1)", "half a day left reads as 1 day, never 0")
        expect(st(fresh, days(14)), "trialEnded", "day 14 to the second: trial over")
        expect(st(fresh, days(-30)), "trial(daysLeft: 14)", "clock set back before the trial began: a full trial, not more")
        var lic = fresh; lic.key = "ABCD-1234"
        expect(st(lic, days(400)), "licensed", "a key outlives the trial")
        var rev = lic; rev.revoked = true
        expect(st(rev, days(1)), "revoked", "revoked wins over a key, even inside the trial window")
        expect(["trial(daysLeft: 3)": LicensePolicy.Status.trial(daysLeft: 3), "licensed": .licensed, "trialEnded": .trialEnded, "revoked": .revoked]
                .sorted { $0.key < $1.key }.map { "\($0.key)=\(LicensePolicy.allowsUse($0.value))" }.joined(separator: " "),
               "licensed=true revoked=false trial(daysLeft: 3)=true trialEnded=false", "only a trial or a license may start dictation")
        expect([LicensePolicy.menuLine(.trial(daysLeft: 1)), LicensePolicy.menuLine(.trial(daysLeft: 9)),
                LicensePolicy.menuLine(.trialEnded), LicensePolicy.menuLine(.revoked), LicensePolicy.menuLine(.licensed)]
                .map { $0 ?? "nil" }.joined(separator: " | "),
               "Trial: 1 day left | Trial: 9 days left | Trial ended | License revoked | nil", "menu lines (none once licensed)")
        expect(lic.maskedKey, "****1234", "logs carry the last 4 characters only")
    }

    // MARK: Gumroad response

    static func gumroadParseTests() {
        print("\n2.6 — Gumroad /v2/licenses/verify responses (shapes from Gumroad's own controller)")
        let pid = "spielPID=="
        func p(_ status: Int?, _ json: String?) -> String {
            "\(GumroadVerdict.parse(httpStatus: status, body: json.map { Data($0.utf8) }, productID: pid))"
        }
        func ok(uses: Int, _ purchase: String) -> String { #"{"success":true,"uses":\#(uses),"purchase":{\#(purchase)}}"# }
        expect(p(200, ok(uses: 1, #""product_id":"spielPID==","refunded":false,"chargebacked":false"#)), "valid(uses: 1)", "valid key, 1 use")
        expect(p(200, ok(uses: 1, #""product_id":"spielPID==","refunded":true,"chargebacked":false"#)), "revoked(SpielCore.GumroadVerdict.RevokeReason.refunded)",
               "refunded: Gumroad still says success:true, with the flag")
        expect(p(200, ok(uses: 1, #""product_id":"spielPID==","refunded":false,"chargebacked":true"#)), "revoked(SpielCore.GumroadVerdict.RevokeReason.chargebacked)",
               "charged back")
        expect(p(200, ok(uses: 1, #""product_id":"otherPID==""#)), "rejected(SpielCore.GumroadVerdict.RejectReason.wrongProduct)", "another product's key")
        expect(p(404, #"{"success":false,"message":"This license key has been disabled."}"#), "revoked(SpielCore.GumroadVerdict.RevokeReason.disabled)", "disabled key (404)")
        expect(p(404, #"{"success":false,"message":"That license does not exist for the provided product."}"#),
               "rejected(SpielCore.GumroadVerdict.RejectReason.unknownKey)", "unknown key (404)")
        expect(p(500, #"{"success":false,"message":"The 'product_id' parameter is required"}"#).hasPrefix("unavailable") ? "unavailable" : "verdict",
               "unavailable", "a 5xx in the failure shape is server trouble, not a verdict")
        expect(p(502, "<html>Bad gateway</html>").hasPrefix("unavailable") ? "unavailable" : "verdict", "unavailable", "HTML error page")
        expect(p(nil, nil).hasPrefix("unavailable") ? "unavailable" : "verdict", "unavailable", "no response at all (offline)")
        expect(p(200, #"{"success":true,"purchase":{}}"#).hasPrefix("unavailable") ? "unavailable" : "verdict", "unavailable", "success without a uses count")
        expect(GumroadVerdict.formBody(productID: pid, key: "AB+C&D", incrementUses: false),
               "product_id=spielPID%3D%3D&license_key=AB%2BC%26D&increment_uses_count=false",
               "form body: encoded, and increment_uses_count always sent (Gumroad counts a use when it is omitted)")
        expect(GumroadVerdict.formBody(productID: "x", key: "k", incrementUses: true).hasSuffix("increment_uses_count=true") ? "ok" : "no", "ok",
               "activation sends increment_uses_count=true")
    }

    // MARK: Activation

    final class FakeGumroad: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [GumroadVerdict]
        private(set) var calls: [Bool] = []
        init(_ answers: [GumroadVerdict]) { self.answers = answers }
        func verify(_ key: String, _ increment: Bool) -> GumroadVerdict {
            lock.lock(); defer { lock.unlock() }
            calls.append(increment)
            return answers.isEmpty ? .unavailable("fixture exhausted") : answers.removeFirst()
        }
        var callLog: String { calls.map { $0 ? "count" : "check" }.joined(separator: ",") }
    }

    static func activationTests() async {
        print("\n2.6 — activation (check first, count a use only if a seat is free; max 2 Macs)")
        let base = LicenseState(trialStart: days(-20))
        func run(_ key: String, _ answers: [GumroadVerdict], state: LicenseState = base, pid: String? = "pid") async -> (String, String, LicenseState?) {
            let g = FakeGumroad(answers)
            let r = await LicensePolicy.activate(key: key, productID: pid, state: state, now: days(0)) { k, inc in g.verify(k, inc) }
            switch r {
            case .success(let s): return ("ok", g.callLog, s)
            case .failure(let e): return (e.message, g.callLog, nil)
            }
        }
        var r = await run("  KEY-1  ", [.valid(uses: 0), .valid(uses: 1)])
        expect("\(r.0) \(r.1) \(r.2?.key ?? "-") \(r.2.map { "\(LicensePolicy.status($0, now: days(1)))" } ?? "-")",
               "ok check,count KEY-1 licensed", "first Mac: check, then count; key trimmed and stored")
        r = await run("KEY-1", [.valid(uses: 1), .valid(uses: 2)])
        expect("\(r.0) \(r.1)", "ok check,count", "second Mac is allowed")
        r = await run("KEY-1", [.valid(uses: 2)])
        expect("\(r.0) | \(r.1)", "This key is already used on 2 Macs. | check", "third Mac refused WITHOUT counting a use")
        r = await run("KEY-1", [.valid(uses: 1), .valid(uses: 3)])
        expect(r.0, "This key is already used on 2 Macs.", "two Macs racing past the check: the count call still refuses at 3")
        r = await run("KEY-1", [.unavailable("offline")])
        expect("\(r.0) \(r.2 == nil)", "Could not reach Gumroad. Try again. true", "offline: plain message, nothing stored")
        r = await run("KEY-1", [.rejected(.wrongProduct)])
        expect(r.0, "That key is for a different product.", "wrong product")
        r = await run("KEY-1", [.rejected(.unknownKey)])
        expect(r.0, "That key is not valid for Spiel.", "unknown key")
        r = await run("KEY-1", [.revoked(.refunded)])
        expect(r.0, "This purchase was refunded.", "refunded key cannot activate")
        r = await run("   ", [])
        expect("\(r.0) [\(r.1)]", "Enter a license key. []", "empty key: no network call")
        r = await run("KEY-1", [], pid: nil)
        expect("\(r.0) [\(r.1)]", "This build has no Gumroad product ID. []", "no product ID in Info.plist: no network call")
        var held = base; held.key = "KEY-1"; held.activatedAt = days(-3)
        r = await run("KEY-1", [], state: held)
        expect("\(r.0) [\(r.1)]", "ok []", "re-entering the key this Mac holds spends no seat")
        held.revoked = true
        r = await run("KEY-1", [.valid(uses: 1), .valid(uses: 2)], state: held)
        expect("\(r.0) \(r.2?.revoked == false)", "ok true", "a revoked Mac can re-activate (it goes through Gumroad again)")
    }

    // MARK: Weekly re-check

    static func revalidationTests() {
        print("\n2.6 — background re-check (weekly; only 2 consecutive revocation answers revoke)")
        var s = LicenseState(trialStart: days(-30), key: "KEY-1", activatedAt: days(0), lastValidation: days(0))
        func due(_ now: Date) -> String { LicensePolicy.revalidationDue(s, now: now) ? "due" : "not due" }
        expect([due(days(6.9)), due(days(7))].joined(separator: ","), "not due,due", "at most weekly")
        s = LicensePolicy.applyRevalidation(s, .unavailable("offline"), now: days(7))
        expect([due(days(7.5)), due(days(8))].joined(separator: ","), "not due,due", "after an offline attempt: retry a day later, not every 6 h")
        expect("\(s.lastValidation == days(0)) \(s.revokeStrikes)", "true 0", "an offline attempt is not a validation")
        let trial = LicenseState(trialStart: t0)
        expect(LicensePolicy.revalidationDue(trial, now: days(100)) ? "due" : "never", "never", "no key: nothing to re-check")

        func fold(_ verdicts: [GumroadVerdict]) -> LicenseState {
            var st = LicenseState(trialStart: days(-30), key: "KEY-1", activatedAt: days(0))
            for (i, v) in verdicts.enumerated() { st = LicensePolicy.applyRevalidation(st, v, now: days(Double(7 * (i + 1)))) }
            return st
        }
        func show(_ st: LicenseState) -> String { "\(LicensePolicy.status(st, now: days(100))) strikes=\(st.revokeStrikes)" }
        expect(show(fold([.revoked(.refunded)])), "licensed strikes=1", "one refund answer does not revoke")
        expect(show(fold([.revoked(.refunded), .revoked(.refunded)])), "revoked strikes=2", "two in a row do")
        expect(fold([.revoked(.disabled), .revoked(.disabled)]).revokeReason ?? "-", "disabled", "the reason is kept")
        expect(show(fold([.revoked(.refunded), .valid(uses: 1), .revoked(.refunded)])), "licensed strikes=1", "a valid answer in between resets the count")
        expect(show(fold([.revoked(.chargebacked), .unavailable("offline"), .revoked(.chargebacked)])), "revoked strikes=2",
               "an offline attempt in between is not a check, so the two answers are still consecutive")
        expect(show(fold(Array(repeating: .unavailable("Gumroad down"), count: 20))), "licensed strikes=0", "offline / Gumroad down never revokes")
        expect(show(fold([.rejected(.unknownKey), .rejected(.unknownKey), .rejected(.other("x"))])), "licensed strikes=0",
               "an answer that is not refunded/chargebacked/disabled never revokes")
        let gone = fold([.revoked(.refunded), .revoked(.refunded)])
        expect(LicensePolicy.revalidationDue(gone, now: days(200)) ? "due" : "never", "never", "a revoked key is not re-checked")
    }

    // MARK: Storage

    static func licenseStoreTests() {
        print("\n2.6 — trial start stored twice (UserDefaults + Application Support); the earlier wins")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spiel-license-\(UUID().uuidString)")
        let suite = "spiel-selftest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { expect("no defaults", "defaults", "temp UserDefaults suite"); return }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("license.json")
        let store = LicenseStore(url: url, defaults: defaults)
        let first = store.load(now: t0)
        expect("\(first.trialStart == t0) \(FileManager.default.fileExists(atPath: url.path)) \((defaults.object(forKey: LicenseStore.defaultsKey) as? Date) == t0)",
               "true true true", "first launch records the start in both places")
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        expect(String(perms, radix: 8), "600", "license.json is 0600")
        expect(store.load(now: days(5)).trialStart == t0 ? "kept" : "moved", "kept", "a later launch keeps the original start")
        try? FileManager.default.removeItem(at: url)
        expect(store.load(now: days(6)).trialStart == t0 ? "kept" : "restarted", "kept", "file deleted: UserDefaults still holds the start (and rewrites the file)")
        defaults.removeObject(forKey: LicenseStore.defaultsKey)
        expect(store.load(now: days(7)).trialStart == t0 ? "kept" : "restarted", "kept", "UserDefaults cleared: the file still holds the start")
        defaults.set(days(-3), forKey: LicenseStore.defaultsKey)
        expect(store.load(now: days(8)).trialStart == days(-3) ? "earlier" : "later", "earlier", "the two disagree: the earlier wins")
        var s = store.load(now: days(8)); s.key = "KEY-9"; s.activatedAt = days(8)
        try? store.save(s)
        expect(store.load(now: days(9)).key ?? "-", "KEY-9", "the key round-trips")
        try? Data("{not json".utf8).write(to: url)
        let corrupt = store.load(now: days(10))
        expect("\(corrupt.trialStart == days(-3)) \(corrupt.key ?? "nil")", "true nil", "corrupt file: key lost (re-enter it), trial start kept")
    }

    // MARK: Source rules

    static func releaseSourceRules26() {
        print("\n2.6 — source rules (gate placement, release script)")
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var root: URL?
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Sources/SpielApp/main.swift").path) { root = dir; break }
            dir.deleteLastPathComponent()
        }
        func read(_ rel: String) -> String? { root.flatMap { try? String(contentsOf: $0.appendingPathComponent(rel), encoding: .utf8) } }
        guard let app = read("Sources/SpielApp/main.swift"), let release = read("scripts/release.sh"),
              let bundle = read("scripts/bundle.sh"), let manifest = read("Package.swift") else {
            print("  – SKIPPED: sources not found beside this binary (nothing asserted)")
            return
        }
        func firstStatement(_ fn: String) -> String {
            guard let r = app.range(of: "private func \(fn)() {\n") else { return "" }
            return app[r.upperBound...].split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        expect(firstStatement("start"), "guard licenseAllowsStart() else { return }", "dictation start: the license check comes first")
        expect(firstStatement("startListening"), "guard licenseAllowsStart() else { return }", "Listen start: the license check comes first")
        let stopAndResume = ["stop", "finish", "resumeListening", "stopListening", "pauseListening"].filter { fn in
            guard let r = app.range(of: "private func \(fn)(") else { return false }
            let rest = app[r.upperBound...]
            let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
            return rest[..<end].contains("licenseAllowsStart")
        }
        expect(stopAndResume.joined(separator: ","), "", "nothing that continues or ends a session checks the license (never interrupt)")
        expect(manifest.contains(#".package(url: "https://github.com/sparkle-project/Sparkle", exact: "#) ? "exact" : "loose", "exact", "Sparkle is pinned exactly")
        let pinned = manifest.range(of: #"Sparkle", exact: ""#).map { String(manifest[$0.upperBound...].prefix(while: { $0 != "\"" })) } ?? "?"
        expect(release.contains("SPARKLE_VERSION=\"\(pinned)\"") ? "same" : "differs", "same", "release.sh's Sparkle tools match the package pin (\(pinned))")
        expect(release.contains("SPIEL_GUMROAD_PRODUCT_ID") && release.contains("refuse") ? "ok" : "missing", "ok", "release.sh refuses without a Gumroad product ID")
        let signLines = release.split(separator: "\n").filter { $0.contains("codesign") && !$0.contains("--verify") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        expect(signLines.filter { $0.contains("--deep") }.count == 0 ? "inside-out" : "--deep", "inside-out", "release signing never uses --deep (only verification does)")
        expect(release.contains("--options runtime") && release.contains("--timestamp") ? "ok" : "missing", "ok", "hardened runtime + secure timestamp")
        expect(bundle.contains("<key>SUFeedURL</key>") && bundle.contains("<key>SUPublicEDKey</key>") && !bundle.contains("<key>SUEnableAutomaticChecks</key>") ? "ok" : "wrong", "ok",
               "Info.plist: feed + public key; no SUEnableAutomaticChecks, so Sparkle asks consent")
        expect(bundle.contains("@executable_path/../Frameworks") ? "ok" : "missing", "ok", "bundle.sh adds the Frameworks rpath for Sparkle")
    }
}
