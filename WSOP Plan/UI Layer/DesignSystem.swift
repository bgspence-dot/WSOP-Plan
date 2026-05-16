// DesignSystem.swift
// WSOPPlanUI
//
// All semantic color tokens, type scale, and per-item visual treatment.
// Single file for the three design-system concerns — keeps Phase 5 file count clean.
// Aesthetic: dark felt green base, warm gold accents, cream text. Casino floor palette.

import SwiftUI

// MARK: - AppColors

public enum AppColors {

    // MARK: - Backgrounds

    /// Deep poker-felt green — primary app background
    public static let backgroundPrimary   = Color(hex: "#111D11")
    /// Slightly lighter surface for cards and sheets
    public static let backgroundSurface   = Color(hex: "#1A2A1A")
    /// Elevated surface — nav bars, filter chips
    public static let backgroundElevated  = Color(hex: "#223322")
    /// Separator / divider lines
    public static let separator           = Color(hex: "#2E3D2E")

    // MARK: - Accents

    /// Warm casino gold — primary accent
    public static let gold                = Color(hex: "#C9A84C")
    /// Muted gold for secondary elements
    public static let goldMuted           = Color(hex: "#8A6E2F")
    /// Bright gold for active/selected states
    public static let goldBright          = Color(hex: "#E8C46A")

    // MARK: - Text

    /// Primary cream text
    public static let textPrimary         = Color(hex: "#F0E8D0")
    /// Secondary dimmed text
    public static let textSecondary       = Color(hex: "#9BA88A")
    /// Tertiary / placeholder
    public static let textTertiary        = Color(hex: "#5A6650")
    /// Inverse (dark text on light chip)
    public static let textInverse         = Color(hex: "#111D11")

    // MARK: - Intent Colors

    public static let intentDefinite      = Color(hex: "#4CAF50")   // green — "going"
    public static let intentLikely        = Color(hex: "#8BC34A")   // light green — "probably"
    public static let intentInterested    = Color(hex: "#C9A84C")   // gold — "maybe"
    public static let intentSkip          = Color(hex: "#5A4A3A")   // dark brown — "skip"
    public static let intentPlay          = Color(hex: "#4CAF50")   // green — playing
    public static let intentNone          = Color(hex: "#2E3D2E")   // felt — no intent

    // MARK: - Status Colors

    public static let statusPlaying       = Color(hex: "#4CAF50")
    public static let statusCashed        = Color(hex: "#C9A84C")
    public static let statusEliminated    = Color(hex: "#C0392B")
    public static let statusRegistered    = Color(hex: "#5B8DB8")
    public static let statusCancelled     = Color(hex: "#444444")

    // MARK: - Game Type Colors (venue-tinting fallback)

    public static let gameHoldEm          = Color(hex: "#C9A84C")
    public static let gameOmaha           = Color(hex: "#5B8DB8")
    public static let gameMixed           = Color(hex: "#9B59B6")
    public static let gameStud            = Color(hex: "#E67E22")
    public static let gameOther           = Color(hex: "#7F8C8D")

    // MARK: - Profit / Loss

    public static let profit              = Color(hex: "#4CAF50")
    public static let loss                = Color(hex: "#C0392B")
    public static let breakeven           = Color(hex: "#9BA88A")
}

// MARK: - Color + Hex Init

