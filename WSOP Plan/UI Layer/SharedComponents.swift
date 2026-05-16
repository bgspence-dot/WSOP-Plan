// SharedComponents.swift
// WSOPPlanUI
//
// Reusable atomic UI components used across all tab views.
// All are stateless views that render from value-type inputs.

import SwiftUI

// MARK: - MoneyLabel

/// Renders a MoneyAmount in monospaced numerics with optional profit/loss coloring.
public struct MoneyLabel: View {
    let amount: MoneyAmount
    let style: MoneyLabelStyle

    public enum MoneyLabelStyle {
        case neutral      // gold
        case profitLoss   // green if positive, red if negative
        case buyin        // cream, compact
        case large        // large display, always gold
    }

    public init(_ amount: MoneyAmount, style: MoneyLabelStyle = .neutral) {
        self.amount = amount
        self.style  = style
    }

    public var body: some View {
        Text(displayText)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
    }

    private var displayText: String {
        switch style {
        case .large:  return amount.compactDisplayString
        default:      return amount.compactDisplayString
        }
    }

    private var font: Font {
        switch style {
        case .large:  return .title.weight(.bold).monospacedDigit()
        case .buyin:  return .footnote.weight(.semibold).monospacedDigit()
        default:      return .subheadline.weight(.semibold).monospacedDigit()
        }
    }

    private var color: Color {
        switch style {
        case .profitLoss:
            if amount.cents > 0 { return AppColors.profit }
            if amount.cents < 0 { return AppColors.loss }
            return AppColors.textSecondary
        case .buyin:   return AppColors.textPrimary
        case .large:   return AppColors.gold
        default:       return AppColors.gold
        }
    }
}

// MARK: - GameTypeBadge

/// Pill badge for a GameType — abbreviated label with type-specific tint.
/// Returns EmptyView for NLH (implied default), O8, and Other (too generic).
public struct GameTypeBadge: View {
    let gameType: GameType
    let compact: Bool

    public init(_ gameType: GameType, compact: Bool = false) {
        self.gameType = gameType
        self.compact  = compact
    }

    /// All game type badges are suppressed — the game name always appears
    /// in the tournament name itself, making the badge redundant.
    private var shouldSuppress: Bool { true }

    public var body: some View {
        if shouldSuppress {
            EmptyView()
        } else {
            Text(gameType.abbreviation)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(gameType.color)
                .padding(.horizontal, compact ? 5 : 7)
                .padding(.vertical, compact ? 2 : 3)
                .background(
                    Capsule()
                        .fill(gameType.color.opacity(0.15))
                        .overlay(Capsule().strokeBorder(gameType.color.opacity(0.35), lineWidth: 0.5))
                )
        }
    }
}

// MARK: - FormatTagChip

/// Compact chip for a single FormatTag. Used in row and detail views.
public struct FormatTagChip: View {
    let tag: FormatTag
    let highlighted: Bool

    public init(_ tag: FormatTag, highlighted: Bool = false) {
        self.tag         = tag
        self.highlighted = highlighted
    }

    public var body: some View {
        Text(tag.chipLabel)
            .font(.caption2.weight(highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? AppColors.gold : AppColors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(highlighted
                          ? AppColors.goldMuted.opacity(0.25)
                          : AppColors.backgroundElevated)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                highlighted ? AppColors.goldMuted.opacity(0.6) : AppColors.separator,
                                lineWidth: 0.5
                            )
                    )
            )
    }
}

/// Horizontal scrolling row of FormatTagChips.
/// Automatically suppresses:
/// - `.freezeout` (always implied when no re-entry tags are present)
/// - Tags whose display text already appears in `tournamentName`
public struct FormatTagRow: View {
    let tags:           [FormatTag]
    let highlighted:    Set<FormatTag>
    let tournamentName: String

    public init(
        tags:           [FormatTag],
        highlighted:    Set<FormatTag> = [],
        tournamentName: String = ""
    ) {
        self.tags           = tags
        self.highlighted    = highlighted
        self.tournamentName = tournamentName
    }

