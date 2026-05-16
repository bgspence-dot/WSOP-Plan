// ResultsViewModel.swift
// WSOPPlanPlanning
//
// Drives ResultsDashboardView and SessionListView.
// Aggregates all Entry and Result data for the trip window into summary stats
// and a chronological session list. All writes delegate to EntryRepositoryProtocol.
//
// Dependencies: WSOPPlanDomain, WSOPPlanData protocols

import Foundation

// MARK: - ResultsSummary

/// Aggregated financial and performance stats for the results dashboard.
public struct ResultsSummary: Sendable {
    public let totalEntriesPlayed:   Int
    public let totalBulletsPlayed:   Int      // entries + re-entries
    public let totalInvestedCents:   Int64
    public let totalPrizeCents:      Int64
    public let netProfitCents:       Int64
    public let cashCount:            Int
    public let cashRate:             Double   // cashes / entries, 0–1
    public let avgInvestmentCents:   Int64
    public let biggestCashCents:     Int64
    public let liveEntryCount:       Int      // currently in-progress

    public var totalInvested:   MoneyAmount { MoneyAmount(cents: totalInvestedCents) }
    public var totalPrize:      MoneyAmount { MoneyAmount(cents: totalPrizeCents) }
    public var netProfit:       MoneyAmount { MoneyAmount(cents: netProfitCents) }
    public var biggestCash:     MoneyAmount { MoneyAmount(cents: biggestCashCents) }
    public var avgInvestment:   MoneyAmount { MoneyAmount(cents: avgInvestmentCents) }
    public var isProfitable:    Bool        { netProfitCents > 0 }

    public static let empty = ResultsSummary(
        totalEntriesPlayed: 0, totalBulletsPlayed: 0, totalInvestedCents: 0,
        totalPrizeCents: 0, netProfitCents: 0, cashCount: 0,
        cashRate: 0, avgInvestmentCents: 0, biggestCashCents: 0, liveEntryCount: 0
    )
}

// MARK: - ResultsViewModel

@Observable
@MainActor
public final class ResultsViewModel {

    // MARK: - Published State

    /// Aggregated summary for the dashboard header.
    public private(set) var summary:      ResultsSummary = .empty

    /// Chronological list of all entries for the session list view.
    public private(set) var sessions:     [EntrySnapshot] = []

    /// Entries currently in progress (live = registered or playing).
    public private(set) var liveSessions: [EntrySnapshot] = []

    /// Entries that cashed.
    public private(set) var cashedSessions: [EntrySnapshot] = []

    public private(set) var isLoading:    Bool    = false
    public private(set) var errorMessage: String? = nil

    // MARK: - Result Entry Editor State
    // Bound to the result entry sheet.

    public var editorFinishPosition:  String = ""
    public var editorTotalEntries:    String = ""
    public var editorPlacesPaid:      String = ""
    public var editorBubblesPaid:     String = ""
    public var editorIsBubble:        Bool   = false
    public var editorIsChop:          Bool   = false
    public var editorChopNotes:       String = ""
    public var editorEndLevel:        String = ""
    public var editorStartTime:       Date?  = nil
    public var editorEndTime:         Date?  = nil
    public var editorStartingChips:   String = ""
    public var editorReEntryCount:    String = ""
    public var editorPrizeDollars:    String = ""
    public var editorPrizeType:       ResultPrizeType = .cash
    public var editorBountyDollars:   String = ""
    public var editorNotes:           String = ""
    public var editingEntryID:        UUID?  = nil
    public var isResultEditorPresented: Bool = false
    // Payout scanner
    public var isPayoutScannerPresented: Bool  = false
    public var scannedPayoutText:        String = ""

    // MARK: - Re-entry editor state
    public var reEntryTargetID:      UUID? = nil
    public var isReEntryConfirmPresented: Bool = false

    // MARK: - Dependencies

    private let entryRepo:  any EntryRepositoryProtocol
    public private(set) var activeRange: TripDateRange?

