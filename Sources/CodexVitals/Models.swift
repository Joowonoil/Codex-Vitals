import AppKit
import SwiftUI

enum AccountProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

// MARK: - Quota Window

struct QuotaWindow: Equatable, Codable, Sendable {
    enum Kind: Equatable {
        case fiveHour
        case weekly
        case custom
    }

    static let fiveHourSeconds: Double = 5 * 60 * 60
    static let weeklySeconds: Double = 7 * 24 * 60 * 60

    let limitSeconds: Double
    let remainingPercent: Double
    let resetAfterSeconds: Double

    init(limitSeconds: Double, remainingPercent: Double, resetAfterSeconds: Double) {
        self.limitSeconds = limitSeconds
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetAfterSeconds = max(0, resetAfterSeconds)
    }

    var kind: Kind {
        switch Int(limitSeconds.rounded()) {
        case Int(Self.fiveHourSeconds): return .fiveHour
        case Int(Self.weeklySeconds): return .weekly
        default: return .custom
        }
    }

    var label: String {
        switch kind {
        case .fiveHour:
            return "5h"
        case .weekly:
            return "1w"
        case .custom:
            return Self.durationLabel(seconds: limitSeconds)
        }
    }

    var isExhausted: Bool {
        remainingPercent <= 0.001
    }

    private static func durationLabel(seconds rawSeconds: Double) -> String {
        let seconds = max(1, Int(rawSeconds.rounded()))
        if seconds.isMultiple(of: Int(weeklySeconds)) {
            return "\(seconds / Int(weeklySeconds))w"
        }
        if seconds.isMultiple(of: 24 * 60 * 60) {
            return "\(seconds / (24 * 60 * 60))d"
        }
        if seconds.isMultiple(of: 60 * 60) {
            return "\(seconds / (60 * 60))h"
        }
        if seconds.isMultiple(of: 60) {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }
}

// MARK: - Account

struct Account: Identifiable, Equatable, Codable, Sendable {
    let id: String          // dedup key: "email|accountId"
    let profileKey: String?
    let email: String
    var alias: String? = nil
    let workspace: String   // team name or plan type
    var workspaceAlias: String? = nil
    let plan: String
    let sessionFree: Double // 0-100 (% remaining)
    let weeklyFree: Double
    let sessionResetSeconds: Double
    let weeklyResetSeconds: Double
    var quotaWindows: [QuotaWindow]? = nil
    var fableQuotaWindow: QuotaWindow? = nil
    var planRenewalDate: Date?
    let hasError: Bool
    let errorMessage: String?
    var provider: AccountProvider? = nil
    var providerAccountNumber: Int? = nil
    var providerProfileID: String? = nil
    var providerIsActive: Bool? = nil
    var providerStatus: String? = nil

    var accountProvider: AccountProvider {
        provider ?? .codex
    }

    var isClaudeAccount: Bool {
        accountProvider == .claude
    }

    var emailPrefix: String {
        email.components(separatedBy: "@").first ?? email
    }

    var displayAlias: String? {
        Account.normalizedAlias(alias)
    }

    var displayName: String {
        displayAlias ?? email
    }

    var hasDisplayAlias: Bool {
        displayAlias != nil
    }

    var displayPlanName: String? {
        if isClaudeAccount,
           plan.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Claude") == .orderedSame {
            return nil
        }
        return PlanDisplayFormatter.badgeText(for: plan)
    }

    var displayWorkspaceName: String {
        Account.normalizedAlias(workspaceAlias) ?? workspace
    }

    var hasDisplayWorkspaceAlias: Bool {
        Account.normalizedAlias(workspaceAlias) != nil
    }

