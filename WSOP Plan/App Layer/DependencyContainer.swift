// DependencyContainer.swift
// WSOPPlanApp
//
// Composition root. Creates and owns every long-lived object in the app:
// - ModelContextProvider (SwiftData container)
// - All four @ModelActor repositories
// - All Planning services
// - All ViewModels
// - IngestionPipeline
//
// Nothing else in the app creates these objects. All dependencies flow
// downward from this single point of construction.
//
// Dependencies: all modules

import Foundation
import SwiftData

// MARK: - DependencyContainer

/// The app's single composition root.
///
/// Instantiated once in `WSOPPlanApp` and injected into the SwiftUI
/// environment. Views retrieve their pre-built ViewModels from here
/// rather than constructing them independently.
@MainActor
@Observable
public final class DependencyContainer {

    // MARK: - SwiftData

    /// The shared model container. Exposed so SwiftUI views can inject
    /// it via `.modelContainer(container.modelContainer)` for `@Query`.
    public let modelContextProvider: ModelContextProvider

    // MARK: - Repositories (protocol types — UI never sees concrete actors)

    public let tournamentRepo:    any TournamentRepositoryProtocol
    public let opportunityRepo:   any OpportunityRepositoryProtocol
    public let opportunityStore:  OpportunityStore
    public let planRepo:        any PlanRepositoryProtocol
    public let entryRepo:       any EntryRepositoryProtocol

    // MARK: - Ingestion

    public let ingestionPipeline: IngestionPipeline

    // MARK: - Planning Services

    public let planItemService: PlanItemService

    // MARK: - ViewModels
    // One instance per tab — created eagerly so state survives tab switches.

    public let timelineViewModel: TimelineViewModel
    public let exploreViewModel:  ExploreViewModel
    public let planViewModel:     PlanViewModel
    public let resultsViewModel:  ResultsViewModel
    public let importViewModel:   ImportViewModel

    // MARK: - Init

    /// Creates the full object graph.
    ///
    /// - Parameter inMemory: When `true` uses an ephemeral store.
    ///   Pass `true` for SwiftUI previews and unit tests.
    public init(inMemory: Bool = false) throws {

        // 1. SwiftData container
        let provider = try ModelContextProvider(inMemory: inMemory)
        self.modelContextProvider = provider

        // 2. Repositories — @ModelActor synthesises init(modelContainer:)
        let tRepo  = TournamentRepository(modelContainer:  provider.container)
        let oRepo  = OpportunityRepository(modelContainer: provider.container)
        let pRepo  = PlanRepository(modelContainer:        provider.container)
        let eRepo  = EntryRepository(modelContainer:       provider.container)

        self.tournamentRepo  = tRepo
        self.opportunityRepo = oRepo
        self.planRepo        = pRepo
        self.entryRepo       = eRepo

        // Shared opportunity store — single source of truth for all ViewModels
        let store = OpportunityStore(opportunityRepo: oRepo, planRepo: pRepo)
        self.opportunityStore = store

        // 3. Ingestion pipeline
        self.ingestionPipeline = IngestionPipeline(
            tournamentRepo:  tRepo,
            opportunityRepo: oRepo
        )

        // 4. Planning services
        let planSvc = PlanItemService(planRepo: pRepo)
        self.planItemService = planSvc

        // 5. ViewModels
        self.timelineViewModel = TimelineViewModel(
            opportunityRepo:  oRepo,
            planRepo:         pRepo,
            entryRepo:        eRepo,
            planItemService:  planSvc,
            opportunityStore: store
        )

        self.exploreViewModel = ExploreViewModel(
            opportunityRepo:  oRepo,
            tournamentRepo:   tRepo,
            planRepo:         pRepo,
            planItemService:  planSvc,
            entryRepo:        eRepo,
            opportunityStore: store
        )

        self.planViewModel = PlanViewModel(
            planService:      planSvc,
            planRepo:         pRepo,
            opportunityRepo:  oRepo,
            entryRepo:        eRepo,
            opportunityStore: store
        )

        self.resultsViewModel = ResultsViewModel(
            entryRepo: eRepo
        )

        self.importViewModel = ImportViewModel(
            pipeline: ingestionPipeline
        )
    }

    // MARK: - Convenience factory for previews

    /// A container backed by an in-memory store, pre-populated with
    /// sample data. Use in SwiftUI `#Preview` blocks.
    public static func preview() -> DependencyContainer {
        (try? DependencyContainer(inMemory: true)) ?? {
            fatalError("Failed to create preview DependencyContainer")
        }()
    }
}

// MARK: - Environment Key

import SwiftUI

private struct DependencyContainerKey: EnvironmentKey {
    // Default is a fatalError sentinel — the real container is always
    // injected at the app root before any view reads it.
    static let defaultValue: DependencyContainer? = nil
}

extension EnvironmentValues {
    public var dependencyContainer: DependencyContainer? {
        get { self[DependencyContainerKey.self] }
        set { self[DependencyContainerKey.self] = newValue }
    }
}

extension View {
    /// Injects the dependency container into the SwiftUI environment.
    public func withDependencies(_ container: DependencyContainer) -> some View {
        environment(\.dependencyContainer, container)
    }
}
