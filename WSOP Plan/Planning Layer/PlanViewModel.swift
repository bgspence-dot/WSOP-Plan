// PlanViewModel.swift
// WSOPPlanPlanning
//
// Drives PlanView. Exposes the user's current planned items for the trip window
// and delegates all writes to PlanItemService. No conflict logic — all actions
// are explicit and immediately reflected in the list.
//
// Dependencies: WSOPPlanDomain, WSOPPlanData protocols, PlanItemService

import Foundation

@Observable
@MainActor
public final class PlanViewModel {

    // MARK: - Published State

    /// Opportunity snapshots keyed by ID — used to render TournamentRowShell in PlanView.
    public private(set) var opportunitySnapshots: [UUID: OpportunitySnapshot] = [:]

    /// All plan items for the active trip range, grouped by day.
    public private(set) var dayGroups: [(date: Date, items: [PlanItemSnapshot])] = []

    /// Plan items filtered to a specific intent level (for "Definites" / "Likelies" sub-views).
    public private(set) var definiteItems:  [PlanItemSnapshot] = []
    public private(set) var likelyItems:    [PlanItemSnapshot] = []
    public private(set) var interestedItems:[PlanItemSnapshot] = []

    public private(set) var isLoading:    Bool    = false
    public private(set) var errorMessage: String? = nil

    // MARK: - Time Block Editor State
    // Bound to PlanItemEditorView sheet.

    public var editorTitle:      String = ""
    public var editorStartTime:  Date   = Date()
    public var editorEndTime:    Date?  = nil
    public var editorNotes:      String = ""
    public var editingItemID:    UUID?  = nil   // nil = creating new

    public var isEditorPresented: Bool = false

    // MARK: - Private

    private var allPlanItems: [PlanItemSnapshot] = []
    public private(set) var activeRange: TripDateRange?

    // MARK: - Dependencies

    private let planService:    PlanItemService
    private let planRepo:       any PlanRepositoryProtocol
    private let opportunityRepo:  any OpportunityRepositoryProtocol
    private let entryRepo:        any EntryRepositoryProtocol
    private let opportunityStore: OpportunityStore

    // MARK: - Init

    public init(
        planService:      PlanItemService,
        planRepo:         any PlanRepositoryProtocol,
        opportunityRepo:  any OpportunityRepositoryProtocol,
        entryRepo:        any EntryRepositoryProtocol,
        opportunityStore: OpportunityStore
    ) {
        self.planService      = planService
        self.planRepo         = planRepo
        self.opportunityRepo  = opportunityRepo
        self.entryRepo        = entryRepo
        self.opportunityStore = opportunityStore
    }

    // MARK: - Entry