    var searchText: String {
        [displayAlias, email, displayWorkspaceName, workspace, plan, accountProvider.displayName]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    static func normalizedAlias(_ alias: String?) -> String? {
        guard let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var accountID: String {
        let pieces = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return "" }
        let value = String(pieces[1])
        guard value != profileKey else { return "" }
        return value
    }

    /// New snapshots store exact API windows. Older snapshots fall back to the legacy 5h/1w fields.
    var usageWindows: [QuotaWindow] {
        if let quotaWindows {
            return quotaWindows.sorted { $0.limitSeconds < $1.limitSeconds }
        }
        guard !hasError else { return [] }
        return [
            QuotaWindow(
                limitSeconds: QuotaWindow.fiveHourSeconds,
                remainingPercent: sessionFree,
                resetAfterSeconds: sessionResetSeconds
            ),
            QuotaWindow(
                limitSeconds: QuotaWindow.weeklySeconds,
                remainingPercent: weeklyFree,
                resetAfterSeconds: weeklyResetSeconds
            ),
        ]
    }

    var fiveHourQuotaWindow: QuotaWindow? {
        usageWindows.first { $0.kind == .fiveHour }
    }

    var weeklyQuotaWindow: QuotaWindow? {
        usageWindows.first { $0.kind == .weekly }
    }

    var limitingQuotaRemaining: Double {
        usageWindows.map(\.remainingPercent).min() ?? 0
    }

    /// Weekly quota fully used; the row uses exhausted styling.
    var isWeeklyExhausted: Bool {
        hasError || weeklyQuotaWindow?.isExhausted == true
    }

    var isFreePlan: Bool {
        plan.codexVitalsNormalized == "free"
    }

    var isFreeWaitingForReset: Bool {
        guard !hasError,
              isFreePlan,
              let sessionWindow = fiveHourQuotaWindow,
              sessionWindow.isExhausted,
              weeklyQuotaWindow?.isExhausted != true else {
            return false
        }
        return sessionWindow.resetAfterSeconds > 0
    }

    var freePlanResetSeconds: Double {
        fiveHourQuotaWindow?.resetAfterSeconds
            ?? weeklyQuotaWindow?.resetAfterSeconds
            ?? 0
    }

    var nextWaitingResetSeconds: Double {
        let exhaustedReset = usageWindows
            .filter(\.isExhausted)
            .map(\.resetAfterSeconds)
            .filter { $0 > 0 }
            .min()
        if let exhaustedReset { return exhaustedReset }

        return usageWindows
            .map(\.resetAfterSeconds)
            .filter { $0 > 0 }
            .min()
            ?? Double.greatestFiniteMagnitude
    }

    var isUsableForCodex: Bool {
        !hasError && !usageWindows.isEmpty && usageWindows.allSatisfy { !$0.isExhausted }
    }

    var canSwitchProviderAccount: Bool {
        guard isClaudeAccount else { return isUsableForCodex }
        switch providerStatus {
        case "ok":
            return isUsableForCodex
        case "unavailable":
            return true
        default:
            return false
        }
    }

    /// Hours until weekly window resets (from API `reset_after_seconds`).
    var hoursUntilWeeklyReset: Double {
        guard let weeklyQuotaWindow else { return .infinity }
        return max(0, weeklyQuotaWindow.resetAfterSeconds / 3600)
    }

    /// Highlight reset text when meaningful balance expires soon.
    var isWeeklyResetUrgent: Bool {
        guard let weeklyQuotaWindow else { return false }
        return isUsableForCodex
            && weeklyQuotaWindow.remainingPercent >= 20
            && hoursUntilWeeklyReset < 12
    }

    /// Top priority strip: useful balance that resets in less than 24 hours.
    var isWeeklyPriority: Bool {
        guard let weeklyQuotaWindow else { return false }
        let shortTermRemaining = fiveHourQuotaWindow?.remainingPercent ?? 100
        return isUsableForCodex
            && shortTermRemaining >= 20
            && weeklyQuotaWindow.remainingPercent >= 20
            && hoursUntilWeeklyReset < 24
    }

    var planDaysRemaining: Int? {
        guard let planRenewalDate else { return nil }
        return max(0, Int(ceil(planRenewalDate.timeIntervalSinceNow / 86_400)))
    }
}

// MARK: - Enums

enum ListDensity: String {
    case expanded
    case compact
}

enum AutoRefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    static let userDefaultsKey = "autoRefreshIntervalSeconds"

    var id: Int { rawValue }

    var seconds: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .fiveMinutes:
            return "5 min"
        case .tenMinutes:
            return "10 min"
        case .fifteenMinutes:
            return "15 min"
        case .thirtyMinutes:
            return "30 min"
        }
    }

    static var stored: AutoRefreshInterval {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else {
            return .tenMinutes
        }
        return AutoRefreshInterval(rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)) ?? .tenMinutes
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

extension String {
    fileprivate var codexVitalsNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isGenericWorkspaceName: Bool {
        let trimmed = codexVitalsNormalized
        return trimmed == "team" || trimmed == "plus" || trimmed == "pro" || trimmed == "pro lite" || trimmed == "pro_lite" || trimmed == "pro-lite" || trimmed == "free" || trimmed == "?"
    }

