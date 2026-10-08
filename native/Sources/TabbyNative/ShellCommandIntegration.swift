import Foundation
import UserNotifications

/// Hooks live only in this shell; no profile files or server packages are changed.
enum ShellCommandIntegration {
    static func script(token: String) -> String {
        #"""
        _axon_history_b64() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
        _axon_history_report() { printf '\033]7;axon-command;__AXON_TOKEN__;%s\007' "$1"; }
        _axon_history_running=0
        _axon_history_emit() { _axon_history_running=1; _axon_history_started=$SECONDS; _axon_history_report "$(_axon_history_b64 "$1")"; _axon_history_report "meta;$(_axon_history_b64 "$PWD")"; }
        _axon_history_finish() { local _axon_code=$?; if [ "$_axon_history_running" = 1 ]; then _axon_history_report "end;$_axon_code;$((SECONDS-_axon_history_started))"; fi; _axon_history_running=0; _axon_history_report prompt; return "$_axon_code"; }
        if [ -n "${ZSH_VERSION-}" ]; then
        autoload -Uz add-zsh-hook
        add-zsh-hook -d preexec _axon_history_emit 2>/dev/null
        add-zsh-hook -d precmd _axon_history_finish 2>/dev/null
        add-zsh-hook preexec _axon_history_emit
        add-zsh-hook precmd _axon_history_finish
        _axon_history_report ready
        elif [ -n "${BASH_VERSION-}" ]; then
        _axon_history_last=
        _axon_history_begin() { case "$1" in _axon_*|trap\ *|exit|return\ *) return;; esac; [ "$_axon_history_running" = 0 ] || return; local _axon_line _axon_id _axon_cmd; _axon_line=$(HISTTIMEFORMAT= builtin history 1); if [[ "$_axon_line" =~ ^[[:space:]]*([0-9]+) ]]; then _axon_id=${BASH_REMATCH[1]}; if [ "$_axon_history_last" != "$_axon_id" ]; then _axon_history_last=$_axon_id; _axon_cmd=$(printf '%s' "$_axon_line" | sed '1s/^[[:space:]]*[0-9]*[*[:space:]]*//'); _axon_history_emit "$_axon_cmd"; fi; fi; }
        if ! [[ "${PROMPT_COMMAND[*]-}" == *'_axon_history_finish'* ]]; then
        if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare -a'; then PROMPT_COMMAND=(_axon_history_finish "${PROMPT_COMMAND[@]}"); else PROMPT_COMMAND="_axon_history_finish${PROMPT_COMMAND:+; $PROMPT_COMMAND}"; fi
        fi
        if [ -z "$(trap -p DEBUG)" ]; then trap '_axon_history_begin "$BASH_COMMAND"' DEBUG; else printf '%s\n' 'Axon history: existing DEBUG trap retained; command timing unavailable.'; fi
        _axon_history_report ready
        else
        _axon_history_report unsupported
        fi
        """#.replacingOccurrences(of: "__AXON_TOKEN__", with: token)
    }
}

@MainActor enum CommandCompletionNotification {
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier == "org.tabby.native" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func send(_ entry: ExecutedCommand) {
        guard Bundle.main.bundleIdentifier == "org.tabby.native" else { return }
        let content = UNMutableNotificationContent()
        content.title = entry.hostName
        content.body = "Command finished / 命令已完成 · exit \(entry.exitCode ?? 0) · \(Int(entry.duration ?? 0))s"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil)) { _ in }
    }
}
