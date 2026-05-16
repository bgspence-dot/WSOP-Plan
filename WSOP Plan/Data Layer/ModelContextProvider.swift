// ModelContextProvider.swift
// WSOPPlanData
//
// Owns the SwiftData ModelContainer and provides it to @ModelActor repositories.
// With @ModelActor, each repository actor owns its own ModelContext derived from
// the shared container — no manual context vending or .perform {} needed.

import Foundation
import SwiftData

// MARK: - RepositoryError

/// Errors surfaced by all repository operations.
public enum RepositoryError: Error, LocalizedError {
    /// The requested entity was not found.
    case notFound(String)
    /// An attempt was made to create a duplicate record where uniqueness is required.
    case duplicateEntry(String)
    /// A required relationship target was missing.
    case missingRelationship(String)
    /// A context save failed.
    case saveFailed(underlying: Error)
    /// A fetch predicate or descriptor was malformed.
    case invalidQuery(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let msg):            return "Not found: \(msg)"
        case .duplicateEntry(let msg):      return "Duplicate entry: \(msg)"
        case .missingRelationship(let msg): return "Missing relationship: \(msg)"
        case .saveFailed(let err):          return "Save failed: \(err.localizedDescription)"
        case .invalidQuery(let msg):        return "Invalid query: \(msg)"
        }
    }
}

// MARK: - ModelContextProvider

/// Owns the `ModelContainer` for the app.
///
/// Responsibilities:
/// - Initialise the SwiftData schema with all domain model types.
/// - Expose `container` so `DependencyContainer` can pass it to each `@ModelActor`
///   repository at construction time.
/// - Expose `mainContext` for SwiftUI `@Query` macros and environment injection.
///
/// `@ModelActor` repositories call `ModelActor(modelContainer:)` themselves and
/// maintain their own actor-isolated `ModelContext` — no manual context vending here.
public final class ModelContextProvider: @unchecked Sendable {

    // MARK: - Properties

    public let container: ModelContainer

    /// The main-actor context for SwiftUI observation.
    /// Use only for `@Query` and reading — never for direct writes.
    @MainActor
    public var mainContext: ModelContext { container.mainContext }

    // MARK: - Init

    /// - Parameters:
    ///   - inMemory: When `true`, uses an ephemeral in-memory store (tests / previews).
    ///   - url: Optional custom store URL. Defaults to the standard app-support location.
    public init(inMemory: Bool = false, url: URL? = nil) throws {
        let schema = Schema([
            Venue.self,
            Series.self,
            Tournament.self,
            Opportunity.self,
            PlanItem.self,
            Entry.self,
            Result.self
        ])

        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            config = ModelConfiguration(schema: schema, url: url)
        } else {
            config = ModelConfiguration(schema: schema)
        }

        self.container = try ModelContainer(for: schema, configurations: [config])
    }
}

// MARK: - Safe Save Helper

/// Saves `context` and wraps any error in `RepositoryError.saveFailed`.
///
/// Defined as a free function rather than a `ModelContext` extension because
/// `ModelContext` is `@MainActor`-isolated in SwiftData. An extension method would
/// inherit that isolation and cannot be called from a `@ModelActor` actor in Swift 6
/// strict concurrency mode. A free function has no implicit actor isolation, so it
/// is callable from any actor as long as the caller passes its own actor-isolated context.
nonisolated func contextSave(_ context: ModelContext) throws {
    do {
        try context.save()
    } catch {
        throw RepositoryError.saveFailed(underlying: error)
    }
}
