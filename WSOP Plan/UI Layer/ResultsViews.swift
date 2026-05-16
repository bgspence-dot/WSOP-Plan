// ResultsViews.swift
// WSOPPlanUI
//
// ResultsDashboardView — tournament performance stats + results list
// No cash game tracking — tournaments only.

import SwiftUI
import Vision

// MARK: - ResultPrizeType

/// The form of prize received — drives the prize picker in ResultEditorSheet.
public enum ResultPrizeType: String, CaseIterable, Hashable {
    case cash    = "cash"
    case seat    = "seat"
    case package = "package"
}

// MARK: - ResultsDashboardView

public struct ResultsDashboardView: View {

    let viewModel: ResultsViewModel

    public init(viewModel: ResultsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()

                if viewModel.isLoading {
                    LoadingOverlay()
                } else if viewModel.sessions.isEmpty {
                    emptyState
                } else {
                    List {
                        // Day-grouped results
                        ForEach(groupedByDay, id: \.date) { group in
                            daySection(group: group)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(AppColors.backgroundPrimary)
                }
            }
            .navigationTitle("Results")
            .navigationBarStyling()
            .safeAreaInset(edge: .top) {
                if let msg = viewModel.errorMessage {
                    ErrorBanner(message: msg) { }
                }
            }
            .sheet(isPresented: Binding(
                get: { viewModel.isResultEditorPresented },
                set: { viewModel.isResultEditorPresented = $0 }
            )) {
                ResultEditorSheet(viewModel: viewModel)
            }
        }
    }

    // MARK: - Grouping

    private var groupedByDay: [(date: Date, entries: [EntrySnapshot])] {
        let sorted = viewModel.sessions.sorted { $0.startTime > $1.startTime }
        var result: [(Date, [EntrySnapshot])] = []
        var current: (Date, [EntrySnapshot])? = nil
        for e in sorted {
            let day = Calendar.current.startOfDay(for: e.startTime)
            if current?.0 == day { current!.1.append(e) }
            else { if let p = current { result.append(p) }; current = (day, [e]) }
        }
        if let last = current { result.append(last) }
        return result.map { (date: $0.0, entries: $0.1) }
    }

