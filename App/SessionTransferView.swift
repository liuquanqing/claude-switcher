import AppKit
import SwiftUI
import SwitcherCore

@MainActor
struct CopyThreadsView: View {
    @StateObject private var controller: SessionTransferController

    init(store: Store) {
        _controller = StateObject(wrappedValue: SessionTransferController(store: store))
    }

    private var selectableVisibleRows: [SessionTransferRow] {
        controller.visibleRows.filter(\.selectable)
    }

    private var allVisiblePicked: Bool {
        !selectableVisibleRows.isEmpty && selectableVisibleRows.allSatisfy { controller.picked.contains($0.id) }
    }

    private var targetName: String {
        controller.locations.first { $0.id == controller.targetID }?.name ?? controller.targetID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    picker("From", selection: sourceBinding, options: controller.locations)
                    if controller.sourceSpaces.count > 1 {
                        spacePicker("来源空间", selection: sourceSpaceBinding, options: controller.sourceSpaces)
                    }
                }
                Image(systemName: "arrow.right").foregroundColor(.claude)
                VStack(alignment: .leading, spacing: 8) {
                    picker("To", selection: targetBinding, options: controller.locations)
                    if controller.targetSpaces.count > 1 {
                        spacePicker("目标空间", selection: targetSpaceBinding, options: controller.targetSpaces)
                    }
                }
                Spacer(minLength: 0)
            }

            if let error = controller.errorMessage {
                message(error, color: .bad)
            } else if let status = controller.statusMessage {
                message(status, color: .sub)
            }

            HStack(spacing: 12) {
                TextField("Search threads or projects", text: $controller.query)
                    .textFieldStyle(.roundedBorder)
                Toggle("更新已有会话", isOn: updateBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(controller.isWorking)
                    .help("默认只新增；开启后才可选择有充分证据的已有会话更新")
            }

            HStack(spacing: 7) {
                Button(allVisiblePicked ? "Select none" : "Select all") {
                    controller.selectAllVisible()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(selectableVisibleRows.isEmpty || controller.isWorking)
                FooterButton(icon: "arrow.clockwise", help: "重新读取并检查会话") {
                    Task { await controller.refresh() }
                }
                .disabled(controller.isWorking)
                Spacer()
                Text("\(controller.picked.count) selected · \(controller.visibleRows.count) shown")
                    .font(.system(size: 11)).foregroundColor(.sub)
            }

            List(controller.visibleRows) { row in
                HStack(spacing: 10) {
                    Toggle("", isOn: pickedBinding(row))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!row.selectable || controller.isWorking)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.txt)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(row.title)
                            if row.kind != .add {
                                Image(systemName: statusIcon(row.kind))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(statusColor(row.kind))
                                    .help(row.reason)
                                    .accessibilityLabel(row.reason)
                            }
                        }
                        Text(displayPath(row.cwd))
                            .font(.system(size: 11))
                            .foregroundColor(.sub)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.cwd)
                    }
                    Spacer(minLength: 4)
                    Text(row.project)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .foregroundColor(.sub)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.stroke))
                        .lineLimit(1)
                    Text(ago(row.lastActivity))
                        .font(.system(size: 11))
                        .foregroundColor(.sub)
                        .frame(width: 66, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .help(row.reason)
                .accessibilityHint(row.reason)
                .onTapGesture {
                    guard row.selectable, !controller.isWorking else { return }
                    controller.setPicked(row.id, selected: !controller.picked.contains(row.id))
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .overlay {
                if controller.visibleRows.isEmpty {
                    Text(controller.rows.isEmpty ? "没有可复制的会话" : "没有匹配的会话")
                        .font(.system(size: 12))
                        .foregroundColor(.sub)
                }
            }

            if let operation = controller.lastOperation {
                operationView(operation)
            }

            HStack(spacing: 8) {
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                    Text("正在处理…").font(.system(size: 11)).foregroundColor(.claude)
                }
                Spacer()
                Button("复制 \(controller.picked.count) 项到 \(targetName)") {
                    Task { await controller.copySelected() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canCopy || controller.isWorking)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 520)
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .task { await controller.refresh() }
        .alert(item: confirmationBinding) { confirmation in
            Alert(title: Text(confirmation.title),
                  message: Text(confirmation.message),
                  primaryButton: .cancel(Text("取消")) { controller.cancelConfirmation() },
                  secondaryButton: .destructive(Text(confirmation.buttonTitle)) {
                      Task { await controller.confirmAction() }
                  })
        }
        .alert("备份摘要", isPresented: backupPresented) {
            Button("关闭") { controller.dismissBackup() }
        } message: {
            Text(controller.backupInformation ?? "")
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

    private var confirmationBinding: Binding<SessionTransferConfirmation?> {
        Binding(get: { controller.confirmation }, set: { value in
            if value == nil { controller.dismissConfirmation() }
        })
    }

    private var backupPresented: Binding<Bool> {
        Binding(get: { controller.backupInformation != nil }, set: { presented in
            if !presented { controller.dismissBackup() }
        })
    }

    private func pickedBinding(_ row: SessionTransferRow) -> Binding<Bool> {
        Binding(get: { controller.picked.contains(row.id) },
                set: { controller.setPicked(row.id, selected: $0) })
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
            Text("请选择空间").tag("")
            ForEach(options) { Text($0.name).tag($0.id) }
        }
        .frame(width: 210)
        .disabled(controller.isWorking)
    }

    private func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusIcon(_ kind: SessionTransferKind) -> String {
        switch kind {
        case .add: return "plus.circle"
        case .update: return "arrow.triangle.2.circlepath"
        case .skip: return "info.circle"
        case .blocked: return "exclamationmark.circle"
        }
    }

    private func statusColor(_ kind: SessionTransferKind) -> Color {
        switch kind {
        case .add: return .good
        case .update: return .claude
        case .skip: return .sub
        case .blocked: return .warn
        }
    }

    private func operationView(_ operation: SessionTransferOperation) -> some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(operation.needsRecovery ? .bad : .txt)
                Text(operation.summary)
                    .font(.system(size: 10.5))
                    .foregroundColor(.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("查看备份") { controller.showBackup() }
                .buttonStyle(.link).font(.system(size: 10.5))
            if operation.canUndo {
                Button("撤销") { controller.requestUndo() }
                    .buttonStyle(.link).font(.system(size: 10.5))
                    .disabled(controller.isWorking)
            }
            if operation.needsRecovery {
                Button("恢复") { controller.requestRecovery() }
                    .buttonStyle(.link).font(.system(size: 10.5))
                    .disabled(controller.isWorking)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.card))
    }
}

enum CopyWindow {
    static var window: NSWindow?

    @MainActor static func show(_ store: Store) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "复制 Claude Code 会话"
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentViewController = NSHostingController(rootView: CopyThreadsView(store: store))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
