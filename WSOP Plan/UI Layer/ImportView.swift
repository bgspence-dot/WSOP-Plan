// ImportView.swift
// WSOPPlanUI
//
// Four-phase import sheet driven by ImportViewModel:
//
//   idle      → FilePicker  (DocumentGroup / fileImporter)
//   scanning  → Spinner
//   scanned   → ReviewScreen  (date range + venue checklist)
//   importing → ProgressLog
//   done      → SummaryScreen
//   failed    → ErrorScreen
//
// The ReviewScreen is the new piece: it shows the file's full date span,
// lets the user adopt it as their trip dates, and presents a venue checklist
// so they can deselect venues before committing the import.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - ImportView

public struct ImportView: View {

    @Bindable public var viewModel: ImportViewModel

    /// Called when the user taps "Use These Dates" — wires back to WSOPPlanApp's
    /// AppStorage trip timestamps via the DependencyContainer.
    public var onAdoptDateRange: ((TripDateRange) -> Void)? = nil

    /// Stored so the confirmed import can reuse the same URL.
    @State private var pickedURL: URL? = nil

    @Environment(\.dismiss) private var dismiss

    public init(
        viewModel: ImportViewModel,
        onAdoptDateRange: ((TripDateRange) -> Void)? = nil
    ) {
        self.viewModel       = viewModel
        self.onAdoptDateRange = onAdoptDateRange
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()
                phaseContent
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppColors.backgroundElevated, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarContent }
        }
        .fileImporter(
            isPresented: fileImporterBinding,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Navigation

    private var navigationTitle: String {
        switch viewModel.phase {
        case .idle:               return "Import Schedule"
        case .scanning:           return "Reading File…"
        case .scanned(let scan):  return scan.sourceLabel
        case .importing:          return "Importing…"
        case .done:               return "Import Complete"
        case .failed:             return "Import Failed"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                viewModel.reset()
                dismiss()
            }
            .foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: - Phase Routing

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .idle:
            IdleView()

        case .scanning(let label):
            ScanningView(sourceLabel: label)

        case .scanned(let scan):
            ReviewScreen(
                scan:           scan,
                viewModel:      viewModel,
                onImport: {
                    guard let url = pickedURL else { return }
                    // Pass the user's selected date range as tripDateRange
                    let dr = viewModel.selectedDateRange
                    viewModel.confirmImport(
                        url:           url,
                        tripDateRange: dr.map { (start: $0.start, end: $0.end) }
                    )
                },
                onAdoptDates: { range in
                    onAdoptDateRange?(range)
                }
            )

        case .importing(let lines):
            ProgressLogView(lines: lines)

        case .done(let result):
            DoneView(result: result, onDismiss: {
                viewModel.reset()
                dismiss()
            })

        case .failed(let message):
            ErrorView(message: message, onRetry: { viewModel.reset() })
        }
    }

    // MARK: - File Importer

    private var fileImporterBinding: Binding<Bool> {
        Binding(
            get: {
                if case .idle = viewModel.phase { return true }
                return false
            },
            set: { _ in }
        )
    }

    private func handleFileImport(_ result: Swift.Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            pickedURL = url
            // startAccess keeps the security-scoped entitlement alive across
            // both the pre-scan and the subsequent ingest. It is released by
            // the ViewModel after ingest finishes, or on reset/cancel.
            viewModel.startAccess(to: url)
            viewModel.beginPreScan(url: url)
        case .failure(let error):
            viewModel.setFailed(error.localizedDescription)
        }
    }
}

// MARK: - IdleView

private struct IdleView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.gold)
            Text("Choose a Schedule File")
                .font(.title3.bold())
                .foregroundStyle(AppColors.textPrimary)
            Text("CSV files exported from the WSOP or other\nmulti-venue schedule are supported.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - ScanningView

private struct ScanningView: View {
    let sourceLabel: String
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
                .tint(AppColors.gold)
            Text("Reading \(sourceLabel)…")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
        }
    }
}

// MARK: - ReviewScreen

/// The new pre-scan review screen. Shows:
///  • Schedule date span + "Use These Dates" button
///  • Per-venue checklist with event counts and date ranges
///  • Select All / Deselect All
///  • "Import Selected" CTA
private struct ReviewScreen: View {

    let scan:          SchedulePreScan
    @Bindable var viewModel: ImportViewModel
    let onImport:      () -> Void
    let onAdoptDates:  (TripDateRange) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Date Range Card ──────────────────────────────────
                dateRangeCard
                    .padding(.horizontal, 16)
                    .padding(.top, 20)

                // ── Summary Row ───────────────────────────────────────
                summaryRow
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                // ── Venue List ────────────────────────────────────────
                venueSection
                    .padding(.top, 20)

                // ── Import Button ─────────────────────────────────────
                importButton
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Date Range Card

