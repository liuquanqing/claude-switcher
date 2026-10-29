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

    private var listSummary: String {
        text(controller.query.isEmpty ? "listSummary" : "filteredListSummary", arguments: [
            "shown": String(controller.visibleRows.count),
            "selectable": String(selectableVisibleRows.count)
        ])
    }

    private var selectedSummary: String {
        let count = controller.picked.count
        let visibleCount = controller.visibleRows.filter { controller.picked.contains($0.id) }.count
        let outsideCount = max(0, count - visibleCount)
        if !controller.query.isEmpty && outsideCount > 0 {
            return text("selectedCountOutside", arguments: ["count": String(count), "outside": String(outsideCount)])
        }
        return text("selectedCount", arguments: ["count": String(count)])
    }

    private var visibleStatusMessage: String? {
        guard let status = controller.statusMessage else { return nil }
        if status.hasPrefix("已复制") || status == "已撤销上次复制。" ||
            status == "已恢复上次未完成的变更。" || status.hasPrefix("已保留当前数据并结束记录") {
            return nil
        }
        switch status {
        case "选择或空间已变化，请重新复制。": return text("statusSelectionChanged")
        case "请先在相应账号或 API 工作区打开 Code 页，再重新检查。": return text("statusOpenCode")
        case "请选择不同的来源和目标空间。": return text("statusDifferentSpaces")
        default: return status
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
        VStack(alignment: .leading, spacing: 12) {
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
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    picker(text("from"), selection: sourceBinding, options: controller.locations)
                    if controller.sourceSpaces.count > 1 {
                        spacePicker(text("sourceSpace"), selection: sourceSpaceBinding, options: controller.sourceSpaces)
                    }
                }
                Image(systemName: "arrow.right").foregroundColor(.sub)
                VStack(alignment: .leading, spacing: 8) {
                    picker(text("to"), selection: targetBinding, options: controller.locations)
                    if controller.targetSpaces.count > 1 {
                        spacePicker(text("targetSpace"), selection: targetSpaceBinding, options: controller.targetSpaces)
                    }
                }
                Spacer(minLength: 0)
            }

            if let error = controller.errorMessage {
                message(error, color: .bad)
            } else if let status = visibleStatusMessage {
                message(status, color: .sub)
            }

            HStack(spacing: 12) {
                TextField(text("search"), text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                Toggle(text("updateExisting"), isOn: updateBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .tint(.importAccentSoft)
                    .disabled(controller.isWorking)
                    .help(text("updateHelp"))
            }

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
                Spacer()
                Text(listSummary)
                    .font(.system(size: 12)).foregroundColor(.sub)
            }

            List(controller.visibleRows) { row in
                let isPicked = controller.picked.contains(row.id)
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: pickedBinding(row))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .tint(.importAccentSoft)
                        .disabled(!row.selectable || controller.isWorking)
                        .accessibilityLabel(Text(row.title))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.txt)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .help(row.title)
                                .layoutPriority(1)
                            Text(row.project)
                                .font(.system(size: 11))
                                .foregroundColor(.sub)
                                .lineLimit(1)
                        }
                        Text(row.cwd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.sub)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(row.cwd)
                        if !row.selectable && row.kind == .blocked {
                            Text(row.reason)
                                .font(.system(size: 11))
                                .foregroundColor(Color.txt.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(activityTime(row.lastActivity))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.sub)
                            .frame(width: 66, alignment: .trailing)
                        if let status = rowStatus(row) {
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(row.kind == .update ? .importAccentSoft : (row.kind == .blocked ? .warn : .sub))
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 7).fill(isPicked ? Color.importAccent.opacity(0.22) : Color.clear))
                .contentShape(Rectangle())
                .help(row.reason)
                .accessibilityHint(row.reason)
                .onTapGesture {
                    guard row.selectable, !controller.isWorking else { return }
                    controller.setPicked(row.id, selected: !controller.picked.contains(row.id))
                }
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.card.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.stroke.opacity(0.75), lineWidth: 1))
            .overlay {
                if controller.visibleRows.isEmpty {
                    Text(text(controller.rows.isEmpty ? "noRows" : "noMatches"))
                        .font(.system(size: 12))
                        .foregroundColor(.sub)
                }
            }

            if let operation = controller.lastOperation {
                operationView(operation)
            }

            HStack(spacing: 10) {
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                    Text(text("processing")).font(.system(size: 12)).foregroundColor(.importAccentSoft)
                }
                Text(selectedSummary)
                    .font(.system(size: 12))
                    .foregroundColor(.sub)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button(text(instructionsCopied ? "copiedInstructions" : "copyForClaude")) {
                    copyInstructions()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .foregroundColor(.sub)
                .disabled(!controller.canExport || controller.isWorking)
                Button(text("copy")) {
                    Task { await controller.copySelected() }
                }
                .buttonStyle(ImportProminentButtonStyle())
                .disabled(!controller.canCopy || controller.isWorking)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 520)
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
            guard pasteboard.setString(instructions, forType: .string),
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

    private func picker(_ label: String, selection: Binding<String>, options: [TransferLocationOption]) -> some View {
        Picker(label, selection: selection) {
            ForEach(options) { Text($0.name).tag($0.id) }
        }
        .frame(width: 210)
        .disabled(controller.isWorking)
    }

    private func spacePicker(_ label: String, selection: Binding<String>, options: [TransferSpaceOption]) -> some View {
        Picker(label, selection: selection) {
            Text(text("chooseSpace")).tag("")
            ForEach(options) { Text($0.name).tag($0.id) }
        }
        .frame(width: 210)
        .disabled(controller.isWorking)
    }

    private func message(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowStatus(_ row: SessionTransferRow) -> String? {
        switch row.kind {
        case .add: return nil
        case .update: return text("canUpdate")
        case .skip: return text("existing")
        case .blocked: return text("needsReview")
        }
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
            guard let first = items.first else { return (text("copyCompleted"), operation.summary, .good) }
            let key = items.count == 1 ? "copiedOne" : "copiedMany"
            return (text("copyCompleted"), text(key, arguments: ["title": first.title, "count": String(items.count)]), .good)
        case .undone:
            return (text("undone"), text("undoneSummary", arguments: ["count": String(items.count)]), .good)
        case .restored:
            return (text("restored"), text("restoredSummary"), .good)
        case .preserved:
            if operation.summary.contains("备份缺失或无法核对") {
                return (text("preserved"), operation.summary, .warn)
            }
            return (text("preserved"), text("preservedSummary"), .warn)
        case .copying, .restoring, .recoveryRequired:
            return (text("recoveryRequired"), text("recoverySummary"), .bad)
        @unknown default:
            return (operation.title, operation.summary, .sub)
        }
    }

    private func operationView(_ operation: SessionTransferOperation) -> some View {
        let content = operationContent(operation)
        return HStack(alignment: .center, spacing: 9) {
            Circle().fill(content.color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(content.color)
                Text(content.summary)
                    .font(.system(size: 10.5))
                    .foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(text("viewBackup")) { controller.showBackup() }
                .buttonStyle(.link).font(.system(size: 10.5)).foregroundColor(.sub)
            if operation.canUndo {
                Button(text("undo")) { controller.requestUndo() }
                    .buttonStyle(.link).font(.system(size: 10.5)).foregroundColor(.sub)
                    .disabled(controller.isWorking)
            }
            if operation.needsRecovery {
                Button(text("recover")) { controller.requestRecovery() }
                    .buttonStyle(.link).font(.system(size: 10.5)).foregroundColor(.sub)
                    .disabled(controller.isWorking)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
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
            return (confirmation.title, confirmation.message, confirmation.buttonTitle, confirmation.items)
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
        default: return information
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
                Text(controller.handoffInformation ?? "")
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
                    pasteboard.setString(information, forType: .string)
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
            w.contentMinSize = NSSize(width: 620, height: 520)
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
