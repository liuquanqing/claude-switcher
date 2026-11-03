import AppKit
import SwiftUI
import SwitcherCore

private enum SessionTransferSheet: Identifiable {
    case confirmation(SessionTransferConfirmation)
    case backup
    case handoff

    var id: String {
        switch self {
        case .confirmation(let confirmation): return confirmation.id.uuidString
        case .backup: return "backup"
        case .handoff: return "handoff"
        }
    }
}

private extension Color {
    /// Primary action fill: white label on it is ~5.5:1; against the window background it is ~3.1:1 (non-text).
    static let importAccent = Color(hex: 0x0A64D6)
    /// Lighter blue for tints and small accent text on dark surfaces (~7:1 on Color.bg). Native checkboxes
    /// render tint darker in dark appearance, so this starts brighter than the button fill.
    static let importAccentSoft = Color(hex: 0x5AA2FF)
}

/// Solid blue primary action with white label; the destructive variant keeps the system-red-like `.bad`
/// with a dark label (white on it is only ~3.4:1). Disabled drops to a neutral raised surface so it stays
/// visible but no longer looks clickable.
private struct ImportProminentButtonStyle: ButtonStyle {
    var tint: Color = .importAccent
    var label: Color = .white
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isEnabled ? label : Color.sub)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isEnabled ? tint : Color.cardHi)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(isEnabled && configuration.isPressed ? 0.18 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isEnabled ? Color.white.opacity(0.10) : Color.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor
private struct MixedSelectionCheckbox: NSViewRepresentable {
    let title: String
    let state: NSControl.StateValue
    let isEnabled: Bool
    let help: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.allowsMixedState = true
        button.contentTintColor = NSColor(Color.importAccentSoft)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(Color.sub)
        ])
        button.state = state
        button.isEnabled = isEnabled
        button.toolTip = help
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func toggle(_ sender: NSButton) {
            action()
        }
    }
}

@MainActor
struct CopyThreadsView: View {
    @ObservedObject private var controller: SessionTransferController
    @FocusState private var modalCancelFocused: Bool
    @State private var handoffCopied = false
    @State private var instructionsCopied = false
    @State private var instructionCopySequence = 0
    @State private var showingScopeHelp = false
    private let store: Store

    init(store: Store) {
        self.store = store
        self.controller = CopyWindow.controller(for: store)
    }

    init(store: Store, controller: SessionTransferController) {
        self.store = store
        self.controller = controller
    }

    private var selectableVisibleRows: [SessionTransferRow] {
        controller.visibleRows.filter(\.selectable)
    }

    private var visiblePickedCount: Int {
        selectableVisibleRows.filter { controller.picked.contains($0.id) }.count
    }

    private var visibleSelectionState: NSControl.StateValue {
        guard !selectableVisibleRows.isEmpty, visiblePickedCount > 0 else { return .off }
        return visiblePickedCount == selectableVisibleRows.count ? .on : .mixed
    }

    private var canSwapDirection: Bool {
        !controller.isWorking && !controller.sourceID.isEmpty && !controller.targetID.isEmpty &&
            controller.sourceID != controller.targetID
    }

    private var directionLabelWidth: CGFloat {
        controller.language == "en" ? 72 : 48
    }

    private var selectedSummary: String {
        let plannedRows = controller.rows.filter { row in
            controller.picked.contains(row.id) &&
                (row.kind == .add || (row.kind == .update && controller.updateExisting))
        }
        let added = plannedRows.filter { $0.kind == .add }.count
        let updated = plannedRows.filter { $0.kind == .update }.count
        let visibleIDs = Set(controller.visibleRows.map(\.id))
        let outsideCount = plannedRows.filter { !visibleIDs.contains($0.id) }.count
        let arguments = [
            "selected": String(plannedRows.count),
            "added": String(added),
            "updated": String(updated)
        ]
        let key = updated > 0 ? (added > 0 ? "selectedChanges" : "selectedUpdates") : "selectedCount"
        let summary = text(key, arguments: arguments)
        guard outsideCount > 0 else { return summary }
        return text("selectedOutside", arguments: [
            "summary": summary,
            "outside": String(outsideCount)
        ])
    }