    /// Tags visible after filtering implied/redundant ones.
    private var visibleTags: [FormatTag] {
        let lower = tournamentName.lowercased()
        return tags.filter { tag in
            // Drop freezeout — always implied
            if tag == .freezeout { return false }
            // Drop a tag if its chipLabel or displayName appears in the tournament name
            let chip    = tag.chipLabel.lowercased()
            let display = tag.displayName.lowercased()
            if lower.contains(chip) || lower.contains(display) { return false }
            // Drop bounty/PKO chip when name contains "bounty" or "knockout"
            if tag == .bounty || tag == .progressiveBounty {
                if lower.contains("bounty") || lower.contains("knockout") ||
                   lower.contains("pko") { return false }
            }
            // Drop mystery when name contains "mystery"
            if tag == .mystery && lower.contains("mystery") { return false }
            // Drop satellite when name contains "sat" or "satellite"
            if tag == .satellite || tag == .superSatellite {
                if lower.contains("sat") || lower.contains("satellite") { return false }
            }
            // Drop seniors/ladies/employees when name contains them
            if tag == .seniors && (lower.contains("senior") || lower.contains("50+")) { return false }
            if tag == .ladies  && (lower.contains("ladies") || lower.contains("women")) { return false }
            if tag == .turbo   && lower.contains("turbo")   { return false }
            if tag == .deepStack && (lower.contains("deep") || lower.contains("deepstack")) { return false }
            if tag == .highRoller && lower.contains("high roller") { return false }
            if tag == .championship && lower.contains("championship") { return false }
            if tag == .shootout  && lower.contains("shootout") { return false }
            if tag == .sixMax    && (lower.contains("6-max") || lower.contains("6 max")) { return false }
            return true
        }
    }

    public var body: some View {
        if visibleTags.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(visibleTags, id: \.self) { tag in
                        FormatTagChip(tag, highlighted: highlighted.contains(tag))
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }
}

// MARK: - DateSectionHeader

/// Day section header used in Timeline and Explore list sections.
public struct DateSectionHeader: View {
    let date:    Date
    let summary: DaySummary?

    public init(date: Date, summary: DaySummary? = nil) {
        self.date    = date
        self.summary = summary
    }

    public var body: some View {
        // Single compact line: "Sat · Jun 14" + intent badges
        HStack(spacing: 10) {
            Text(singleLineDate)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppColors.gold)

            Spacer()

            // Intent summary badges
            if let s = summary, s.hasAnyIntent {
                HStack(spacing: 6) {
                    if s.definiteCount > 0 {
                        IntentCountBadge(count: s.definiteCount, intent: .definite)
                    }
                    if s.likelyCount > 0 {
                        IntentCountBadge(count: s.likelyCount, intent: .likely)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        // Highlighted background: gold-tinted strip clearly separates day groups
        .background(AppColors.gold.opacity(0.28))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppColors.gold.opacity(0.60))
                .frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColors.gold.opacity(0.40))
                .frame(height: 0.5)
        }
    }

    private var singleLineDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEE · MMM d"
        return f.string(from: date)
    }
}

private struct IntentCountBadge: View {
    let count:  Int
    let intent: PlanIntent

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(intent.color)
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(intent.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(intent.color.opacity(0.12), in: Capsule())
    }
}

// MARK: - TimeLabel

/// Fixed-width time display so all rows align regardless of hour digit count.
/// Single-digit hours (1-9) are padded with a leading en-space (U+2002) so
/// "9:00 AM" occupies the same width as "10:00 AM". Color is always .primary.
public struct TimeLabel: View {
    let date:  Date
    let dimmed: Bool

    public init(_ date: Date, dimmed: Bool = false) {
        self.date   = date
        self.dimmed = dimmed
    }

    public var body: some View {
        Text(formatted)
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .fixedSize()
    }

    private var formatted: String {
        let cal  = Calendar.current
        let hour = cal.component(.hour, from: date)
        let h12  = hour % 12 == 0 ? 12 : hour % 12
        let min  = cal.component(.minute, from: date)
        let ampm = hour < 12 ? "AM" : "PM"
        let minStr  = String(format: ":%02d", min)  // always show :00
        // En-space (U+2002) pads single-digit hours so columns align
        let hourStr = h12 < 10 ? "\u{2002}\(h12)" : "\(h12)"
        return "\(hourStr)\(minStr) \(ampm)"
    }
}

