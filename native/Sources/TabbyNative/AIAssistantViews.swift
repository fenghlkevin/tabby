import SwiftUI
import AppKit

struct AIAssistantPane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var ai: AIAssistant
    var terminal = false
    @State private var command = ""
    @State private var contextExpanded = false
    @State private var expandedReplies: Set<UUID> = []
    @State private var followsOutput = true
    @State private var changesPresented = false
    @State private var historyPresented = false
    @State private var approvalScope = "once"
    @AppStorage("axon.ai.executionStyle") private var executionStyle = "terminal"
    private var executes: Bool { terminal && executionStyle != "analysis" }
    private var scopeChoices: [(String, String)] {
        var choices = [("once", store.text("Only this operation", "仅允许这一次"))]
        if ai.settings.policy.mode == .assisted && ai.pendingTool.hasPrefix("terminal_") && ai.pendingTool != "terminal_execute" { choices.append(("task", store.text("Terminal actions for this task", "本次任务的终端操作"))) }
        if ai.pendingTool != "replace_file" {
            choices.append(("remember", store.text("Always allow this operation", "一直允许此操作")))
            choices.append(("deny", store.text("Always deny this operation", "一直不允许此操作")))
        }
        return choices
    }
    var expanded = false
    private var target: TerminalSession? { store.sessions.first { $0.id == ai.answerSessionID } }
    var availableHeight: CGFloat = 620
    private var session: TerminalSession? { store.sessions.first { $0.id == store.activeSession } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(store.text("AI assistant", "AI 助手"), systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                    Text(ai.settings.backend.title + (ai.settings.codexModel.isEmpty || ai.settings.backend != .codex ? "" : " · " + ai.settings.codexModel)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    if !ai.context.source.isEmpty { Text(ai.context.source).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                if terminal && !expanded {
                    Button { store.aiAnalysisPresented = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(IconButtonStyle()).help(store.text("Expand AI workspace", "展开 AI 工作区")).accessibilityIdentifier("axon-ai-expand")
                }
                Group {
                    Button { ai.newConversation() } label: { Image(systemName: "plus.bubble") }.buttonStyle(IconButtonStyle()).disabled(ai.busy).help(store.text("New conversation; previous chats remain in history", "新对话；旧会话保留在会话历史中")).accessibilityIdentifier("axon-ai-new-conversation")
                    Button { historyPresented = true } label: { Image(systemName: "clock.arrow.circlepath") }.buttonStyle(IconButtonStyle()).disabled(ai.busy || ai.taskRecords.isEmpty).help(store.text("Conversation history", "会话历史")).accessibilityIdentifier("axon-ai-task-history")
                }
                Button { store.aiAnalysisPresented = false; store.openPreferences(.ai) } label: { Image(systemName: "gearshape") }.buttonStyle(IconButtonStyle()).help(store.text("AI settings", "AI 设置"))
            }.padding(16)
            Divider()
            ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if terminal && !ai.workflowStage.isEmpty {
                        Label(localized(ai.workflowStage), systemImage: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                        Text(store.text("Network → Service → Configuration → Changes → Verification", "查网络 → 查服务 → 查配置 → 展示修改 → 验证恢复")).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup(store.text("Context · \(ai.context.text.count) characters", "当前上下文 · \(ai.context.text.count) 字"), isExpanded: $contextExpanded) {
                        Text(ai.context.source).font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                        if terminal { ScrollView { Text(ai.context.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("axon-ai-context") }.frame(height: 160).padding(8).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)) }
                        else { TextEditor(text: Binding(get: { ai.context.text }, set: { ai.context = AIContext(source: ai.context.source, text: $0, sessionID: ai.context.sessionID) })).font(.system(size: 11, design: .monospaced)).frame(height: 150).accessibilityIdentifier("axon-ai-context") }
                    }.font(.system(size: 12)).foregroundStyle(Palette.muted)
                    if ai.conversation.isEmpty && ai.submittedQuestion.isEmpty && ai.answer.isEmpty && !ai.busy && ai.steps.isEmpty {
                        Text(executes ? store.text("Describe a goal; I will check this target and request approval when needed.", "描述目标，我会检查当前目标，并按权限规则处理。") : store.text("Ask a question or continue the conversation using the current context.", "直接提问或继续追问，我会结合当前上下文回答。"))
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    ForEach(ai.conversation) { turn in
                        conversationQuestion(turn.question)
                        replyView(turn.answer, steps: turn.steps, error: turn.error, executed: turn.executed)
                        Divider()
                    }
                    if !ai.submittedQuestion.isEmpty { conversationQuestion(ai.submittedQuestion) }
                    if !ai.steps.isEmpty || !ai.answer.isEmpty || !ai.error.isEmpty || ai.busy || ai.stopped {
                        replyView(ai.answer, steps: ai.steps, error: ai.error, executed: ai.currentTurnExecuted, source: ai.executionSource, directory: ai.executionDirectory, live: true)
                    }
            if !command.isEmpty {
                Text(store.text("Review command", "检查命令")).font(.system(size: 12, weight: .semibold))
                TextEditor(text: $command).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(8).frame(height: 90).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("axon-ai-command")
                Text(target?.displayTitle ?? store.text("No terminal target", "没有目标终端")).font(.caption).foregroundStyle(Palette.muted)
                HStack {
                    Button(store.text("Copy", "复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }.buttonStyle(ChromeButtonStyle())
                    Button(store.text("Insert", "填入终端")) { insert() }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(target?.connected != true || target?.id != store.activeSession || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("axon-ai-insert")
                }
                Text(store.text("Inserts into the original active terminal without Return. Review the terminal input before running.", "只填入原会话的当前终端，不按回车；执行前请检查终端输入。")).font(.system(size: 11)).foregroundStyle(Palette.muted).id("ai-command-review-bottom")
            }
                    Color.clear.frame(height: 1).id("ai-answer-bottom")
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity).onChange(of: ai.answer) { _, _ in if ai.busy && followsOutput { reader.scrollTo("ai-answer-bottom", anchor: .bottom) } }.onChange(of: ai.steps.count) { _, _ in if ai.busy && followsOutput { reader.scrollTo("ai-answer-bottom", anchor: .bottom) } }.onChange(of: command) { _, value in if !value.isEmpty { reader.scrollTo("ai-command-review-bottom", anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let pending = ai.pendingApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(store.text("Approval required on ", "需要确认 · ") + localized(ai.executionSource), systemImage: "hand.raised").font(.system(size: 12, weight: .semibold))
                        Text(pending.reason).font(.system(size: 12)).textSelection(.enabled)
                        ScrollView { Text(operationText(pending)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 60)
                        if ai.approvalPreview.isEmpty {
                            AxonChoiceField(selection: $approvalScope, choices: scopeChoices, placeholder: store.text("Approval scope", "允许范围"), symbol: "checkmark.shield", identifier: "axon-ai-approval-scope")
                        }
                        HStack {
                            Button(store.text("Cancel task", "取消任务")) { ai.resolveApproval(false) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).accessibilityIdentifier("axon-ai-decline")
                            Spacer()
                            Button(ai.approvalPreview.isEmpty ? approvalScope == "deny" ? store.text("Deny and remember", "禁止并记住") : store.text("Allow and continue", "允许并继续") : store.text("Review and apply", "查看差异并应用")) {
                                if !ai.approvalPreview.isEmpty { changesPresented = true }
                                else if approvalScope == "task" { ai.allowInteractiveTask() }
                                else if approvalScope == "remember" { ai.rememberExactAction() }
                                else if approvalScope == "deny" { ai.rememberExactAction(denied: true) }
                                else { ai.approveAction() }
                            }.buttonStyle(ChromeButtonStyle(prominent: true)).accessibilityIdentifier("axon-ai-approve")
                        }
                    }.padding(12).background(Palette.selected).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if ai.busy {
                    Text(ai.submittedQuestion).font(.system(size: 12)).lineLimit(2).foregroundStyle(Palette.muted)
                } else {
                    AIComposer(text: $ai.question, send: sendCurrent).frame(height: 76).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("axon-ai-question")
                }
                if ai.pendingApproval == nil {
                    HStack(spacing: 8) {
                        Button { if !contextExpanded { store.prepareTerminalAI() }; contextExpanded.toggle() } label: { Image(systemName: contextExpanded ? "eye" : "eye.slash") }.buttonStyle(IconButtonStyle()).help(contextExpanded ? store.text("Hide context", "收起上下文") : store.text("Preview context", "预览上下文")).disabled(ai.busy || session == nil).accessibilityIdentifier("axon-ai-preview").accessibilityValue(contextExpanded ? "open" : "closed")
                        if terminal && !ai.busy {
                            AxonChoiceField(selection: $executionStyle, choices: [("terminal", store.text("Current terminal", "当前终端")), ("independent", store.text("Independent command", "独立命令")), ("analysis", store.text("Chat assistant", "对话助手"))], placeholder: store.text("Execution method", "执行方式"), symbol: "terminal", identifier: "axon-ai-execution-style").frame(width: 120).disabled(ai.busy)
                        }
                        if ai.busy { Toggle(store.text("Follow", "跟随"), isOn: $followsOutput).toggleStyle(.switch).controlSize(.small).font(.system(size: 11)) }
                        Spacer()
                        if ai.busy { Button(store.text("Stop", "停止任务")) { ai.cancel() }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-ai-stop") }
                        else {
                            VStack(spacing: 4) {
                                Button(store.text("Send ↩︎", "发送 ↩︎")) { sendCurrent() }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (executes && session?.connected != true)).accessibilityIdentifier("axon-ai-send")
                                Text(store.text("Shift+↩︎ newline", "Shift+↩︎ 换行")).font(.system(size: 9)).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
                Text(executes ? store.text("Permission rules apply. File changes show a diff; recovery needs health checks.", "按权限规则执行；修改先看差异，完成后验证恢复。") : store.text("Conversation includes the current context. No commands are executed.", "结合当前上下文连续对话，不执行命令。")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(16).background(Palette.card)
        }.onChange(of: ai.pendingApproval?.id) { _, _ in approvalScope = "once" }.frame(height: availableHeight).foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light)
            .sheet(isPresented: $changesPresented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(store.text("Review configuration change", "检查配置修改")).font(.system(size: 18, weight: .semibold))
                    Text(localized(ai.executionSource)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Text(ai.pendingApproval.map(operationText) ?? "").font(.system(size: 12)).textSelection(.enabled)
                    ScrollView { Text(ai.approvalPreview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.padding(12).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(store.text("Checks for conflicts, preserves the original backup and verifies written bytes. Service recovery will be checked afterwards.", "应用时检查冲突，保留原文备份并校验写入内容；随后继续检查服务恢复情况。")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    HStack {
                        Button(store.text("Back", "返回")) { changesPresented = false }.buttonStyle(ChromeButtonStyle())
                        Spacer()
                        Button(store.text("Apply and verify", "应用并验证")) { changesPresented = false; ai.approveAction() }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.pendingApproval == nil).accessibilityIdentifier("axon-ai-apply-diff")
                    }
                }.padding(20).frame(width: 680, height: 520).foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light)
            }
            .sheet(isPresented: $historyPresented) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(store.text("Conversation history", "会话历史")).font(.system(size: 18, weight: .semibold)); Spacer(); Button(store.text("Delete all", "全部删除"), role: .destructive) { ai.deleteAllTasks() }.buttonStyle(ChromeButtonStyle()).disabled(ai.busy || ai.taskRecords.isEmpty).accessibilityIdentifier("axon-ai-delete-all-tasks"); DismissIconButton(title: store.text("Close", "关闭")) { historyPresented = false }.accessibilityIdentifier("axon-ai-close-history") }
                    Text(store.text("Continue on the original target. Previous results are rechecked; modifications are never replayed automatically.", "同一会话中的连续提问归为一条对话；“新对话”另建记录。打开历史可恢复全部问答；旧版记录保留原有摘要，执行前重新检查目标。")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(ai.taskRecords.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.question).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    Text(localized(entry.target)).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                                    Text(entry.updated.formatted() + " · " + taskState(entry.state) + " · " + String(entry.messageCount ?? 1) + store.text(" messages", " 条消息")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    Text(entry.summary).font(.system(size: 12)).lineLimit(3)
                                    HStack { Button(store.text("Open conversation", "打开会话")) { ai.restoreTask(entry); historyPresented = false }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-ai-continue-task"); Spacer(); Button(store.text("Delete", "删除"), role: .destructive) { ai.deleteTask(entry.id) }.buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-ai-delete-task") }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }.padding(20).frame(width: 680, height: 520).foregroundStyle(Palette.text).background(Palette.background).colorScheme(.light)
            }
            .onChange(of: ai.approvalPreview) { _, value in if value.isEmpty { changesPresented = false } }
            .onChange(of: ai.requestID) { _, _ in command = "" }
            .onAppear { if terminal && ai.context.sessionID != store.activeSession { store.prepareTerminalAI() } }
    }
    private func conversationQuestion(_ value: String) -> some View {
        HStack { Spacer(minLength: 24); Text(value).font(.system(size: 13)).textSelection(.enabled).padding(12).background(Palette.selected).clipShape(RoundedRectangle(cornerRadius: 10)) }.accessibilityIdentifier("axon-ai-user-message")
    }
    private func copyAnswer(_ value: String) -> some View {
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: {
            Label(store.text("Copy answer", "复制回答"), systemImage: "doc.on.doc").font(.system(size: 11))
        }.buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityIdentifier("axon-ai-copy-answer")
    }
    private func replyView(_ value: String, steps: [AIAgentStep], error: String, executed: Bool, source: String = "", directory: String = "", live: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                if !source.isEmpty {
                    Label(localized(source), systemImage: "scope").font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    if !directory.isEmpty { Text(store.text("Directory: ", "目录：") + localized(directory)).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                }
                if !steps.isEmpty {
                    Button {
                        if let id = steps.first?.id {
                            if expandedReplies.contains(id) { expandedReplies.remove(id) } else { expandedReplies.insert(id) }
                        }
                    } label: {
                        Label(store.text("Actions · \(steps.count)", "执行过程 · \(steps.count) 步"), systemImage: expandedReplies.contains(steps[0].id) ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).accessibilityIdentifier("axon-ai-reply-actions")
                    if expandedReplies.contains(steps[0].id) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(steps) { step in
                                stepView(step)
                                if step.id != steps.last?.id { Divider() }
                            }
                        }.padding(.top, 6)
                    }
                }
                ForEach(Array(AIProtocol.displayBlocks(value).enumerated()), id: \.offset) { _, block in
                    if block.code {
                        ScrollView(.horizontal) { Text(block.text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(10) }.background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else { Text((try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text)).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                if !error.isEmpty { Label(localized(error), systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger).font(.system(size: 12)).textSelection(.enabled).accessibilityIdentifier("axon-ai-error") }
                if live && ai.stopped { Label(store.text("Stopped · results retained", "已停止 · 保留已执行结果"), systemImage: "stop.circle").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                if live && ai.busy {
                    if let last = steps.last { Text(localized(last.reason)).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(localized(ai.activity.isEmpty ? "Receiving answer / 正在接收回答" : ai.activity) + " · " + String(max(0, Int(timeline.date.timeIntervalSince(ai.startedAt)))) + "s").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }.accessibilityIdentifier("axon-ai-progress")
                }
                if executed && !value.isEmpty && !(live && ai.busy) { copyAnswer(value) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 24)
        }
    }
    private func stepView(_ step: AIAgentStep) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(operationText(step)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if !step.output.isEmpty {
                    ScrollView { Text(step.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
                }
                if step.state == "failed" || step.state == "stopped" { Text(store.text("Command did not complete", "命令未完成")).font(.caption).foregroundStyle(Palette.danger) }
            }.padding(.vertical, 6)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: step.state == "running" ? "hourglass" : step.state == "finished" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(step.state == "failed" ? Palette.danger : Palette.muted)
                Text(localized(step.reason)).font(.system(size: 12)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let code = step.exitCode { Text("exit \(code)").font(.system(size: 10)).foregroundStyle(code == 0 ? Palette.muted : Palette.danger) }
            }
        }.padding(.vertical, 7)
    }
    private func operationText(_ step: AIAgentStep) -> String {
        switch step.tool {
        case "terminal_send": return store.text("Input without Return:\n", "输入文本（不回车）：\n") + step.input
        case "terminal_execute": return store.text("Execute command:\n", "执行命令：\n") + step.input
        case "terminal_key":
            let names = ["enter": "回车", "escape": "Esc", "space": "空格", "up": "上", "down": "下", "left": "左", "right": "右", "backspace": "退格", "tab": "Tab", "home": "Home", "end": "End"]
            return store.text("Press key: ", "按键：") + store.text(step.input, names[step.input] ?? step.input)
        case "terminal_read": return store.text("Read current terminal", "读取当前终端")
        case "terminal_wait": return store.text("Wait and read terminal: ", "等待并读取终端：") + step.input + "s"
        case "replace_file": return store.text("Change configuration:\n", "修改配置：\n") + step.input
        default: return step.command
        }
    }
    private func localized(_ text: String) -> String { let parts = text.components(separatedBy: " / "); return parts.count == 2 ? store.text(parts[0], parts[1]) : text }
    private func taskState(_ value: String) -> String {
        let chinese = ["running": "执行中", "finished": "已完成", "interrupted": "已中断", "failed": "失败", "blocked": "受阻", "declined": "已取消", "limited": "达到限额"]
        return store.text(value, chinese[value] ?? value)
    }
    private func sendCurrent() {
        guard !ai.busy, !ai.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !executes || session?.connected == true else { return }
        if terminal { store.prepareTerminalAI() }
        if executes {
            ai.executionChannel = executionStyle == "terminal" ? .currentTerminal : .independent
            guard let session, session.connected else { ai.error = store.text("Connect a terminal first", "请先连接终端"); return }
            ai.send(executor: AICommandExecutor(session: session, policy: ai.settings.policy))
        } else { ai.executionChannel = nil; ai.send() }
    }
    private func insert() {
        guard let target, target.connected, target.id == store.activeSession, let view = target.terminal else { return }
        do {
            guard !command.unicodeScalars.contains(where: { (127...159).contains($0.value) }) else { throw AppFailure.message("Command contains terminal control characters. / 命令包含终端控制字符。") }
            let bytes = try SnippetInput.bytes(command, action: .insert, bracketedPaste: view.terminalStateSnapshot().bracketedPasteMode, chinese: store.chinese); view.send(data: bytes[...]) }
        catch { ai.error = error.localizedDescription }
    }
}

struct AIAnalysisSheet: View {
    private var sheetHeight: CGFloat { min(900, (NSScreen.main?.visibleFrame.height ?? 1000) - 60) }
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(store.text("AI analysis", "AI 分析")).font(.headline); Spacer(); DismissIconButton(title: store.text("Close", "关闭")) { dismiss() } }.padding(16)
            AIAssistantPane(ai: store.ai, terminal: store.ai.context.sessionID != nil, expanded: true, availableHeight: sheetHeight - 60)
        }.frame(width: min(1200, (NSScreen.main?.visibleFrame.width ?? 1300) - 60), height: sheetHeight).background(Palette.background)
    }
}

struct AISettingsPane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var ai: AIAssistant
    @State private var draft = AISettings()
    @State private var key = ""
    @State private var feedback = ""
    @State private var failed = false
    @State private var catalog: [CodexModel] = []
    @State private var discovering = false
    @State private var discoveryError = ""
    @State private var customModel = false
    private var selectedModel: CodexModel? { catalog.first { $0.slug == draft.codexModel } }
    private var modelSelection: Binding<String> { Binding(get: { customModel ? "__custom__" : draft.codexModel }, set: { value in
        customModel = value == "__custom__"
        if !customModel {
            draft.codexModel = value
            if let model = catalog.first(where: { $0.slug == value }) {
                if let effort = draft.codexReasoningEffort, !model.efforts.isEmpty, !model.efforts.contains(effort) { draft.codexReasoningEffort = nil }
                if !model.supportsFast, draft.codexServiceTier == "priority" { draft.codexServiceTier = nil }
            }
            saveCodexSelection()
        }
    }) }
    private var modelChoices: [(String, String)] { [("", store.text("CLI default model", "CLI 默认模型"))] + catalog.map { ($0.slug, $0.display_name) } + [("__custom__", store.text("Custom model ID…", "自定义模型 ID…"))] }
    private var effortChoices: [(String, String)] {
        let efforts = selectedModel?.efforts.isEmpty == false ? selectedModel!.efforts : ["low", "medium", "high", "xhigh", "max", "ultra"]
        let titles = ["minimal": store.text("Minimal", "最低"), "low": store.text("Low", "低"), "medium": store.text("Medium", "中"), "high": store.text("High", "高"), "xhigh": store.text("Extra high", "很高"), "max": store.text("Maximum", "最高"), "ultra": store.text("Ultra", "超高")]
        return [("", store.text("Model default", "模型默认"))] + efforts.map { ($0, titles[$0] ?? $0) }
    }
    private var speedChoices: [(String, String)] {
        var values = [("", store.text("CLI default", "CLI 默认")), ("default", store.text("Standard", "标准"))]
        if selectedModel?.supportsFast != false { values.append(("priority", store.text("Fast · when available", "快速 · 需支持"))) }
        return values
    }
    private func optional(_ keyPath: WritableKeyPath<AISettings, String?>) -> Binding<String> { Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0; if keyPath == \.codexReasoningEffort || keyPath == \.codexServiceTier { saveCodexSelection() } }) }
    private var provider: Binding<AIProviderSettings> { Binding(get: { draft.provider }, set: { if draft.backend == .claude { draft.claude = $0 } else { draft.chatgpt = $0 } }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AxonChoiceField(selection: $draft.backend, choices: AIBackend.allCases.map { ($0, $0.title) }, placeholder: store.text("Provider", "服务"), symbol: "sparkles", identifier: "axon-ai-provider").frame(maxWidth: 360)
            VStack(alignment: .leading, spacing: 12) {
                if draft.backend == .codex {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.text("Model", "模型")).foregroundStyle(Palette.muted)
                        AxonChoiceField(selection: modelSelection, choices: modelChoices, placeholder: store.text("Choose model", "选择模型"), symbol: "cpu", identifier: "axon-ai-codex-model").frame(maxWidth: 500)
                        Button(store.text("Refresh models", "刷新模型")) { Task { await refreshModels(force: true) } }.buttonStyle(ChromeButtonStyle()).disabled(discovering)
                        if discovering { Text(store.text("Loading CLI models…", "正在查询 CLI 模型…")).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        if !discoveryError.isEmpty { Text(discoveryError).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        if customModel { field(store.text("Model ID", "模型 ID"), text: $draft.codexModel, placeholder: store.text("Exact model ID supported by Codex", "填写 Codex 支持的完整模型 ID")) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) { reasoningField; speedField }
                        VStack(alignment: .leading, spacing: 12) { reasoningField; speedField }
                    }
                    Text(store.text("Higher reasoning effort may take longer. Model and effort choices come from the local Codex catalog; use a custom ID if needed. Fast mode depends on model and account availability and may use more quota. It does not change reasoning effort.", "更高推理强度通常耗时更长。模型与强度选项读取本机 Codex 模型目录，也可填写自定义 ID。快速模式取决于模型和账号支持，可能消耗更多额度；速度与推理强度独立。")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    DisclosureGroup(store.text("Runtime paths", "运行环境路径")) {
                        VStack(alignment: .leading, spacing: 12) {
                            field(store.text("Codex executable · optional", "Codex 程序路径 · 可选"), text: $draft.codexPath, placeholder: store.text("Discover automatically", "自动查找"))
                            field(store.text("Node.js executable · wrapper fallback", "Node.js 程序路径 · 包装器回退时使用"), text: optional(\.codexNodePath), placeholder: store.text("Used only when no native executable is found", "仅在未找到原生程序时使用"))
                        }.padding(.top, 8)
                    }
                    Label(AIAssistant.executable(draft.codexPath) ?? store.text("Codex CLI not found", "未找到 Codex CLI"), systemImage: AIAssistant.executable(draft.codexPath) == nil ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 12)).textSelection(.enabled)
                    if let executable = AIAssistant.executable(draft.codexPath), CodexRuntime.requiresNode(executable) {
                        Label(CodexRuntime.node(draft.codexNodePath) ?? store.text("Node.js not found", "未找到 Node.js"), systemImage: CodexRuntime.node(draft.codexNodePath) == nil ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 12)).textSelection(.enabled)
                    }
                    Text(store.text("Uses local codex login credentials. Runs in a temporary directory with read-only sandbox, no approvals and a 120-second timeout. Shell tools, subagents and web search are disabled. Shell tools, MCP and hooks are disabled. The CLI may read files allowed by its sandbox; it is instructed to use only the supplied context. No SSH connection is exposed.", "使用本机 codex login 登录。运行于临时目录，采用只读沙箱、不允许提权，120 秒超时；关闭 Shell 工具、子代理及网页搜索，禁用 MCP 和钩子。CLI 可读取沙箱允许的本机文件，我们要求其只使用提供的上下文；执行模式由 Axon 在绑定会话执行命令，Codex 本身不直接连接 SSH。")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else {
                    field(store.text("Full API endpoint · required", "完整接口地址 · 必填"), text: provider.endpoint, placeholder: "https://…")
                    field(store.text("Model ID · required", "模型 ID · 必填"), text: provider.model, placeholder: store.text("Model supported by your provider", "填写接口支持的模型"))
                    Text(store.text("API Key", "API Key")).foregroundStyle(Palette.muted)
                    SecureField(store.text("Leave blank to keep the saved key", "留空保留已保存密钥"), text: $key).appInput().frame(maxWidth: 500).accessibilityIdentifier("axon-ai-api-key")
                    Text(store.text("Keys are saved in macOS Keychain. ChatGPT uses the OpenAI-compatible Chat Completions API; Claude / CC uses the Anthropic Messages API. ChatGPT web subscriptions do not supply an API key.", "密钥保存到 macOS 钥匙串。ChatGPT 使用 OpenAI 兼容 Chat Completions 接口；Claude / CC 使用 Anthropic Messages 接口。ChatGPT 网页订阅不提供 API Key。")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
            AITaskPolicyFields(policy: Binding(get: { draft.policy }, set: { draft.executionPolicy = $0 }))
            HStack {
                Button(store.text("Revert", "撤销更改")) { load() }.buttonStyle(ChromeButtonStyle())
                Button(store.text("Save AI settings", "保存 AI 设置")) { save() }.buttonStyle(ChromeButtonStyle(prominent: true)).disabled(ai.busy).accessibilityIdentifier("axon-ai-save")
                Text(feedback).font(.system(size: 12)).foregroundStyle(failed ? Palette.danger : Palette.muted)
            }
        }.onAppear { load() }.task(id: draft.backend) { await refreshModels() }.onChange(of: draft.backend) { _, _ in key = ""; feedback = "" }
    }
    private var reasoningField: some View {
        VStack(alignment: .leading, spacing: 6) { Text(store.text("Reasoning effort", "推理强度")).foregroundStyle(Palette.muted); AxonChoiceField(selection: optional(\.codexReasoningEffort), choices: effortChoices, placeholder: store.text("Choose effort", "选择强度"), symbol: "brain", identifier: "axon-ai-codex-effort").disabled(selectedModel == nil || discovering) }.frame(minWidth: 210, maxWidth: 320)
    }
    private var speedField: some View {
        VStack(alignment: .leading, spacing: 6) { Text(store.text("Speed", "速度")).foregroundStyle(Palette.muted); AxonChoiceField(selection: optional(\.codexServiceTier), choices: speedChoices, placeholder: store.text("Choose speed", "选择速度"), symbol: "bolt", identifier: "axon-ai-codex-speed").disabled(selectedModel == nil || discovering) }.frame(minWidth: 210, maxWidth: 320)
    }
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).foregroundStyle(Palette.muted); TextField(placeholder, text: text).appInput() } }
    private func load() { draft = ai.settings; customModel = !draft.codexModel.isEmpty && !catalog.contains { $0.slug == draft.codexModel }; key = ""; feedback = ""; failed = false }
    private func refreshModels(force: Bool = false) async {
        guard !discovering, draft.backend == .codex else { return }
        discovering = true; discoveryError = ""
        defer { discovering = false }
        do {
            catalog = try await CodexModelCatalog.discover(settings: draft, refresh: force)
            customModel = !draft.codexModel.isEmpty && !catalog.contains { $0.slug == draft.codexModel }
        } catch { discoveryError = error.localizedDescription }
    }
    private func saveCodexSelection() {
        var saved = ai.settings
        saved.codexModel = draft.codexModel; saved.codexReasoningEffort = draft.codexReasoningEffort; saved.codexServiceTier = draft.codexServiceTier
        do { try ai.save(saved, key: ""); failed = false; feedback = store.text("Model preferences saved automatically", "模型设置已自动保存") }
        catch { failed = true; feedback = error.localizedDescription }
    }
    private func save() {
        do {
            if draft.backend != .codex { _ = try AIProtocol.request(settings: draft, key: key.isEmpty ? Secrets.readChecked(draft.backend.secretID) : key, prompt: "Validation only") }
            if draft.backend == .codex {
                guard let executable = AIAssistant.executable(draft.codexPath) else { throw AppFailure.message("Codex executable not found. / 未找到 Codex 程序。") }
                _ = try CodexRuntime.launch(executable: executable, settings: draft, environment: ProcessInfo.processInfo.environment)
                _ = try CodexRuntime.arguments(settings: draft, output: "validation-only")
                try CodexRuntime.validate(settings: draft, models: catalog)
                if customModel, draft.codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AppFailure.message("Enter a model ID or choose the default model. / 请填写模型 ID，或选择默认模型。") }
            }
            try ai.save(draft, key: key); key = ""; failed = false; feedback = store.text("AI settings saved", "AI 设置已保存")
        } catch { failed = true; feedback = error.localizedDescription }
    }
}