    private var missingSelectionPrompt: String? {
        if controller.sourceID.isEmpty || controller.targetID.isEmpty {
            if controller.sourceID.isEmpty && controller.targetID.isEmpty {
                return text("chooseSourceAndTargetPrompt")
            }
            return text(controller.sourceID.isEmpty ? "chooseSourcePrompt" : "chooseTargetPrompt")
        }
        let sourceSpaceMissing = controller.sourceSpaceID.isEmpty
        let targetSpaceMissing = controller.targetSpaceID.isEmpty
        guard sourceSpaceMissing || targetSpaceMissing else { return nil }
        if (sourceSpaceMissing && controller.sourceSpaces.isEmpty) ||
            (targetSpaceMissing && controller.targetSpaces.isEmpty) {
            return text("statusOpenCode")
        }
        if sourceSpaceMissing && targetSpaceMissing {
            return text("chooseSpacesPrompt")
        }
        return text(sourceSpaceMissing ? "chooseSourceSpacePrompt" : "chooseTargetSpacePrompt")
    }

    private var visibleStatusMessage: String? {
        guard let status = controller.statusMessage else { return nil }
        if status.hasPrefix("已复制") { return nil }
        if status.hasPrefix("已保留当前数据并结束记录") { return text("preservedStatus") }
        switch status {
        case "已撤销上次复制。": return text("undone")
        case "已恢复上次未完成的变更。": return text("restored")
        case "选择或空间已变化，请重新复制。": return text("statusSelectionChanged")
        case "请先在相应账号或 API 工作区打开 Code 页，再重新检查。": return text("statusOpenCode")
        case "请选择不同的来源和目标空间。": return text("statusDifferentSpaces")
        default: return generated(status)
        }
    }

    private var activeSheet: SessionTransferSheet? {
        if let confirmation = controller.confirmation { return .confirmation(confirmation) }
        if controller.backupInformation != nil { return .backup }
        if controller.handoffInformation != nil { return .handoff }
        return nil
    }