// MARK: - LoadingOverlay

public struct LoadingOverlay: View {
    public init() {}
    public var body: some View {
        ZStack {
            AppColors.backgroundPrimary.opacity(0.7)
            ProgressView()
                .tint(AppColors.gold)
                .scaleEffect(1.3)
        }
        .ignoresSafeArea()
    }
}

// MARK: - ErrorBanner

public struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    public init(message: String, dismiss: @escaping () -> Void) {
        self.message = message
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.gold)
            Text(message)
                .font(.footnote)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(AppColors.textSecondary)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppColors.goldMuted.opacity(0.4), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - SectionCard modifier

public struct SectionCard: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(AppColors.backgroundSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AppColors.separator, lineWidth: 0.5)
            )
    }
}

extension View {
    public func sectionCard() -> some View {
        modifier(SectionCard())
    }
}

// MARK: - VenueIcon

/// Canonical SF Symbol icon and brand color for each known Vegas poker room.
/// Used in timeline rows, venue filter chips, the import screen, and section headers.
public enum VenueIcon {

    public static func icon(for venue: String) -> String {
        switch venue.lowercased() {
        case let s where s.contains("wsop") ||
                         s.contains("horseshoe") ||
                         s.contains("bally"):      return "trophy.fill"
        case let s where s.contains("wynn"):       return "w.circle.fill"
        case let s where s.contains("venetian"):   return "building.columns.fill"
        case let s where s.contains("aria"):       return "a.circle.fill"
        case let s where s.contains("mgm") ||
                         s.contains("bellagio"):   return "crown.fill"
        case let s where s.contains("orleans"):    return "music.note.house.fill"
        case let s where s.contains("south point"):return "mappin.circle.fill"
        case let s where s.contains("golden nugget") ||
                         s.contains("nugget"):     return "sparkles"
        case let s where s.contains("binion"):     return "star.fill"
        case let s where s.contains("resorts"):    return "r.circle.fill"
        default:                                   return "suit.spade.fill"
        }
    }

    public static func color(for venue: String) -> Color {
        switch venue.lowercased() {
        case let s where s.contains("wsop"):         return Color(hex: "#C0392B")
        case let s where s.contains("wynn"):         return Color(hex: "#2E7D32")
        case let s where s.contains("venetian"):     return Color(hex: "#6A1B9A")
        case let s where s.contains("aria"):         return Color(hex: "#1565C0")
        case let s where s.contains("mgm"):          return Color(hex: "#1B5E20")
        case let s where s.contains("orleans"):      return Color(hex: "#E65100")
        case let s where s.contains("south point"):  return Color(hex: "#4A148C")
        case let s where s.contains("golden nugget"):return Color(hex: "#F57F17")
        default:                                     return AppColors.gold
        }
    }

    /// A small filled circle with the venue's brand color — used as a dot indicator.
    public static func dot(for venue: String, size: CGFloat = 8) -> some View {
        Circle()
            .fill(color(for: venue))
            .frame(width: size, height: size)
    }
}

// MARK: - VenueBadge

/// Compact venue pill: icon + short name, tinted in brand color.
public struct VenueBadge: View {
    let name:    String
    let compact: Bool