    private func daySection(
        group: (date: Date, entries: [EntrySnapshot])
    ) -> some View {
        Group {
            // Slim date label — no header framing
            Text(group.date, style: .date)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppColors.textTertiary)
                .kerning(0.8)
                .padding(.leading, 16)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(group.entries) { session in
                ResultRow(
                    entry:  session,
                    onTap:  { viewModel.beginRecordingResult(entryID: session.id) },
                    onEdit: { viewModel.beginRecordingResult(entryID: session.id) }
                )
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "trophy")
                .font(.largeTitle)
                .foregroundStyle(AppColors.goldMuted)
                .padding(.top, 48)
            Text("No results recorded")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Tap Play on any tournament to record an entry.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ResultRow

private struct ResultRow: View {
    let entry:       EntrySnapshot
    let onTap:       () -> Void   // opens detail (if result exists) or editor (if live)
    let onEdit:      () -> Void   // always opens editor (pre-filled)

    var body: some View {
        VStack(spacing: 0) {
            // Tournament row
            TournamentRowShell(
                snapshot: OpportunitySnapshot(
                    id:             entry.opportunityID ?? entry.id,
                    date:           Calendar.current.startOfDay(for: entry.startTime),
                    startTime:      entry.startTime,
                    tournamentName: entry.tournamentName,
                    gameType:       entry.gameType,
                    buyinCents:     entry.totalInvestedCents,
                    venueName:      entry.venueName,
                    venueShortName: entry.venueName,
                    planIntent:     .play,
                    isPlayed:       true
                ),
                onTap: onTap
            )

            // Result data line
            if entry.hasResult || entry.status == .playing || entry.status == .lateReg {
                resultLine
                    .padding(.leading, 11)
                    .padding(.trailing, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .background(EntryStatus.playing.rowBackground)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(action: onEdit) {
                Label(entry.hasResult ? "Edit" : "Result", systemImage: "pencil.circle.fill")
            }
            .tint(AppColors.gold)
        }
    }

    @ViewBuilder
    private var resultLine: some View {
        HStack(spacing: 5) {
            resultStatusPill

            if let pos = entry.finishPosition {
                Text(ordinal(pos))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                if let total = entry.totalEntries {
                    Text("/ \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let paid = entry.placesPaid {
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text("\(paid) paid")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let lvl = entry.endLevel {
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text("L\(lvl)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if entry.reEntryCount > 0 {
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text("\(entry.reEntryCount)R")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if entry.isBubble { Text("Bubble").font(.caption.weight(.semibold)).foregroundStyle(AppColors.loss) }
            if entry.isChop   { Text("Chop").font(.caption.weight(.semibold)).foregroundStyle(AppColors.gold) }

            Spacer()

            if let prize = entry.prizeCents, prize > 0 {
                Text(MoneyAmount(cents: prize).compactDisplayString)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppColors.profit)
            } else if entry.prizeIsSeat {
                Text("Seat/Pkg")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColors.gold)
            } else if entry.status == .eliminated {
                Text(MoneyAmount(cents: -entry.totalInvestedCents).compactDisplayString)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(AppColors.loss)
            } else if entry.status == .playing || entry.status == .lateReg {
                Text("Live").font(.footnote.weight(.semibold)).foregroundStyle(AppColors.statusPlaying)
            }
        }
    }

    private var resultStatusPill: some View {
        let (label, color): (String, Color) = {
            switch entry.status {
            case .won:               return ("Won",       AppColors.statusCashed)
            case .cashed:            return ("Cashed",    AppColors.statusCashed)
            case .eliminated:        return ("Busted",    AppColors.statusEliminated)
            case .playing, .lateReg: return ("Live",      AppColors.statusPlaying)
            case .registered:        return ("Reg'd",    AppColors.statusRegistered)
            case .cancelled:         return ("Cancelled", AppColors.statusCancelled)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func ordinal(_ n: Int) -> String {
        let s: String
        switch n % 100 {
        case 11, 12, 13: s = "th"
        default:
            switch n % 10 {
            case 1: s = "st"; case 2: s = "nd"; case 3: s = "rd"; default: s = "th"
            }
        }
        return "\(n)\(s)"
    }
}

// MARK: - ResultEditorSheet

struct ResultEditorSheet: View {
    @Bindable var viewModel: ResultsViewModel
    @Environment(\.dismiss) private var dismiss

    /// Current entry being edited — used to render the tournament row at top.
    private var entry: EntrySnapshot? {
        viewModel.sessions.first { $0.id == viewModel.editingEntryID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()
                List {

                    // ── Tournament row ─────────────────────────────────────
                    if let e = entry {
                        TournamentRowShell(
                            snapshot: OpportunitySnapshot(
                                id:             e.opportunityID ?? e.id,
                                date:           Calendar.current.startOfDay(for: e.startTime),
                                startTime:      e.startTime,
                                tournamentName: e.tournamentName,
                                gameType:       e.gameType,
                                buyinCents:     e.totalInvestedCents,
                                venueName:      e.venueName,
                                venueShortName: e.venueName,
                                planIntent:     .play,
                                isPlayed:       true
                            ),
                            onTap: {}
                        )
                        .allowsHitTesting(false)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    Group {
                        LabeledField(label: "Starting Chips",     placeholder: "e.g. 25000", text: $viewModel.editorStartingChips,  keyboardType: .numberPad)
                        LabeledField(label: "Re-entries / Add-ons", placeholder: "0",         text: $viewModel.editorReEntryCount,   keyboardType: .numberPad)
                        OptionalDateRow(label: "Start Time",  date: $viewModel.editorStartTime)
                        OptionalDateRow(label: "End Time",    date: $viewModel.editorEndTime,
                                        onSet: { _ in
                                            if let start = viewModel.editorStartTime {
                                                viewModel.editorEndTime = start
                                            }
                                        })
                        LabeledField(label: "Finish Position",    placeholder: "e.g. 42",    text: $viewModel.editorFinishPosition, keyboardType: .numberPad)
                        LabeledField(label: "Total Entries",      placeholder: "e.g. 847",   text: $viewModel.editorTotalEntries,   keyboardType: .numberPad)
                        LabeledField(label: "End Level",          placeholder: "e.g. 18",    text: $viewModel.editorEndLevel,       keyboardType: .numberPad)
                        Toggle("Bubble (first out of money)", isOn: $viewModel.editorIsBubble)
                            .font(.footnote).foregroundStyle(.primary).tint(AppColors.loss)
                        LabeledField(label: "Places Paid",        placeholder: "e.g. 90",    text: $viewModel.editorPlacesPaid,     keyboardType: .numberPad)
                        LabeledField(label: "Bubble(s) Paid",     placeholder: "e.g. 2",     text: $viewModel.editorBubblesPaid,    keyboardType: .numberPad)
                        Toggle("Deal / Chop", isOn: $viewModel.editorIsChop)
                            .font(.footnote).foregroundStyle(.primary).tint(AppColors.gold)
                    }
                    .listRowBackground(AppColors.backgroundSurface)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))

                    if viewModel.editorIsChop {
                        TextField("Chop notes (e.g. 3-way even split)", text: $viewModel.editorChopNotes)
                            .font(.footnote).foregroundStyle(.secondary)
                            .listRowBackground(AppColors.backgroundSurface)
                            .listRowSeparator(.hidden)
                            .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }

                    Group {
                        Picker("Prize Type", selection: $viewModel.editorPrizeType) {
                            Text("Cash").tag(ResultPrizeType.cash)
                            Text("Seat").tag(ResultPrizeType.seat)
                            Text("Package").tag(ResultPrizeType.package)
                        }
                        .pickerStyle(.segmented)
                        LabeledField(label: "Prize ($)",    placeholder: "0", text: $viewModel.editorPrizeDollars,  keyboardType: .decimalPad)
                        LabeledField(label: "Bounties ($)", placeholder: "0", text: $viewModel.editorBountyDollars, keyboardType: .decimalPad)
                        Button {
                            viewModel.isPayoutScannerPresented = true
                        } label: {
                            Label("Scan Payout Sheet", systemImage: "camera.viewfinder")
                                .font(.footnote).foregroundStyle(AppColors.gold)
                        }
                        .buttonStyle(.plain)
                        TextField("Notes", text: $viewModel.editorNotes, axis: .vertical)
                            .font(.footnote).foregroundStyle(.primary).lineLimit(2...5)
                    }
                    .listRowBackground(AppColors.backgroundSurface)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .background(AppColors.backgroundPrimary)
                .sheet(isPresented: Binding(
                    get: { viewModel.isPayoutScannerPresented },
                    set: { viewModel.isPayoutScannerPresented = $0 }
                )) {
                    PayoutScannerSheet(viewModel: viewModel)
                }
            }
            .navigationTitle("Record Result")
            .navigationBarStyling()
            .toolbar {
                ToolbarItem(placement: .leadingAction) {
                    Button("Cancel") { viewModel.cancelResultEditor() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .trailingAction) {
                    Button("Save") { Task { await viewModel.commitResult() } }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppColors.gold)
                }
            }
        }
    }
}

// MARK: - PayoutScannerSheet

/// Camera/photo picker that uses VisionKit to OCR a payout structure image.
/// Extracted text is sent to the ViewModel which parses it into editor fields.
struct PayoutScannerSheet: View {
    @Bindable var viewModel: ResultsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedImage: UIImage? = nil
    @State private var isPickerPresented = false
    @State private var isCameraPresented = false
    @State private var extractedText: String = ""
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 20) {
                    // Preview
                    if let img = selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 16)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AppColors.backgroundSurface)
                            .frame(height: 200)
                            .overlay {
                                VStack(spacing: 10) {
                                    Image(systemName: "doc.text.viewfinder")
                                        .font(.largeTitle)
                                        .foregroundStyle(AppColors.goldMuted)
                                    Text("Take a photo of the payout sheet")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                    }

                    // Image source buttons
                    HStack(spacing: 12) {
                        ScanButton(icon: "camera.fill", label: "Camera") {
                            isCameraPresented = true
                        }
                        ScanButton(icon: "photo.on.rectangle", label: "Photo Library") {
                            isPickerPresented = true
                        }
                    }
                    .padding(.horizontal, 16)

                    // Extracted text preview
                    if !extractedText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("EXTRACTED TEXT")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .kerning(1.2)
                            ScrollView {
                                Text(extractedText)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        }
                        .padding(12)
                        .background(AppColors.backgroundSurface, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                    }

                    if isProcessing {
                        ProgressView("Reading payout sheet…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.top, 16)
            }
            .navigationTitle("Scan Payout Sheet")
            .navigationBarStyling()
            .toolbar {
                ToolbarItem(placement: .leadingAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .trailingAction) {
                    Button("Apply") {
                        viewModel.applyScannedPayouts(extractedText)
                        dismiss()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(extractedText.isEmpty ? Color.secondary : AppColors.gold)
                    .disabled(extractedText.isEmpty)
                }
            }
            .sheet(isPresented: $isCameraPresented) {
                ImagePickerView(sourceType: .camera, selectedImage: $selectedImage)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $isPickerPresented) {
                ImagePickerView(sourceType: .photoLibrary, selectedImage: $selectedImage)
                    .ignoresSafeArea()
            }
            .onChange(of: selectedImage) { _, img in
                guard let img else { return }
                isProcessing = true
                Task {
                    extractedText = await recognizeText(in: img)
                    isProcessing  = false
                }
            }
        }
    }

    /// Runs VisionKit text recognition on the provided image.
    private func recognizeText(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
}

private struct ScanButton: View {
    let icon:   String
    let label:  String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppColors.textInverse)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(AppColors.gold, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// UIKit photo picker bridge.
private struct ImagePickerView: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    @Binding var selectedImage: UIImage?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate   = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePickerView
        init(_ parent: ImagePickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.selectedImage = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

private struct LabeledField: View {
    let label:        String
    let placeholder:  String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer()
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .multilineTextAlignment(.trailing)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(AppColors.gold)
        }
    }
}

/// A row that shows a DatePicker when a value is present,
/// or a "Set" button when nil — keeps the form clean for optional times.
private struct OptionalDateRow: View {
    let label: String
    @Binding var date: Date?
    var onSet: ((Date) -> Void)? = nil

    var body: some View {
        if let d = date {
            HStack {
                DatePicker(label,
                           selection: Binding(get: { d }, set: { date = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .tint(AppColors.gold)
                Button {
                    date = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Set") {
                    let now = Date()
                    date = now
                    onSet?(now)
                }
                .font(.footnote)
                .foregroundStyle(AppColors.gold)
                .buttonStyle(.plain)
            }
        }
    }
}