    /// Creates a registered entry for an opportunity and marks it as playing.
    public func recordEntry(opportunityID: UUID) async {
        do {
            try await entryRepo.createEntry(
                opportunityID:     opportunityID,
                status:            .playing,
                actualStartTime:   nil,
                actualBuyinCents:  nil,
                actualFeeCents:    nil,
                reEntryCount:      0,
                usedTicket:        false,
                hasBacking:        false,
                selfActionPercent: 1.0,
                totalFieldSize:    nil,
                notes:             nil
            )
            opportunityStore.applyPlayed(true, forOpportunityID: opportunityID)
            NotificationCenter.default.post(name: .entryCreated, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Load

    public func load(range: TripDateRange) async {
        activeRange  = range
        isLoading    = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Fetch sequentially — concurrent @ModelActor fetches on the same
            // ModelContainer can SIGABRT in SwiftData's SQLite layer.
            let rawPlans = try await planRepo.fetchPlanItems(in: range)
            let rawOpps  = try await opportunityRepo.fetchOpportunities(in: range)

            // Build opportunity lookup — same join pattern as TimelineViewModel
            let planByOppID: [UUID: PlanItem] = Dictionary(
                rawPlans
                    .filter { $0.type == .tournamentIntent }
                    .compactMap { item -> (UUID, PlanItem)? in
                        guard let oid = item.opportunity?.id else { return nil }
                        return (oid, item)
                    },
                uniquingKeysWith: { a, b in
                    a.intent.sortWeight >= b.intent.sortWeight ? a : b
                }
            )

            // Build opportunity snapshots with intent applied
            opportunitySnapshots = Dictionary(
                uniqueKeysWithValues: rawOpps.map { opp in
                    (opp.id, OpportunitySnapshot.from(opp, planItem: planByOppID[opp.id]))
                }
            )

            allPlanItems = rawPlans.map { PlanItemSnapshot.from($0) }
            regroup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Intent Actions (called from row swipe/button)

    /// Sets intent for an opportunity. Reloads plan items after write.
    public func setIntent(_ intent: PlanIntent, forOpportunityID id: UUID) async {
        do {
            try await planService.setIntent(intent, forOpportunityID: id)
            if let range = activeRange { await load(range: range) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Cycles to the next intent level for the given opportunity.
    public func cycleIntent(current: PlanIntent, forOpportunityID id: UUID) async {
        do {
            try await planService.cycleIntent(current: current, forOpportunityID: id)
            if let range = activeRange { await load(range: range) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Time Block Actions

    /// Opens the editor sheet pre-filled for creating a new time block.
    public func beginCreatingTimeBlock(defaultStart: Date = Date()) {
        editingItemID   = nil
        editorTitle     = ""
        editorStartTime = defaultStart
        editorEndTime   = nil
        editorNotes     = ""
        isEditorPresented = true
    }

    /// Opens the editor sheet pre-filled for editing an existing time block.
    public func beginEditing(planItem: PlanItemSnapshot) {
        guard planItem.type == .timeBlock else { return }
        editingItemID     = planItem.id
        editorTitle       = planItem.title
        editorStartTime   = planItem.effectiveStartTime
        editorEndTime     = planItem.blockEnd
        editorNotes       = planItem.notes ?? ""
        isEditorPresented = true
    }

    /// Commits the editor — creates or updates the time block.
    public func commitEditor() async {
        guard !editorTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "A title is required for time blocks."
            return
        }
        do {
            if let id = editingItemID {
                try await planService.updateTimeBlock(
                    planItemID: id,
                    title:      editorTitle,
                    blockStart: editorStartTime,
                    blockEnd:   editorEndTime,
                    notes:      editorNotes.isEmpty ? nil : editorNotes
                )
            } else {
                try await planService.createTimeBlock(
                    title:      editorTitle,
                    blockStart: editorStartTime,
                    blockEnd:   editorEndTime,
                    notes:      editorNotes.isEmpty ? nil : editorNotes
                )
            }
            isEditorPresented = false
            if let range = activeRange { await load(range: range) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelEditor() {
        isEditorPresented = false
    }

    // MARK: - Delete

    public func deletePlanItem(id: UUID) async {
        do {
            try await planService.deletePlanItem(id: id)
            if let range = activeRange { await load(range: range) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private: Regroup

    private func regroup() {
        // Group by day
        var map: [(Date, [PlanItemSnapshot])] = []
        var current: (Date, [PlanItemSnapshot])? = nil

        let sorted = allPlanItems.sorted {
            $0.effectiveStartTime < $1.effectiveStartTime
        }

        for item in sorted {
            let day = Calendar.current.startOfDay(for: item.effectiveStartTime)
            if current?.0 == day {
                current!.1.append(item)
            } else {
                if let prev = current { map.append(prev) }
                current = (day, [item])
            }
        }
        if let last = current { map.append(last) }
        dayGroups = map.map { (date: $0.0, items: $0.1) }

        // Intent sub-lists
        let intentItems = allPlanItems.filter { $0.type == .tournamentIntent }
        definiteItems   = intentItems.filter { $0.intent == .definite }
        likelyItems     = intentItems.filter { $0.intent == .likely }
        interestedItems = intentItems.filter { $0.intent == .interested }
    }
}