    public init(_ name: String, compact: Bool = false) {
        self.name    = name
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            Image(systemName: VenueIcon.icon(for: name))
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            if !compact {
                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(VenueIcon.color(for: name))
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            Capsule()
                .fill(VenueIcon.color(for: name).opacity(0.12))
                .overlay(
                    Capsule()
                        .strokeBorder(VenueIcon.color(for: name).opacity(0.3), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - OpportunityRowContent (shared across Timeline, Explore, Plan)
//
// The canonical tournament row content block.
// Identical to the private version in TimelineViews — defined here so
// Explore and Plan can use it without duplication.
//
// Layout: [GameTypeBadge] [name + intent icon] [flight?] [Spacer] [buy-in]

public struct OpportunityRowContent: View {
    public let tournamentName:  String
    public let planIntent:      PlanIntent
    public let gameType:        GameType
    public let flightContext:   String
    public let totalCostCents:  Int64
    public let isCancelled:     Bool

    public init(
        tournamentName:  String,
        planIntent:      PlanIntent  = .none,
        gameType:        GameType    = .holdEm,
        flightContext:   String      = "",
        totalCostCents:  Int64       = 0,
        isCancelled:     Bool        = false
    ) {
        self.tournamentName = tournamentName
        self.planIntent     = planIntent
        self.gameType       = gameType
        self.flightContext  = flightContext
        self.totalCostCents = totalCostCents
        self.isCancelled    = isCancelled
    }

    // Convenience init from OpportunitySnapshot
    public init(snapshot: OpportunitySnapshot) {
        self.tournamentName = snapshot.tournamentName
        self.planIntent     = snapshot.planIntent
        self.gameType       = snapshot.gameType
        self.flightContext  = snapshot.flightContext
        self.totalCostCents = snapshot.totalCostCents
        self.isCancelled    = snapshot.isCancelled
    }

    public var body: some View {
        HStack(spacing: 5) {
            GameTypeBadge(gameType, compact: true)

            Text(tournamentName)
                .font(.footnote)
                .foregroundStyle(isCancelled ? Color.secondary : Color.primary)
                .lineLimit(1)
                .strikethrough(isCancelled)
                .layoutPriority(1)

            // Intent icon — immediately after name, small and unobtrusive
            if planIntent != .none {
                Image(systemName: planIntent.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(planIntent.color)
                    .fixedSize()
            }

            if let fl = compactFlight(flightContext) {
                Text(fl)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(AppColors.backgroundElevated, in: Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 4)

            if totalCostCents > 0 {
                Text(MoneyAmount(cents: totalCostCents).compactDisplayString)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isContinuationDay ? Color.secondary : Color.primary)
            }
        }
        .padding(.trailing, 12)
        .opacity(isCancelled ? 0.5 : 1.0)
    }

    /// True when flightContext indicates a continuation day (Day 2, Day 3, etc.)
    private var isContinuationDay: Bool {
        let s = flightContext.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.hasPrefix("day ") else { return false }
        let numStr = s.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return (Int(numStr) ?? 0) >= 2
    }

    private func compactFlight(_ ctx: String) -> String? {
        let s = ctx.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Lettered flights: "Day 1A", "Day 1B" → show badge
        if s.range(of: #"Day \d+[A-F]"#, options: .regularExpression) != nil {
            return s
        }
        // Plain continuation days: "Day 2", "Day 3" → show badge; "Day 1" → no badge
        if let m = s.range(of: #"Day (\d+)"#, options: .regularExpression) {
            let full = String(s[m])
            let num  = full.replacingOccurrences(of: "Day ", with: "")
            if let n = Int(num), n >= 2 { return full }
        }
        return nil
    }
}

// MARK: - TournamentRowShell (shared outer shell for Timeline, Explore, Plan)
//
// The canonical full row: color bar + time + venue icon + OpportunityRowContent + intent dot.
// Pass any OpportunitySnapshot and an optional tap handler.

public struct TournamentRowShell: View {
    public let snapshot:  OpportunitySnapshot
    public let onTap:     () -> Void

    public init(snapshot: OpportunitySnapshot, onTap: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onTap    = onTap
    }

    private var barColor: Color {
        if let v = snapshot.venueShortName { return VenueIcon.color(for: v) }
        return AppColors.gold
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // 3pt venue color bar
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 3)

                // Time + venue icon
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    TimeLabel(snapshot.startTime)
                    if let venue = snapshot.venueShortName {
                        Image(systemName: VenueIcon.icon(for: venue))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(VenueIcon.color(for: venue))
                    }
                }
                .fixedSize()
                .padding(.trailing, 8)

                // Content block — includes intent dot internally
                OpportunityRowContent(snapshot: snapshot)
            }
            .frame(minHeight: 24)
            .background(snapshot.planIntent.rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(snapshot.isCancelled ? 0.5 : 1.0)
    }
}
