import SwiftUI

/// Explain the terminal's actual color roles without assigning fixed semantics
/// to application output. Shells and programs decide which ANSI index to emit.
struct TerminalColorGuide: View {
    let preferences: Preferences
    let chinese: Bool
    private func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }
    private var ansi: [String] { TerminalTheme.effectiveANSI(preferences) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text("How terminal colors work", "颜色如何生效")).font(.system(size: 14, weight: .semibold))
            Text(text("19 colors = 3 base colors + 8 normal ANSI colors + 8 bright ANSI colors.", "完整方案共 19 色：3 个基础色 + 8 个常规 ANSI 色 + 8 个高亮 ANSI 色。"))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            role(text("Text", "文字"), color: preferences.foreground, explanation: text("Default text when the program has not requested a color. It does not recolor all output.", "程序未指定颜色时的默认文字；不会覆盖程序主动指定的输出颜色。"))
            role(text("Background", "背景"), color: preferences.background, explanation: text("The terminal canvas and default text background. A program may request a different background.", "终端底色与默认文字背景；程序也可以为部分文字指定其他背景色。"))
            role(text("Cursor", "光标"), color: preferences.cursorColor, explanation: text("The input caret. Its block, bar or underline shape is configured under Terminal.", "输入位置的光标；方块、竖线或下划线形状在「终端」中设置。"))
            Divider()
            HStack {
                Text(text("ANSI role", "ANSI 色位")).frame(width: 52, alignment: .leading)
                Text(text("Normal", "常规")).frame(width: 54, alignment: .leading)
                Text(text("Bright", "高亮")).frame(width: 54, alignment: .leading)
                Text(text("Example use · chosen by the program", "常见用途示例 · 由程序决定"))
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
            ForEach(0..<8, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Text(names[index]).frame(width: 44, alignment: .leading)
                    swatch(ansi[index], number: index).frame(width: 54, alignment: .leading)
                    swatch(ansi[index + 8], number: index + 8).frame(width: 54, alignment: .leading)
                    Text(examples[index]).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11))
            }
            Text(text("ANSI slots can color both text and text backgrounds. Bright slots may also be used for bold output. The sample uses blue for folders, green for executables, and red for errors; these are examples, not rules. Actual output follows the program, shell theme and LS_COLORS settings.", "ANSI 色位既可用于文字，也可用于文字背景；粗体输出也可能采用高亮色。预览以蓝色表示目录、绿色表示可执行文件、红色表示错误，这只是示例。实际用色由程序、Shell 主题和 LS_COLORS 等设置决定。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text(text("24-bit RGB output requests its own colors and bypasses this ANSI palette. The extended 256-color slots 16–255 are not edited here.", "24 位 RGB 真彩色输出直接指定颜色，不使用此 ANSI 调色板；256 色中的扩展色位 16–255 不在这里编辑。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(text("Choose a scheme → edit base or ANSI colors → optionally Save as custom → Save at the bottom. Selection and edits stay in the draft until that final Save, which also updates open terminals.", "选择方案 → 调整基础色或 ANSI 色 → 可另存为自定义 → 点击底部保存。方案选择和编辑都先保留在草稿中，最后保存才会更新已打开终端。"))
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("axon-terminal-color-guide")
    }
    private var names: [String] { chinese ? ["黑", "红", "绿", "黄", "蓝", "紫", "青", "白"] : ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"] }
    private var examples: [String] { chinese ? ["暗色细节、背景", "错误、失败提示", "成功提示、可执行文件", "警告、强调内容", "目录、链接", "分支、关键字", "信息提示、特殊文件", "普通内容、浅色文字"] : ["Dark details, backgrounds", "Errors or failures", "Success, executables", "Warnings, emphasis", "Folders, links", "Branches, keywords", "Information, special files", "Content, light text"] }
    private func role(_ title: String, color: String, explanation: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(Color(hex: color)).frame(width: 20, height: 20).overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 12, weight: .medium)); Text(explanation).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func swatch(_ color: String, number: Int) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(Color(hex: color)).frame(width: 20, height: 14).overlay(RoundedRectangle(cornerRadius: 2).stroke(Palette.border, lineWidth: 0.5)); Text(String(number)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
    }
}