    var isPersonalPlanType: Bool {
        let trimmed = codexVitalsNormalized
        return trimmed == "plus" || trimmed == "pro" || trimmed == "pro lite" || trimmed == "pro_lite" || trimmed == "pro-lite" || trimmed == "free" || trimmed == "personal" || trimmed == "individual"
    }

    var isUnknownPlanType: Bool {
        let trimmed = codexVitalsNormalized
        return trimmed.isEmpty || trimmed == "?"
    }

    var isLikelyPersonalAccountID: Bool {
        codexVitalsNormalized.hasPrefix("user-")
    }
}

// MARK: - Theme

struct Theme {
    static let healthyAccent = Color(hex: "30D158")
    static let warningAccent = Color(hex: "FF9F0A")
    static let dangerAccent = Color(hex: "FF453A")

    static let panelCornerRadius: CGFloat = 10
    static let rowCornerRadius: CGFloat = 8
    static let controlCornerRadius: CGFloat = 7

    static let appTitleFont = Font.system(size: 14, weight: .semibold)
    static let sectionTitleFont = Font.system(size: 10.5, weight: .semibold)
    static let accountTitleFont = Font.system(size: 11.5, weight: .semibold)
    static let accountEmailFont = Font.system(size: 10.5, weight: .regular)
    static let metadataFont = Font.system(size: 10, weight: .medium)
    static let metricFont = Font.system(size: 10.5, weight: .semibold)
    static let settingsLabelFont = Font.system(size: 12, weight: .medium)

    static let healthyText = Color(lightHex: "157D40", darkHex: "30D158")
    static let warningText = Color(lightHex: "A25800", darkHex: "FF9F0A")
    static let dangerText = Color(lightHex: "B92F27", darkHex: "FF453A")

    static let toolbarSurface = Color(lightHex: "20FFFFFF", darkHex: "10FFFFFF")
    static let toolbarBorder = Color(lightHex: "19000000", darkHex: "24FFFFFF")
    static let controlHoverSurface = Color(lightHex: "12000000", darkHex: "18FFFFFF")
    static let controlSelectedSurface = Color(lightHex: "1A000000", darkHex: "24FFFFFF")
    static let controlBorder = Color(lightHex: "12000000", darkHex: "20FFFFFF")
    static let listSurfaceTint = Color(lightHex: "16FFFFFF", darkHex: "09FFFFFF")
    static let listBorder = Color(lightHex: "18000000", darkHex: "26FFFFFF")
    static let listDivider = Color(lightHex: "12000000", darkHex: "1AFFFFFF")
    static let sectionSurface = Color(lightHex: "05000000", darkHex: "0AFFFFFF")
    static let rowHoverSurface = Color(lightHex: "0B000000", darkHex: "12FFFFFF")
    static let rowHoverBorder = Color(lightHex: "0D000000", darkHex: "18FFFFFF")
    static let activeRowSurface = Color(lightHex: "0D30D158", darkHex: "1230D158")
    static let activeRowBorder = Color(lightHex: "1C30D158", darkHex: "2630D158")
    static let metricSurface = Color(lightHex: "10000000", darkHex: "14FFFFFF")
    static let metricBorder = Color(lightHex: "10000000", darkHex: "20FFFFFF")
    static let warningSurface = Color(lightHex: "14FF9F0A", darkHex: "1FFF9F0A")
    static let warningBorder = Color(lightHex: "33914C00", darkHex: "38FF9F0A")
    static let dangerSurface = Color(lightHex: "12FF453A", darkHex: "1FFF453A")
    static let dangerBorder = Color(lightHex: "32B92F27", darkHex: "38FF453A")
    static let settingsGroupSurface = Color(lightHex: "0A000000", darkHex: "0FFFFFFF")
    static let settingsGroupBorder = Color(lightHex: "12000000", darkHex: "1EFFFFFF")

    static func providerSectionSurface(for provider: AccountProvider) -> Color {
        .clear
    }

    static func providerHeaderSurface(for provider: AccountProvider) -> Color {
        switch provider {
        case .codex:
            return Color(lightHex: "0C7D6AE7", darkHex: "127D6AE7")
        case .claude:
            return Color(lightHex: "0CD97757", darkHex: "12D97757")
        }
    }

    static func providerBorder(for provider: AccountProvider) -> Color {
        switch provider {
        case .codex:
            return Color(lightHex: "207D6AE7", darkHex: "307D6AE7")
        case .claude:
            return Color(lightHex: "20D97757", darkHex: "30D97757")
        }
    }