    private var dateRangeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Schedule Date Range", systemImage: "calendar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textTertiary)
                .textCase(.uppercase)
                .kerning(0.8)

            if let range = scan.fullDateRange {
                HStack {
                    Text(range.displayString)
                        .font(.title3.bold())
                        .foregroundStyle(AppColors.textPrimary)

                    Spacer()

                    Button {
                        onAdoptDates(range)
                    } label: {
                        Label("Use These Dates", systemImage: "arrow.up.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.gold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AppColors.gold.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No dates found in file")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(14)
        .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.separator, lineWidth: 0.5)
        )
    }

    // MARK: Summary Row

    private var summaryRow: some View {
        HStack(spacing: 0) {
            statPill(value: "\(scan.tournamentCount)", label: "Tournaments")
            Divider()
                .frame(height: 28)
                .background(AppColors.separator)
                .padding(.horizontal, 12)
            statPill(value: "\(scan.opportunityCount)", label: "Start Times")
            if scan.normalizationErrorCount > 0 {
                Divider()
                    .frame(height: 28)
                    .background(AppColors.separator)
                    .padding(.horizontal, 12)
                statPill(
                    value: "\(scan.normalizationErrorCount)",
                    label: "Skipped",
                    valueColor: .orange
                )
            }
            Spacer()
        }
        .padding(12)
        .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppColors.separator, lineWidth: 0.5)
        )
    }

    private func statPill(
        value: String,
        label: String,
        valueColor: Color = AppColors.textPrimary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(valueColor)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: Venue Section

    private var venueSection: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header + select all / none
            HStack {
                Text("VENUES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
                    .kerning(1.2)
                    .padding(.leading, 20)

                Spacer()

                Button("All") { viewModel.selectAllVenues() }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppColors.gold)
                    .padding(.trailing, 8)

                Button("None") { viewModel.deselectAllVenues() }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.trailing, 20)
            }
            .padding(.bottom, 8)

            // Venue rows
            VStack(spacing: 0) {
                ForEach(scan.venues) { venue in
                    VenueRow(
                        venue:     venue,
                        isSelected: viewModel.venueSelection[venue.id] ?? true,
                        onToggle:  { viewModel.toggleVenue(id: venue.id) }
                    )
                    if venue.id != scan.venues.last?.id {
                        Divider()
                            .background(AppColors.separator)
                            .padding(.leading, 52)
                    }
                }
            }
            .background(AppColors.backgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.separator, lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
        }
    }

    // MARK: Import Button

    private var importButton: some View {
        Button(action: onImport) {
            HStack {
                Image(systemName: "square.and.arrow.down.fill")
                let count = viewModel.venueSelection.values.filter { $0 }.count
                Text(count == scan.venues.count
                     ? "Import All Venues"
                     : "Import \(count) Venue\(count == 1 ? "" : "s")")
            }
            .font(.headline)
            .foregroundStyle(viewModel.canImport ? .black : AppColors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                viewModel.canImport ? AppColors.gold : AppColors.backgroundElevated,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canImport)
        .animation(.easeInOut(duration: 0.15), value: viewModel.canImport)
    }
}

// MARK: - VenueRow

private struct VenueRow: View {
    let venue:      PreScannedVenue
    let isSelected: Bool
    let onToggle:   () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? AppColors.gold : AppColors.textTertiary,
                                lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppColors.gold)
                    }
                }
                .animation(.easeInOut(duration: 0.1), value: isSelected)

                // Venue info
                VStack(alignment: .leading, spacing: 3) {
                    Text(venue.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)

                    HStack(spacing: 6) {
                        Text("\(venue.eventCount) event\(venue.eventCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(AppColors.textTertiary)

                        if let range = venue.dateRange {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(AppColors.textTertiary)
                            Text(range.displayString)
                                .font(.caption)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ProgressLogView

private struct ProgressLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(lineColor(line))
                            .id(idx)
                    }
                }
                .padding(16)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.hasPrefix("✓") { return .green }
        if line.hasPrefix("⚠️") { return .orange }
        if line.hasPrefix("Venue:") { return AppColors.gold }
        return AppColors.textSecondary
    }
}

// MARK: - DoneView

private struct DoneView: View {
    let result:    IngestionResult
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: result.totalErrors == 0
                  ? "checkmark.circle.fill"
                  : "exclamationmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(result.totalErrors == 0 ? .green : .orange)

            Text(result.totalErrors == 0 ? "Import Complete" : "Import Finished with Warnings")
                .font(.title3.bold())
                .foregroundStyle(AppColors.textPrimary)

            // Stats grid
            VStack(spacing: 10) {
                statRow("Venues",       value: result.venuesUpserted)
                statRow("Tournaments",  value: result.tournamentsUpserted)
                statRow("Start Times",  value: result.opportunitiesUpserted)
                if result.totalErrors > 0 {
                    statRow("Errors", value: result.totalErrors, color: .orange)
                }
            }
            .padding(16)
            .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)

            Button("Done") { onDismiss() }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppColors.gold, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)

            Spacer()
        }
    }

    private func statRow(_ label: String, value: Int, color: Color = AppColors.textPrimary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
            Text("\(value)")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(color)
        }
        .font(.subheadline)
    }
}

// MARK: - ErrorView

private struct ErrorView: View {
    let message:  String
    let onRetry:  () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Could Not Read File")
                .font(.title3.bold())
                .foregroundStyle(AppColors.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") { onRetry() }
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(AppColors.gold, in: RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
    }
}