    private var sheetBinding: Binding<SessionTransferSheet?> {
        Binding(get: { activeSheet }, set: { newValue in
            guard newValue == nil, let sheet = activeSheet else { return }
            switch sheet {
            case .confirmation: controller.dismissConfirmation()
            case .backup: controller.dismissBackup()
            case .handoff: controller.dismissHandoff()
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.isShowingCopyResult {
                if let operation = controller.lastOperation, operation.state == .completed {
                    completionSummary(operation)
                }
            } else {
                navigationBar
                directionEditor
                scopeLabel
            }

            if !controller.isShowingCopyResult, let prompt = missingSelectionPrompt {
                if let error = controller.errorMessage {
                    message(generated(error), color: .bad)
                }
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundColor(.sub)
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            } else {
                if let error = controller.errorMessage {
                    message(generated(error), color: .bad)
                } else if let status = visibleStatusMessage {
                    message(status, color: .sub)
                }
                searchAndUpdate
                if !controller.isShowingCopyResult {
                    selectionToolbar
                }
                sessionList
            }

            if let operation = controller.lastOperation {
                if operation.needsRecovery {
                    recoveryRecordView(operation)
                } else if !controller.isShowingCopyResult {
                    recentRecordView(operation)
                }
            }

            bottomBar
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .task { await controller.refresh() }
        .sheet(item: sheetBinding) { sheet in
            sheetContent(sheet)
        }
        .onChange(of: controller.language) { language in
            CopyWindow.updateTitle(store: store, language: language)
        }
        .onChange(of: controller.handoffInformation) { _ in
            handoffCopied = false
        }
    }

    private var navigationBar: some View {
        HStack {
            Button { CopyWindow.returnToAccounts(store) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text(text("back"))
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.link)
            .foregroundColor(.sub)
            .help(text("backHelp"))
            Spacer()
            Button(text(instructionsCopied ? "copiedInstructions" : "copyForClaude")) {
                copyInstructions()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .foregroundColor(.sub)
            .fixedSize()
            .disabled(!controller.canExport || controller.isWorking)
        }
    }

    private var directionEditor: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(text("from"))
                        .frame(width: directionLabelWidth, alignment: .leading)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.sub)
                    picker(text("from"), selection: sourceBinding, options: controller.locations)
                        .labelsHidden()
                    if !controller.sourceID.isEmpty && controller.sourceID == controller.currentEndpointID {
                        Text(text("currentAccount"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.importAccentSoft)
                    }
                }
                if controller.sourceSpaces.count > 1 {
                    HStack(spacing: 6) {
                        Text(text("sourceSpace"))
                            .frame(width: directionLabelWidth, alignment: .leading)
                            .font(.system(size: 11))
                            .foregroundColor(.sub)
                        spacePicker(text("sourceSpace"), selection: sourceSpaceBinding, options: controller.sourceSpaces)
                    }
                }
            }
            Button { controller.swapDirection() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundColor(.sub)
            .padding(.top, 2)
            .help(text("swapDirection"))
            .accessibilityLabel(Text(text("swapDirection")))
            .disabled(!canSwapDirection)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(text("to"))
                        .frame(width: directionLabelWidth, alignment: .leading)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.sub)
                    picker(text("to"), selection: targetBinding, options: controller.locations, placeholder: text("chooseTarget"))
                        .labelsHidden()
                    if !controller.targetID.isEmpty && controller.targetID == controller.currentEndpointID {
                        Text(text("currentAccount"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.importAccentSoft)
                    }
                }
                if controller.targetSpaces.count > 1 {
                    HStack(spacing: 6) {
                        Text(text("targetSpace"))
                            .frame(width: directionLabelWidth, alignment: .leading)
                            .font(.system(size: 11))
                            .foregroundColor(.sub)
                        spacePicker(text("targetSpace"), selection: targetSpaceBinding, options: controller.targetSpaces)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var scopeLabel: some View {
        HStack(spacing: 5) {
            Text(text("copyScopeLabel"))
                .font(.system(size: 11))
                .foregroundColor(.sub)
            Button { showingScopeHelp.toggle() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundColor(.sub)
            .accessibilityLabel(Text(text("copyScopeAccessibility")))
            .popover(isPresented: $showingScopeHelp, arrowEdge: .bottom) {
                Text(text("copyScopeHelp"))
                    .font(.system(size: 11))
                    .foregroundColor(.txt)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 340)
                    .background(Color.bg)
            }
            Spacer()
        }
    }

    private var searchAndUpdate: some View {
        HStack(spacing: 12) {
            TextField(text("search"), text: $controller.query)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isWorking)
            if !controller.isShowingCopyResult {
                Toggle(text("updateExisting"), isOn: updateBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .tint(.importAccentSoft)
                    .disabled(controller.isWorking)
                    .help(text("updateHelp"))
            }
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 7) {
            MixedSelectionCheckbox(
                title: text("selectCopyable"),
                state: visibleSelectionState,
                isEnabled: !selectableVisibleRows.isEmpty && !controller.isWorking,
                help: text("selectCopyableHelp"),
                action: controller.selectAllVisible
            )
            .frame(height: 22)
            FooterButton(icon: "arrow.clockwise", help: text("refreshHelp")) {
                Task { await controller.refresh() }
            }
            .disabled(controller.isWorking)
            Spacer(minLength: 8)
            Text(selectedSummary)
                .font(.system(size: 12))
                .foregroundColor(.sub)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(selectedSummary)
        }
    }

    private var sessionList: some View {
        List(controller.visibleRows) { row in
            sessionRow(row)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 180)
        .layoutPriority(1)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.card.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.stroke.opacity(0.75), lineWidth: 1))
        .overlay {
            if controller.visibleRows.isEmpty {
                Text(emptyListMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.sub)
            }
        }
    }

    private func sessionRow(_ row: SessionTransferRow) -> some View {
        let result = controller.isShowingCopyResult ? controller.resultItem(for: row) : nil
        let title = result?.title ?? row.title
        let path = result?.cwd ?? row.cwd
        let isPicked = !controller.isShowingCopyResult && controller.picked.contains(row.id)
        let showsOriginalTitle = result.map { $0.title != row.title } ?? false
        return HStack(alignment: .top, spacing: 10) {
            if !controller.isShowingCopyResult {
                Toggle("", isOn: pickedBinding(row))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .tint(.importAccentSoft)
                    .disabled(!row.selectable || controller.isWorking)
                    .accessibilityLabel(Text(row.title))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.txt)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                if showsOriginalTitle {
                    Text(text("originalTitle", arguments: ["title": row.title]))
                        .font(.system(size: 11))
                        .foregroundColor(.sub)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.title)
                }
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.sub)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                if shouldShowReason(row) {
                    Text(generated(row.reason))
                        .font(.system(size: 11))
                        .foregroundColor(Color.txt.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(generated(row.reason))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(activityTime(row.lastActivity))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.sub)
                    .frame(width: 66, alignment: .trailing)
                Text(rowStatus(row, result: result))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(rowStatusColor(row, result: result))
                    .lineLimit(1)
                    .frame(width: 88, alignment: .trailing)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(isPicked ? Color.importAccent.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityHint(generated(row.reason))
        .onTapGesture {
            guard !controller.isShowingCopyResult, row.selectable, !controller.isWorking else { return }
            controller.setPicked(row.id, selected: !controller.picked.contains(row.id))
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptyListMessage: String {
        if controller.errorMessage != nil { return text("rowsUnavailable") }
        if controller.isShowingCopyResult || !controller.query.isEmpty {
            return text(controller.query.isEmpty ? "noRows" : "noMatches")
        }
        return text(controller.rows.isEmpty ? "noRows" : "noMatches")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if controller.isShowingCopyResult {
                Button(text("continueCopy")) { controller.beginAnotherCopy() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .foregroundColor(.sub)
                    .disabled(controller.isWorking)
                Spacer()
                Button(text("back")) { CopyWindow.returnToAccounts(store) }
                    .buttonStyle(ImportProminentButtonStyle())
                    .fixedSize()
                    .disabled(controller.isWorking)
            } else {
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                    Text(text("processing"))
                        .font(.system(size: 12))
                        .foregroundColor(.importAccentSoft)
                }
                Spacer(minLength: 4)
                Button(text("copy")) {
                    Task { await controller.copySelected() }
                }
                .buttonStyle(ImportProminentButtonStyle())
                .fixedSize()
                .disabled(!controller.canCopy || controller.isWorking)
            }
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(get: { controller.sourceID }, set: { controller.setSource($0) })
    }

    private var targetBinding: Binding<String> {
        Binding(get: { controller.targetID }, set: { controller.setTarget($0) })
    }

    private var sourceSpaceBinding: Binding<String> {
        Binding(get: { controller.sourceSpaceID }, set: { controller.setSourceSpace($0) })
    }

    private var targetSpaceBinding: Binding<String> {
        Binding(get: { controller.targetSpaceID }, set: { controller.setTargetSpace($0) })
    }

    private var updateBinding: Binding<Bool> {
        Binding(get: { controller.updateExisting }, set: { controller.setUpdates($0) })
    }

    private func pickedBinding(_ row: SessionTransferRow) -> Binding<Bool> {
        Binding(get: { controller.picked.contains(row.id) },
                set: { controller.setPicked(row.id, selected: $0) })
    }

    private func copyInstructions() {
        instructionCopySequence += 1
        let sequence = instructionCopySequence
        instructionsCopied = false
        Task {
            guard let instructions = await controller.generateInstructions(),
                  !instructions.isEmpty,
                  sequence == instructionCopySequence else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let localized = SessionTransferLocalization.instructions(instructions, language: controller.language)
            guard pasteboard.setString(localized, forType: .string),
                  sequence == instructionCopySequence else { return }
            instructionsCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard sequence == instructionCopySequence else { return }
                instructionsCopied = false
            }
        }
    }

    private func text(_ key: String, arguments: [String: String] = [:]) -> String {
        SessionTransferLocalization.text(key, language: controller.language, arguments: arguments)
    }

    private func generated(_ value: String) -> String {
        SessionTransferLocalization.message(value, language: controller.language)
    }

    private func picker(_ label: String, selection: Binding<String>, options: [TransferLocationOption], placeholder: String? = nil) -> some View {
        let selectedName = options.first { $0.id == selection.wrappedValue }.map {
            $0.id == "api" ? text("apiWorkspace") : $0.name
        } ?? placeholder ?? label
        return Picker(label, selection: selection) {
            if let placeholder {
                Text(placeholder).tag("")
            }
            ForEach(options) { option in
                Text(option.id == "api" ? text("apiWorkspace") : option.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tag(option.id)
            }
        }
        .frame(width: 170)
        .disabled(controller.isWorking)
        .help(selectedName)
    }

    private func spacePicker(_ label: String, selection: Binding<String>, options: [TransferSpaceOption]) -> some View {
        let selectedName = options.first { $0.id == selection.wrappedValue }.map {
            SessionTransferLocalization.spaceName($0.name, language: controller.language)
        } ?? text("chooseSpace")
        return Picker(label, selection: selection) {
            Text(text("chooseSpace")).tag("")
            ForEach(options) { option in
                Text(SessionTransferLocalization.spaceName(option.name, language: controller.language))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tag(option.id)
            }
        }
        .labelsHidden()
        .frame(width: 170)
        .disabled(controller.isWorking)
        .help(selectedName)
    }

    private func message(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundColor(color)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(value)
    }

    private func skipStatus(_ row: SessionTransferRow) -> String? {
        switch row.reason {
        case "目标已同步，无需重复复制。": return text("skipSynced")
        case "目标进度较新，保留目标。": return text("skipTargetNewer")
        case "目标已有这段会话；开启更新后可同步列表进度。": return text("skipUpdatesDisabled")
        case "目标已有同一会话，保留目标条目。": return text("skipExisting")
        default: return nil
        }
    }

    private func shouldShowReason(_ row: SessionTransferRow) -> Bool {
        guard !row.reason.isEmpty else { return false }
        return row.kind == .blocked || (row.kind == .skip && skipStatus(row) == nil)
    }

    private func rowStatus(_ row: SessionTransferRow, result: TransferSessionItem?) -> String {
        if let result {
            switch result.kind {
            case .add: return text("resultAdded")
            case .update: return text("resultUpdated")
            case .skip, .blocked: return text("notCopied")
            }
        }
        if controller.isShowingCopyResult {
            switch row.kind {
            case .add, .update: return text("notCopied")
            case .skip: return skipStatus(row) ?? text("notCopied")
            case .blocked: return text("needsReview")
            }
        }
        switch row.kind {
        case .add: return text("willAdd")
        case .update: return text("willUpdate")
        case .skip: return skipStatus(row) ?? text("skipRetained")
        case .blocked: return text("needsReview")
        }
    }

    private func rowStatusColor(_ row: SessionTransferRow, result: TransferSessionItem?) -> Color {
        if let result {
            switch result.kind {
            case .add, .update: return .good
            case .skip, .blocked: return .warn
            }
        }
        if row.kind == .blocked { return .warn }
        if controller.isShowingCopyResult { return .sub }
        return row.kind == .add || row.kind == .update ? .importAccentSoft : .sub
    }

    private func activityTime(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 60 { return text("justNow") }
        if seconds < 3600 { return text("minutesAgo", arguments: ["count": String(seconds / 60)]) }
        if seconds < 86400 { return text("hoursAgo", arguments: ["count": String(seconds / 3600)]) }
        return text("daysAgo", arguments: ["count": String(seconds / 86400)])
    }

    private func operationContent(_ operation: SessionTransferOperation) -> (title: String, summary: String, color: Color) {
        let items = operation.items
        switch operation.state {
        case .completed:
            let addedCount = items.filter { $0.kind == .add }.count
            let updatedCount = items.filter { $0.kind == .update }.count
            if addedCount > 0 && updatedCount > 0 {
                return (text("copyCompleted"), text("copiedMixed", arguments: [
                    "target": operation.targetName,
                    "added": String(addedCount),
                    "updated": String(updatedCount)
                ]), .good)
            }
            if addedCount > 0 {
                let key = addedCount == 1 ? "copiedAddedOne" : "copiedAddedMany"
                return (text("copyCompleted"), text(key, arguments: [
                    "target": operation.targetName,
                    "count": String(addedCount)
                ]), .good)
            }
            if updatedCount > 0 {
                let key = updatedCount == 1 ? "copiedUpdatedOne" : "copiedUpdatedMany"
                return (text("copyCompleted"), text(key, arguments: [
                    "target": operation.targetName,
                    "count": String(updatedCount)
                ]), .good)
            }
            return (text("copyCompleted"), generated(operation.summary), .good)
        case .undone:
            return (text("undone"), text("undoneSummary", arguments: ["count": String(items.count)]), .good)
        case .restored:
            return (text("restored"), text("restoredSummary"), .good)
        case .preserved:
            if operation.summary.contains("备份缺失或无法核对") {
                return (text("preserved"), generated(operation.summary), .warn)
            }
            return (text("preserved"), text("preservedSummary"), .warn)
        case .copying, .restoring, .recoveryRequired:
            return (text("recoveryRequired"), text("recoverySummary"), .bad)
        @unknown default:
            return (generated(operation.title), generated(operation.summary), .sub)
        }
    }

    private func completionSummary(_ operation: SessionTransferOperation) -> some View {
        let content = operationContent(operation)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.good)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(content.summary)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.txt)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .help(content.summary)
            Button(text("viewBackup")) { controller.showBackup() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .foregroundColor(.sub)
                .fixedSize()
                .disabled(controller.isWorking)
            if operation.canUndo {
                Button(text("undo")) { controller.requestUndo() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .foregroundColor(.sub)
                    .fixedSize()
                    .disabled(controller.isWorking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentRecordView(_ operation: SessionTransferOperation) -> some View {
        let content = operationContent(operation)
        return HStack(spacing: 12) {
            Button(text("recentOperation")) { controller.showBackup() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .foregroundColor(.sub)
                .help(content.title + "\n" + content.summary)
                .disabled(controller.isWorking)
            if operation.canUndo {
                Button(text("undo")) { controller.requestUndo() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .foregroundColor(.sub)
                    .disabled(controller.isWorking)
            }
            Spacer()
        }
    }

    private func recoveryRecordView(_ operation: SessionTransferOperation) -> some View {
        let content = operationContent(operation)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(content.color)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(content.color)
                Text(content.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.sub)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(content.summary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button(text("viewBackup")) { controller.showBackup() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .foregroundColor(.sub)
                .fixedSize()
                .disabled(controller.isWorking)
            Button(text("recover")) { controller.requestRecovery() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .foregroundColor(.sub)
                .fixedSize()
                .disabled(controller.isWorking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sheetContent(_ sheet: SessionTransferSheet) -> some View {
        Group {
            switch sheet {
            case .confirmation(let confirmation): confirmationSheet(confirmation)
            case .backup: backupSheet()
            case .handoff: handoffSheet()
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .onAppear { modalCancelFocused = true }
        .onDisappear { modalCancelFocused = false }
    }

    private func confirmationCopy(_ confirmation: SessionTransferConfirmation) -> (title: String, message: String, button: String, items: [TransferSessionItem]) {
        switch confirmation.kind {
        case "copy":
            let updates = confirmation.items.filter { $0.kind == .update }
            return (text("confirmCopyTitle"), text("confirmCopyBody", arguments: [
                "added": String(confirmation.addedCount),
                "updated": String(confirmation.updatedCount)
            ]), text("confirmCopyButton"), updates.isEmpty ? confirmation.items : updates)
        case "undo":
            return (text("confirmUndoTitle"), text("confirmUndoBody"), text("confirmUndoButton"), confirmation.items)
        case "recovery":
            return (text("confirmRecoveryTitle"), text("confirmRecoveryBody"), text("confirmRecoveryButton"), confirmation.items)
        case "preserve":
            return (text("confirmPreserveTitle"), text("confirmPreserveBody"), text("confirmPreserveButton"), confirmation.items)
        default:
            return (generated(confirmation.title), generated(confirmation.message), generated(confirmation.buttonTitle), confirmation.items)
        }
    }

    private func confirmationSheet(_ confirmation: SessionTransferConfirmation) -> some View {
        let content = confirmationCopy(confirmation)
        return VStack(alignment: .leading, spacing: 13) {
            Text(content.title).font(.system(size: 16, weight: .semibold)).foregroundColor(.txt)
            Text(content.message)
                .font(.system(size: 12))
                .foregroundColor(.sub)
                .fixedSize(horizontal: false, vertical: true)
            if !content.items.isEmpty {
                sessionList(content.items)
            }
            HStack {
                Spacer()
                Button(text(confirmation.kind == "preserve" ? "return" : "cancel")) {
                    if confirmation.kind == "preserve" {
                        controller.requestRecovery()
                    } else {
                        controller.cancelConfirmation()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .focused($modalCancelFocused)
                Button(content.button) {
                    Task { await controller.confirmAction() }
                }
                .buttonStyle(confirmation.kind == "preserve"
                    ? ImportProminentButtonStyle(tint: .bad, label: .bg)
                    : ImportProminentButtonStyle())
            }
            if confirmation.kind == "recovery" {
                Divider().overlay(Color.stroke)
                HStack {
                    Spacer()
                    Button(text("keepCurrent")) { controller.requestKeepCurrent() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .foregroundColor(.sub)
                }
            }
        }
    }

    private func backupInformationText(_ information: String) -> String {
        switch information {
        case "正在核对备份…": return text("backupChecking")
        case "备份已核对；只包含本次索引变更，不包含聊天原文。": return text("backupVerified")
        default: return generated(information)
        }
    }

    private func backupSheet() -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(text("backupTitle")).font(.system(size: 16, weight: .semibold)).foregroundColor(.txt)
            if let information = controller.backupInformation {
                Text(backupInformationText(information))
                    .font(.system(size: 11))
                    .foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(text("copyScope"))
                .font(.system(size: 11))
                .foregroundColor(.sub)
                .fixedSize(horizontal: false, vertical: true)
            if !controller.backupItems.isEmpty {
                sessionList(controller.backupItems, showKind: true)
            }
            HStack {
                Spacer()
                Button(text("close")) { controller.dismissBackup() }
                    .buttonStyle(ImportProminentButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .focused($modalCancelFocused)
            }
        }
    }

    private func handoffSheet() -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(text("handoffTitle")).font(.system(size: 16, weight: .semibold)).foregroundColor(.txt)
            Text(text("handoffNote"))
                .font(.system(size: 11))
                .foregroundColor(.sub)
            ScrollView {
                Text(SessionTransferLocalization.instructions(controller.handoffInformation ?? "", language: controller.language))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.txt)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
            HStack {
                Spacer()
                Button(text("close")) { controller.dismissHandoff() }
                    .keyboardShortcut(.cancelAction)
                    .focused($modalCancelFocused)
                Button(text(handoffCopied ? "copiedInstructions" : "copyInstructions")) {
                    guard let information = controller.handoffInformation else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(SessionTransferLocalization.instructions(information, language: controller.language), forType: .string)
                    handoffCopied = true
                }
                .buttonStyle(ImportProminentButtonStyle())
            }
        }
    }

    private func sessionList(_ items: [TransferSessionItem], showKind: Bool = false) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.txt)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.cwd)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        if showKind, let label = backupItemKind(item.kind) {
                            Text(label)
                                .font(.system(size: 10))
                                .foregroundColor(.sub)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if item.id != items.last?.id { Divider().overlay(Color.stroke) }
                }
            }
        }
        .frame(maxHeight: 230)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card.opacity(0.6)))
    }

    private func backupItemKind(_ kind: SessionTransferKind) -> String? {
        switch kind {
        case .add: return text("backupNew")
        case .update: return text("backupUpdate")
        case .skip, .blocked: return nil
        }
    }
}

@MainActor
private final class CopyWindowDelegate: NSObject, NSWindowDelegate {
    let store: Store
    let controller: SessionTransferController
    private var noticeTask: Task<Void, Never>?

    init(store: Store, controller: SessionTransferController) {
        self.store = store
        self.controller = controller
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        CopyWindow.returnToAccounts(store)
        return false
    }

    func showWorkingNotice(on window: NSWindow) {
        window.subtitle = SessionTransferLocalization.text("workingClose", language: controller.language)
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak window] in
            do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            window?.subtitle = ""
        }
    }
}

@MainActor
enum CopyWindow {
    static var window: NSWindow?
    private static var delegate: CopyWindowDelegate?
    private static var controllers: [ObjectIdentifier: SessionTransferController] = [:]

    static func controller(for store: Store) -> SessionTransferController {
        let key = ObjectIdentifier(store)
        if let controller = controllers[key] { return controller }
        let controller = SessionTransferController(store: store)
        controllers[key] = controller
        return controller
    }

    static func show(_ store: Store) {
        let controller = controller(for: store)
        var viewWillRefresh = false
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentMinSize = NSSize(width: 680, height: 520)
            window = w
            install(store: store, controller: controller, on: w)
            w.center()
            viewWillRefresh = true
        } else if delegate?.store !== store {
            install(store: store, controller: controller, on: window!)
            viewWillRefresh = true
        }
        updateTitle(store: store, language: controller.language)
        window?.subtitle = ""
        if !viewWillRefresh && !controller.isWorking {
            Task { await controller.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func returnToAccounts(_ store: Store) {
        let controller = controller(for: store)
        guard !controller.isWorking else {
            if let window { delegate?.showWorkingNotice(on: window) }
            return
        }
        window?.subtitle = ""
        window?.orderOut(nil)
        store.returnToAccounts()
    }

    static func updateTitle(store: Store, language: String) {
        guard let window, delegate?.store === store else { return }
        let key = store.isDemo ? "demoWindowTitle" : "windowTitle"
        window.title = SessionTransferLocalization.text(key, language: language)
    }

    private static func install(store: Store, controller: SessionTransferController, on window: NSWindow) {
        let windowDelegate = CopyWindowDelegate(store: store, controller: controller)
        delegate = windowDelegate
        window.delegate = windowDelegate
        window.contentViewController = NSHostingController(rootView: CopyThreadsView(store: store, controller: controller))
    }
}