extension Color {
    public init(hex: String) {
        let hex    = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int    = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hex.count {
        case 6:  (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:  (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b, a) = (0, 0, 0, 255)
        }
        self.init(
            .sRGB,
            red:     Double(r) / 255,
            green:   Double(g) / 255,
            blue:    Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - TimelineItemStyle

/// Per-type visual treatment for timeline row rendering.
public struct TimelineItemStyle {
    public let accentColor:    Color
    public let iconName:       String    // SF Symbol
    public let rowBackground:  Color
    public let labelText:      String

    // MARK: - Factory

    public static func style(for item: TimelineItem) -> TimelineItemStyle {
        switch item {
        case .opportunity(let s): return opportunityStyle(s)
        case .planItem(let s):    return planItemStyle(s)
        case .entry(let s):       return entryStyle(s)
        }
    }

    // MARK: - Opportunity

    private static func opportunityStyle(_ s: OpportunitySnapshot) -> TimelineItemStyle {
        if s.isCancelled {
            return TimelineItemStyle(
                accentColor:   AppColors.statusCancelled,
                iconName:      "xmark.circle",
                rowBackground: AppColors.backgroundSurface.opacity(0.4),
                labelText:     "Cancelled"
            )
        }
        let (color, icon) = intentVisuals(s.planIntent)
        return TimelineItemStyle(
            accentColor:   color,
            iconName:      icon,
            rowBackground: AppColors.backgroundSurface,
            labelText:     s.planIntent.displayName
        )
    }

    private static func intentVisuals(_ intent: PlanIntent) -> (Color, String) {
        switch intent {
        case .definite:   return (AppColors.intentDefinite,   "checkmark.circle.fill")
        case .likely:     return (AppColors.intentLikely,     "circle.dotted")
        case .interested: return (AppColors.intentInterested, "star.circle")
        case .skip:       return (AppColors.intentSkip,       "minus.circle")
        case .none:       return (AppColors.intentNone,       "circle")
        case .play:       return (AppColors.intentPlay,      "suit.spade.fill")
        }
    }

    // MARK: - Plan Item

    private static func planItemStyle(_ s: PlanItemSnapshot) -> TimelineItemStyle {
        if s.type == .timeBlock {
            return TimelineItemStyle(
                accentColor:   AppColors.goldMuted,
                iconName:      "clock.fill",
                rowBackground: AppColors.backgroundElevated,
                labelText:     "Block"
            )
        }
        let (color, icon) = intentVisuals(s.intent)
        return TimelineItemStyle(
            accentColor:   color,
            iconName:      icon,
            rowBackground: AppColors.backgroundElevated,
            labelText:     s.intent.displayName
        )
    }

    // MARK: - Entry

    private static func entryStyle(_ s: EntrySnapshot) -> TimelineItemStyle {
        switch s.status {
        case .playing, .lateReg:
            return TimelineItemStyle(
                accentColor:   AppColors.statusPlaying,
                iconName:      "suit.spade.fill",
                rowBackground: Color(hex: "#1A2E1A"),
                labelText:     "Playing"
            )
        case .cashed, .won:
            return TimelineItemStyle(
                accentColor:   AppColors.statusCashed,
                iconName:      "dollarsign.circle.fill",
                rowBackground: Color(hex: "#2A2210"),
                labelText:     s.status == .won ? "Won!" : "Cashed"
            )
        case .eliminated:
            return TimelineItemStyle(
                accentColor:   AppColors.statusEliminated,
                iconName:      "arrow.down.circle",
                rowBackground: AppColors.backgroundSurface,
                labelText:     "Busted"
            )
        case .registered:
            return TimelineItemStyle(
                accentColor:   AppColors.statusRegistered,
                iconName:      "ticket.fill",
                rowBackground: AppColors.backgroundSurface,
                labelText:     "Registered"
            )
        case .cancelled:
            return TimelineItemStyle(
                accentColor:   AppColors.statusCancelled,
                iconName:      "xmark.circle",
                rowBackground: AppColors.backgroundSurface,
                labelText:     "Cancelled"
            )
        }
    }
}

// MARK: - PlanIntent color extension (UI layer only — displayName lives in Domain/PlanItem.swift)
extension PlanIntent {
    public var color: Color {
        switch self {
        case .none:       return AppColors.intentNone
        case .interested: return AppColors.intentInterested
        case .likely:     return AppColors.intentLikely
        case .definite:   return AppColors.intentDefinite
        case .skip:       return AppColors.intentSkip
        case .play:       return AppColors.intentPlay
        }
    }

    /// Emoji icon shown appended to tournament titles — matches the Plan picker buttons.
    public var icon: String {
        switch self {
        case .none:       return ""
        case .interested: return "star.fill"
        case .likely:     return "circle.fill"
        case .definite:   return "checkmark.circle.fill"
        case .skip:       return "minus.circle.fill"
        case .play:       return "suit.spade.fill"
        }
    }

    /// Tinted row background used in Plan, Timeline, Results, and Explore rows.
    /// Interested = dim green, Likely = dim gold, Definite = dim red, none/skip = surface.
    public var rowBackground: Color {
        switch self {
        case .interested: return Color(hex: "#1A2E1A")   // dim green
        case .likely:     return Color(hex: "#2A2210")   // dim gold
        case .definite:   return Color(hex: "#2E1A1A")   // dim red
        case .skip:       return AppColors.backgroundSurface.opacity(0.5)
        case .play:       return Color(hex: "#1A2E1A")   // dim green — playing
        case .none:       return AppColors.backgroundSurface
        }
    }
}

// MARK: - Entry status row background
extension EntryStatus {
    /// Tinted row background for results rows.
    public var rowBackground: Color {
        switch self {
        case .playing, .lateReg: return Color(hex: "#1A2E1A")   // dim green — live
        case .registered:        return Color(hex: "#1A1E2E")   // dim blue — registered
        case .cashed, .won:      return Color(hex: "#2A2210")   // dim gold — cashed
        case .eliminated:        return AppColors.backgroundSurface
        case .cancelled:         return AppColors.backgroundSurface.opacity(0.5)
        }
    }
}

// MARK: - GameType color extension
extension GameType {
    public var color: Color {
        switch self {
        case .holdEm:                        return AppColors.gameHoldEm
        case .omahaHi, .omahaHiLo, .plo5, .plo6: return AppColors.gameOmaha
        case .sevenCardStud, .sevenCardStudHiLo, .razz: return AppColors.gameStud
        case .horse, .eight, .dealers, .mixed: return AppColors.gameMixed
        default:                             return AppColors.gameOther
        }
    }
}

// MARK: - Platform-safe Navigation Bar Styling

extension View {
    /// Applies dark navigation bar styling on iOS.
    /// No-op on macOS where these APIs are unavailable.
    @ViewBuilder
    func navigationBarStyling() -> some View {
#if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppColors.backgroundPrimary, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
#else
        self
#endif
    }
}

extension ToolbarItemPlacement {
    /// `.navigationBarLeading` on iOS, `.automatic` on macOS.
    static var leadingAction: ToolbarItemPlacement {
#if os(iOS)
        .navigationBarLeading
#else
        .automatic
#endif
    }

    /// `.navigationBarTrailing` on iOS, `.automatic` on macOS.
    static var trailingAction: ToolbarItemPlacement {
#if os(iOS)
        .navigationBarTrailing
#else
        .automatic
#endif
    }
}