    static func providerText(for provider: AccountProvider) -> Color {
        switch provider {
        case .codex:
            return Color(lightHex: "6752C7", darkHex: "B4A9FF")
        case .claude:
            return Color(lightHex: "A84F34", darkHex: "F3A184")
        }
    }

    /// Bar fill color based on % free remaining.
    static func barColor(for pct: Double) -> Color {
        switch pct {
        case 50...:       return healthyAccent
        case 20..<50:     return Color(lightHex: "8A6A00", darkHex: "FFD60A")   // yellow
        case 5..<20:      return warningAccent
        case 0.001..<5:   return dangerAccent
        default:          return Color(hex: "8E8E93")   // gray (0 %)
        }
    }

    /// Small status text needs more contrast than the brighter graphical bar fill.
    static func statusTextColor(for pct: Double) -> Color {
        switch pct {
        case 50...:       return healthyText
        case 20..<50:     return Color(lightHex: "806400", darkHex: "FFD60A")
        case 5..<20:      return warningText
        case 0.001..<5:   return dangerText
        default:          return Color(lightHex: "5F6368", darkHex: "A9A9AE")
        }
    }

    /// Weekly bar when quota is exhausted: neutral gray, not alert red.
    static let weeklyExhaustedBar = Color(hex: "8E8E93")

    /// Workspace chip background.
    static func workspaceColor(for ws: String) -> Color {
        let hex = workspaceHex(for: ws)
        return Color(lightHex: "18\(hex)", darkHex: "26\(hex)")
    }

    static func workspaceBorderColor(for ws: String) -> Color {
        let hex = workspaceHex(for: ws)
        return Color(lightHex: "26\(hex)", darkHex: "38\(hex)")
    }

    /// Keep chip labels colorful while darkening or lightening the accent for contrast.
    static func workspaceTextColor(for ws: String) -> Color {
        let hex = workspaceHex(for: ws)
        return Color(
            lightHex: scaledHex(hex, by: 0.78),
            darkHex: lightenedHex(hex, amount: 0.32)
        )
    }

    private static func workspaceHex(for ws: String) -> String {
        if let hex = planHex(for: ws) {
            return hex
        }
        let stableIndex = ws.lowercased().unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        switch stableIndex % 6 {
        case 0: return "5F80A8"
        case 1: return "6F9277"
        case 2: return "8A6F9B"
        case 3: return "A7666E"
        case 4: return "AF8158"
        default: return "7871A6"
        }
    }

    private static func planHex(for raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        if key.contains("pro") && key.contains("lite") {
            return "5E8CDA"
        }
        if key == "pro" || key.contains("pro ") {
            return "7D6AE7"
        }
        if key == "plus" {
            return "2C8E7B"
        }
        if key == "free" {
            return "6E7681"
        }
        return nil
    }

    private static func scaledHex(_ hex: String, by factor: Double) -> String {
        transformedHex(hex) { component in
            Int((Double(component) * factor).rounded())
        }
    }

    private static func lightenedHex(_ hex: String, amount: Double) -> String {
        transformedHex(hex) { component in
            Int((Double(component) + (255 - Double(component)) * amount).rounded())
        }
    }

    private static func transformedHex(
        _ hex: String,
        transform: (Int) -> Int
    ) -> String {
        let value = Int(hex, radix: 16) ?? 0
        let components = [value >> 16, value >> 8 & 0xFF, value & 0xFF]
            .map { min(255, max(0, transform($0))) }
        return String(format: "%02X%02X%02X", components[0], components[1], components[2])
    }
}

// MARK: - Color Helper

