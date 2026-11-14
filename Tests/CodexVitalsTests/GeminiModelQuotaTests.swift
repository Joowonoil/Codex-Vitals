import Foundation
import XCTest
@testable import CodexVitals

final class GeminiModelQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProShowsArgonButDoesNotDuplicateHydrogenOrInventCarbon() throws {
        let account = try account(groups: [group("Argon", buckets: [bucket("argon", remaining: 0.42)])])
        XCTAssertEqual(account.supplementaryQuotas.map(\.label), ["Argon"])
        XCTAssertEqual(account.geminiQuotaDescription, "Models within this group: Gemini 4 Hydrogen, Gemini 3.8 Flash")
        XCTAssertEqual(account.supplementaryQuotaRowCount, 1)
        XCTAssertEqual(account.argonQuotaWindow?.remainingPercent, 42)
    }

    func testCarbonIndependentQuotaKeepsItsOwnWindow() throws {
        let account = try account(groups: [group("Carbon", buckets: [bucket("carbon", remaining: 0.35)])])
        let carbon = try XCTUnwrap(account.supplementaryQuotas.first)
        XCTAssertEqual(carbon.label, "Carbon")
        XCTAssertEqual(carbon.windows.first?.remainingPercent, 35)
        XCTAssertFalse(carbon.sharesMainQuota)
        XCTAssertEqual(account.weeklyFree, 80)
    }

    func testSharingRequiresExplicitModelMembershipAndNeverDuplicatesHydrogen() throws {
        let account = try account(members: "Gemini 4 Hydrogen, Gemini 3.8 Flash, Gemini 4 Argon, Gemini 4 Carbon")
        XCTAssertEqual(account.supplementaryQuotas.map(\.label), ["Argon", "Carbon"])
        XCTAssertTrue(account.supplementaryQuotas.allSatisfy(\.sharesMainQuota))
        XCTAssertTrue(account.supplementaryQuotas.allSatisfy { $0.windows.isEmpty })
        XCTAssertNil(account.argonQuotaWindow)
        XCTAssertEqual(account.supplementaryQuotaRowCount, 2)
        XCTAssertTrue(account.supplementaryQuotas.last?.tooltip.contains("not an additional allowance") == true)
    }

    func testSameMainBucketInCarbonGroupMeansSharingNotExtraAllowance() throws {
        let account = try account(groups: [group("Carbon", buckets: [
            ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.8],
        ])])
        XCTAssertEqual(account.supplementaryQuotas.first?.label, "Carbon")
        XCTAssertEqual(account.supplementaryQuotas.first?.sharesMainQuota, true)
        XCTAssertTrue(account.supplementaryQuotas.first?.windows.isEmpty == true)
    }

    func testUltraPlanAloneDoesNotInventAvailableModels() throws {
        let account = try account(plan: "Ultra")
        XCTAssertTrue(account.supplementaryQuotas.isEmpty)
    }

    func testMarketingTextDoesNotEstablishSharedModelAvailability() throws {
        let account = try account(members: nil, groups: [[
            "displayName": "Gemini 4 Argon",
            "description": "Carbon is available on Ultra. Hydrogen uses a different quota.",
            "buckets": [bucket("argon", remaining: 0.4)],
        ]])
        XCTAssertEqual(account.supplementaryQuotas.map(\.label), ["Argon"])
    }

    func testDisabledCarbonAndThirdPartyBucketsAreNotDisplayed() throws {
        var disabled = bucket("carbon", remaining: 1)
        disabled["disabled"] = true
        let account = try account(groups: [group("Carbon", buckets: [disabled, [
            "bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1,
        ]])])
        XCTAssertTrue(account.supplementaryQuotas.isEmpty)
    }

    func testMissingCarbonUsageStaysUnknownRatherThanFullOrShared() throws {
        let account = try account(groups: [group("Carbon", buckets: [bucket("carbon", remaining: nil)])])
        let carbon = try XCTUnwrap(account.supplementaryQuotas.first)
        XCTAssertTrue(carbon.windows.isEmpty)
        XCTAssertFalse(carbon.sharesMainQuota)
        XCTAssertEqual(carbon.rowCount, 1)
        XCTAssertTrue(carbon.tooltip.contains("unavailable"))
    }

    func testMultipleCarbonWindowsAreOrderedAndDeduplicated() throws {
        let account = try account(groups: [group("Carbon", buckets: [
            bucket("carbon", remaining: 0.35),
            bucket("carbon", remaining: 0.7, window: "5h"),
            bucket("carbon", remaining: 0.1),
        ])])
        let carbon = try XCTUnwrap(account.supplementaryQuotas.first)
        XCTAssertEqual(carbon.windows.map(\.label), ["5h", "1w"])
        XCTAssertEqual(carbon.windows.map(\.remainingPercent), [70, 35])
        XCTAssertEqual(account.supplementaryQuotaRowCount, 2)
    }

    func testSnapshotsPreserveAndAgeIndependentAndSharedModels() throws {
        let account = try account(members: "Gemini 4 Hydrogen, Gemini 4 Argon", groups: [
            group("Carbon", buckets: [bucket("carbon", remaining: 0.35)]),
        ])
        let aged = account.agingResetTimers(by: 600)
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(aged))
        XCTAssertEqual(decoded.geminiQuotaDetails, aged.geminiQuotaDetails)
        XCTAssertEqual(decoded.geminiQuotaDescription, account.geminiQuotaDescription)
        XCTAssertEqual(decoded.supplementaryQuotas.first?.sharesMainQuota, true)
        XCTAssertEqual(decoded.supplementaryQuotas.last?.windows.first?.resetAfterSeconds, 7_400)
    }

    func testLegacyArgonSnapshotStillDisplaysAndAgesArgon() throws {
        let account = try account(groups: [group("Argon", buckets: [bucket("argon", remaining: 0.4)])])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        json.removeValue(forKey: "geminiQuotaDetails")
        json.removeValue(forKey: "geminiQuotaDescription")
        let decoded = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.geminiQuotaDetails)
        XCTAssertEqual(decoded.supplementaryQuotas.first?.label, "Argon")
        XCTAssertEqual(decoded.agingResetTimers(by: 600).supplementaryQuotas.first?.windows.first?.resetAfterSeconds, 7_400)
    }

    func testIndependentCarbonResetNotifiesButSharedCarbonDoesNotDuplicate() throws {
        var previous = try account()
        previous.geminiQuotaDetails = [ModelQuotaDetail(id: "carbon", label: "Carbon", windows: [
            QuotaWindow(limitSeconds: QuotaWindow.weeklySeconds, remainingPercent: 0, resetAfterSeconds: 100),
        ])]
        var current = try account()
        current.quotaReferenceDate = now.addingTimeInterval(200)
        current.geminiQuotaDetails = [ModelQuotaDetail(id: "carbon", label: "Carbon", windows: [
            QuotaWindow(limitSeconds: QuotaWindow.weeklySeconds, remainingPercent: 60, resetAfterSeconds: 8_000),
        ])]
        let events = UsageResetDetector.detect(
            previousAccounts: [previous], previousFetchedAt: now,
            currentAccounts: [current], currentFetchedAt: now.addingTimeInterval(200)
        )
        XCTAssertEqual(events.map(\.windowLabel), ["Carbon"])
        current.geminiQuotaDetails = [ModelQuotaDetail(id: "carbon", label: "Carbon", sharesMainQuota: true)]
        XCTAssertTrue(UsageResetDetector.detect(
            previousAccounts: [previous], previousFetchedAt: now,
            currentAccounts: [current], currentFetchedAt: now.addingTimeInterval(200)
        ).isEmpty)
    }

    private func group(_ model: String, buckets: [[String: Any]]) -> [String: Any] {
        ["displayName": "Gemini 4 \(model)", "buckets": buckets]
    }

    private func bucket(_ model: String, remaining: Double?, window: String = "weekly") -> [String: Any] {
        var bucket: [String: Any] = [
            "bucketId": "gemini-\(model)-wtu-\(window)", "window": window,
            "resetTime": ISO8601DateFormatter().string(from: now.addingTimeInterval(8_000)),
        ]
        if let remaining { bucket["remainingFraction"] = remaining }
        return bucket
    }

    private func account(
        members: String? = "Gemini 4 Hydrogen, Gemini 3.8 Flash",
        groups: [[String: Any]] = [], plan: String = "Pro"
    ) throws -> Account {
        var main: [String: Any] = ["displayName": "Gemini Models", "buckets": [[
            "bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.8,
        ]]]
        if let members { main["description"] = "Models within this group: \(members)" }
        let object: [String: Any] = ["status": "SUCCESS", "command": [
            "name": "usage", "data": ["groups": [main] + groups],
        ]]
        var profile = GeminiProfile(email: "example@example.com")
        profile.plan = plan
        return try JSONDecoder().decode(GeminiUsageReport.self, from: JSONSerialization.data(withJSONObject: object))
            .account(now: now, profile: profile)
    }
}