    // MARK: - Init

    public init(entryRepo: any EntryRepositoryProtocol) {
        self.entryRepo = entryRepo
        // Reload whenever any view records a new entry.
        // addObserver is synchronous and fires immediately on the posting thread,
        // then we hop to MainActor to do the reload.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("com.wsopplan.entryCreated"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let range = self.activeRange else { return }
                await self.load(range: range)
            }
        }
    }

    // MARK: - Load

    public func load(range: TripDateRange) async {
        activeRange  = range
        isLoading    = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let entries  = try await entryRepo.fetchEntries(in: range)
            let snapshots = entries.map { EntrySnapshot.from($0) }
            // Exclude .registered — no meaningful data yet; Timeline shows the opportunity row
            sessions     = snapshots.filter { $0.status != .registered }.sorted { $0.startTime < $1.startTime }
            liveSessions  = snapshots.filter { $0.status == .playing || $0.status == .lateReg }
            cashedSessions = snapshots.filter { $0.isCash }
            summary      = buildSummary(from: snapshots)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Entry Actions

    /// Records a new entry for an opportunity. Reloads after write.
    public func recordEntry(
        opportunityID:      UUID,
        actualBuyinCents:   Int64? = nil,
        actualFeeCents:     Int64? = nil,
        usedTicket:         Bool   = false,
        hasBacking:         Bool   = false,
        selfActionPercent:  Double = 1.0,
        totalFieldSize:     Int?   = nil
    ) async {
        do {
            try await entryRepo.createEntry(
                opportunityID:     opportunityID,
                status:            .playing,
                actualStartTime:   nil,
                actualBuyinCents:  actualBuyinCents,
                actualFeeCents:    actualFeeCents,
                reEntryCount:      0,
                usedTicket:        usedTicket,
                hasBacking:        hasBacking,
                selfActionPercent: selfActionPercent,
                totalFieldSize:    totalFieldSize,
                notes:             nil
            )
            if let r = activeRange { await load(range: r) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Advances entry status to `.playing`.
    public func markPlaying(entryID: UUID) async {
        await updateStatus(.playing, entryID: entryID)
    }

    /// Records a re-entry (increments reEntryCount on the existing Entry).
    public func recordReEntry(entryID: UUID) async {
        do {
            let entry = try await entryRepo.fetchEntry(byID: entryID)
            guard let entry else { return }
            try await entryRepo.updateEntry(
                entryID:           entryID,
                status:            .playing,
                actualStartTime:   nil,
                actualEndTime:     nil,
                reEntryCount:      entry.reEntryCount + 1,
                startingChips:     nil,
                startingBigBlind:  nil,
                currentChips:      nil,
                currentBlindLevel: nil,
                endLevel:          nil,
                playersRemaining:  nil,
                notes:             nil
            )
            if let r = activeRange { await load(range: r) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Updates live chip-count tracking fields.
    public func updateLiveTracking(
        entryID:          UUID,
        currentChips:     Int?,
        blindLevel:       Int?,
        playersRemaining: Int?
    ) async {
        do {
            try await entryRepo.updateEntry(
                entryID:           entryID,
                status:            nil,
                actualStartTime:   nil,
                actualEndTime:     nil,
                reEntryCount:      nil,
                startingChips:     nil,
                startingBigBlind:  nil,
                currentChips:      currentChips,
                currentBlindLevel: blindLevel,
                endLevel:          nil,
                playersRemaining:  playersRemaining,
                notes:             nil
            )
            if let r = activeRange { await load(range: r) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Result Editor

    /// Opens the result entry sheet, pre-filling fields from any existing result.
    public func beginRecordingResult(entryID: UUID) {
        // Find matching snapshot to pre-fill if a result already exists
        let existing = sessions.first { $0.id == entryID }

        editingEntryID            = entryID
        editorFinishPosition      = existing?.finishPosition.map { "\($0)" } ?? ""
        editorTotalEntries        = existing?.totalEntries.map   { "\($0)" } ?? ""
        editorPlacesPaid          = existing?.placesPaid.map     { "\($0)" } ?? ""
        editorBubblesPaid         = ""
        editorIsBubble            = existing?.isBubble   ?? false
        editorIsChop              = existing?.isChop     ?? false
        editorChopNotes           = existing?.chopNotes  ?? ""
        editorEndLevel            = existing?.endLevel.map       { "\($0)" } ?? ""
        editorStartTime           = existing?.startTime
        editorEndTime             = existing?.endTime
        editorStartingChips       = existing?.startingChips.map  { "\($0)" } ?? ""
        editorReEntryCount        = existing.map { "\($0.reEntryCount)" } ?? ""
        editorPrizeDollars        = {
            guard let cents = existing?.prizeCents, cents > 0 else { return "" }
            return String(format: "%.0f", Double(cents) / 100.0)
        }()
        editorPrizeType           = {
            guard let snap = existing else { return .cash }
            if snap.prizeIsSeat { return .seat }
            return .cash
        }()
        editorBountyDollars       = ""
        editorNotes               = existing?.resultNotes ?? ""
        isResultEditorPresented   = true
    }

    /// Commits the result editor — records the result and updates entry status.
    public func commitResult() async {
        guard let entryID = editingEntryID else { return }

        let finishPos    = Int(editorFinishPosition)
        let totalEnt     = Int(editorTotalEntries)
        let placesPaid   = Int(editorPlacesPaid)
        let endLvl       = Int(editorEndLevel)
        let startChips   = Int(editorStartingChips)
        let reEntries    = Int(editorReEntryCount) ?? 0
        let prizeCents   = parseDollarsToCents(editorPrizeDollars)   // used for all prize types
        let bountyCents  = parseDollarsToCents(editorBountyDollars)
        let prizeIsSeat  = editorPrizeType == .seat
        let seatDesc: String? = editorPrizeType == .seat    ? "Tournament Seat"
                              : editorPrizeType == .package ? "Tournament Package"
                              : nil

        do {
            try await entryRepo.recordResult(
                entryID:                entryID,
                finishPosition:         finishPos,
                totalEntries:           totalEnt,
                prizeCents:             prizeCents,
                prizeIsSeat:            prizeIsSeat,
                seatPrizeDescription:   seatDesc,
                bountiesCollectedCents: bountyCents,
                placesPaid:             placesPaid,
                isBubble:               editorIsBubble,
                isChop:                 editorIsChop,
                chopNotes:              editorChopNotes.isEmpty ? nil : editorChopNotes,
                notes:                  editorNotes.isEmpty ? nil : editorNotes,
                tags:                   []
            )
            // Write entry-level fields (times, stack, endLevel)
            try await entryRepo.updateEntry(
                entryID:           entryID,
                status:            nil,
                actualStartTime:   editorStartTime,
                actualEndTime:     editorEndTime,
                reEntryCount:      reEntries,
                startingChips:     startChips,
                startingBigBlind:  nil,
                currentChips:      nil,
                currentBlindLevel: nil,
                endLevel:          endLvl,
                playersRemaining:  nil,
                notes:             nil
            )
            isResultEditorPresented = false
            if let r = activeRange { await load(range: r) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Payout Scanner

    /// Called when Vision/AI returns extracted text from a payout structure image.
    /// Parses lines like "1st: $50,000", "1-3: $25,000", "Bubble: $500", "Chop: $18,000"
    /// and pre-fills the relevant editor fields.
    public func applyScannedPayouts(_ text: String) {
        scannedPayoutText = text
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var highestPlace = 0
        for line in lines {
            let lower = line.lowercased()

            // Detect chop line: "chop" or "deal"
            if lower.contains("chop") || lower.contains("deal") {
                editorIsChop = true
                if let amt = extractDollars(from: line) {
                    editorPrizeDollars = formatDollars(amt)
                }
                editorChopNotes = line
                continue
            }

            // Detect bubble line
            if lower.contains("bubble") {
                editorIsBubble = true
                continue
            }

            // Extract place range: "1st", "2nd", "1-3", "10-15", etc.
            if let place = extractMaxPlace(from: line) {
                highestPlace = max(highestPlace, place)
            }
        }

        if highestPlace > 0 {
            editorPlacesPaid = "\(highestPlace)"
        }
    }

    private func extractMaxPlace(from line: String) -> Int? {
        // Match patterns: "1st", "2nd", "3", "10-15", "1-3"
        let patterns = [
            #"(\d+)\s*(?:st|nd|rd|th)?\s*[-–]\s*(\d+)"#,  // range: 1-3
            #"(\d+)\s*(?:st|nd|rd|th)"#,                    // ordinal: 1st
            #"^(\d+)\s*:"#                                   // bare: 1:
        ]
        for pat in patterns {
            if let match = line.range(of: pat, options: .regularExpression),
               let numRange = line[match].range(of: #"\d+"#, options: [.regularExpression, .backwards]),
               let n = Int(line[numRange]) {
                return n
            }
        }
        return nil
    }

    private func extractDollars(from line: String) -> Int64? {
        // Match $X,XXX or $X.XXX patterns
        guard let match = line.range(of: #"\$[\d,.]+"#, options: .regularExpression) else { return nil }
        let raw = line[match]
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let d = Decimal(string: raw) else { return nil }
        var input = d * 100
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, .plain)
        return (result as NSDecimalNumber).int64Value
    }

    private func formatDollars(_ cents: Int64) -> String {
        let dollars = Double(cents) / 100.0
        return String(format: "%.0f", dollars)
    }

    public func cancelResultEditor() {
        isResultEditorPresented = false
    }

    // MARK: - Delete

    public func deleteEntry(id: UUID) async {
        do {
            try await entryRepo.deleteEntry(id: id)
            if let r = activeRange { await load(range: r) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private Helpers

    private func updateStatus(_ status: EntryStatus, entryID: UUID) async {
        do {
            try await entryRepo.updateStatus(status, entryID: entryID)
            if let r = activeRange { await load(range: r) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildSummary(from snapshots: [EntrySnapshot]) -> ResultsSummary {
        let played        = snapshots
        let totalEntries  = played.count
        let totalBullets  = played.reduce(0) { $0 + $1.reEntryCount + 1 }
        let invested      = played.reduce(Int64(0)) { $0 + $1.totalInvestedCents }
        let prizes        = played.compactMap { $0.prizeCents }
        let totalPrize    = prizes.reduce(Int64(0), +)
        let netProfit     = played.reduce(Int64(0)) { $0 + ($1.netProfitCents ?? -$1.totalInvestedCents) }
        let cashes        = played.filter { $0.isCash }.count
        let cashRate      = totalEntries > 0 ? Double(cashes) / Double(totalEntries) : 0
        let avgInvest     = totalEntries > 0 ? invested / Int64(totalEntries) : 0
        let biggestCash   = prizes.max() ?? 0
        let live          = played.filter { $0.status == .playing || $0.status == .lateReg }

        return ResultsSummary(
            totalEntriesPlayed:  totalEntries,
            totalBulletsPlayed:  totalBullets,
            totalInvestedCents:  invested,
            totalPrizeCents:     totalPrize,
            netProfitCents:      netProfit,
            cashCount:           cashes,
            cashRate:            cashRate,
            avgInvestmentCents:  avgInvest,
            biggestCashCents:    biggestCash,
            liveEntryCount:      live.count
        )
    }

    private func parseDollarsToCents(_ s: String) -> Int64 {
        let stripped = s
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let d = Decimal(string: stripped) else { return 0 }
        var input  = d * 100
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, .plain)
        return (result as NSDecimalNumber).int64Value
    }
}