extension Color {
    init(lightHex: String, darkHex: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex)
        })
    }

    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        let r, g, b, a: UInt64
        switch h.count {
        case 6: (a, r, g, b) = (255, n >> 16, n >> 8 & 0xFF, n & 0xFF)
        case 8: (a, r, g, b) = (n >> 24, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red:     Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        let r, g, b, a: UInt64
        switch h.count {
        case 6: (a, r, g, b) = (255, n >> 16, n >> 8 & 0xFF, n & 0xFF)
        case 8: (a, r, g, b) = (n >> 24, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(srgbRed: Double(r) / 255,
                  green:   Double(g) / 255,
                  blue:    Double(b) / 255,
                  alpha:   Double(a) / 255)
    }
}

// MARK: - Reset Formatter

struct ResetFormatter {
    private static let weekdaysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Weekly exhausted row: "resets Wed 18:19" because reset is the only actionable info.
    static func formatReset(seconds: Double) -> String {
        let inner = format(seconds: seconds)
        if inner == "now" { return "resets now" }
        return "resets \(inner)"
    }

    /// Short context-aware string.
    static func format(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        let now = Date()
        let tgt = now.addingTimeInterval(seconds)
        let cal = Calendar.current
        let t   = hhmm(tgt)
        if cal.isDateInToday(tgt) { return t }
        if cal.isDateInTomorrow(tgt) { return "tomorrow \(t)" }
        if isSameWeekStartingSunday(now, tgt) {
            let wd = cal.component(.weekday, from: tgt)
            return "\(weekdaysShort[wd - 1]) \(t)"
        }
        return dateTimeString(target: tgt, now: now, time: t)
    }

    static func formatFreeReturn(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        let now = Date()
        let tgt = now.addingTimeInterval(seconds)
        let cal = Calendar.current
        let t = hhmm(tgt)
        if cal.isDateInToday(tgt) { return "today \(t)" }
        if cal.isDateInTomorrow(tgt) { return "tomorrow \(t)" }
        return dateTimeString(target: tgt, now: now, time: t)
    }

    static func timeOnly(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        return hhmm(Date().addingTimeInterval(seconds))
    }

    static func compact(seconds: Double) -> String {
        guard seconds > 0 else { return "now" }
        let now = Date()
        let tgt = now.addingTimeInterval(seconds)
        let cal = Calendar.current
        let t = hhmm(tgt)
        if cal.isDateInToday(tgt) { return t }
        if cal.isDateInTomorrow(tgt) { return "tmr \(t)" }
        if isSameWeekStartingSunday(now, tgt) {
            let wd = cal.component(.weekday, from: tgt)
            return "\(weekdaysShort[wd - 1]) \(t)"
        }
        return dateString(target: tgt, now: now)
    }

    private static func startOfWeekSunday(containing date: Date) -> Date {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: dayStart)
        return cal.date(byAdding: .day, value: -(weekday - 1), to: dayStart) ?? dayStart
    }

    private static func isSameWeekStartingSunday(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.current
        let sa = startOfWeekSunday(containing: a)
        let sb = startOfWeekSunday(containing: b)
        return cal.isDate(sa, inSameDayAs: sb)
    }

    private static func dateTimeString(target: Date, now: Date, time: String) -> String {
        "\(dateString(target: target, now: now)) \(time)"
    }

    private static func dateString(target: Date, now: Date) -> String {
        let cal = Calendar.current
        let d = cal.component(.day, from: target)
        let m = cal.component(.month, from: target)
        let y = cal.component(.year, from: target)
        let yNow = cal.component(.year, from: now)
        if y == yNow {
            return String(format: "%02d/%02d", d, m)
        }
        return String(format: "%02d/%02d/%d", d, m, y)
    }

    /// Full tooltip string.
    static func fullTooltip(seconds: Double) -> String {
        guard seconds > 0 else { return "Now" }
        let tgt = Date().addingTimeInterval(seconds)
        return tooltipFormatter.string(from: tgt)
    }

    static func fullTooltip(date: Date) -> String {
        tooltipFormatter.string(from: date)
    }

    private static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d 'at' HH:mm"
        return f
    }()
}

struct PlanCycleFormatter {
    static func daysText(for account: Account) -> String? {
        guard let days = account.planDaysRemaining else { return nil }
        return "\(days)D"
    }

    static func tooltip(for date: Date) -> String {
        "Plan renews \(ResetFormatter.fullTooltip(date: date))"
    }
}

struct PlanDisplayFormatter {
    static func badgeText(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        guard !normalized.isEmpty, normalized != "?" else { return nil }

        if normalized.contains("pro") && normalized.contains("lite") {
            return "Pro Lite"
        }
        if normalized == "pro" || normalized.hasPrefix("pro ") || normalized.contains(" pro") {
            return "Pro"
        }
        if normalized == "plus" || normalized.contains("plus") {
            return "Plus"
        }
        if normalized == "free" {
            return "Free"
        }
        if normalized == "team" || normalized.contains("team") {
            return "Team"
        }
        if normalized == "enterprise" || normalized.contains("enterprise") {
            return "Enterprise"
        }

        return trimmed
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}
