---
name: axon-dev-delivery
description: 开发、修复和交付本项目 native/ 下的 Axon macOS 应用，统一现有 UI 配色、布局与操作，并完成实际界面验收、相关测试与授权范围内的打包安装。预览、文档和 skill 修改不重建安装；不适用于 Tabby Web/Electron。
---

# Axon 开发与 UI 验收

## 项目与设计基准

- 产品代码在 `native/`，使用 SwiftUI/AppKit、SwiftTerm、Citadel。检查涉及的成熟页面、公共组件和测试，保留用户已有未提交改动。
- 界面要求与 Axon 当前系统保持一致，操作遵循 macOS 习惯。明确批准的新设计优先于旧实现；生成过的设计图不等于获批，不把示例数据或概念入口擅自变成新功能。
- 用户要求「先看看」时只做预览，等后续实现指令。常规开发自行解决布局、颜色等选择，不让用户重复做首次 UI 检查。
- 仅文档、skill 修改或评估代码时不重建、不安装应用。

## 配色与公共控件

实施前阅读仓库当前定义，不复制另一份主题或自创新色板：

- `native/Sources/TabbyNative/Models.swift` 的 `Palette`：背景、侧栏、卡片、输入、边框、文字、选中和语义强调色。
- `native/Sources/TabbyNative/Design.swift`：`ChromeButtonStyle`、`IconButtonStyle`、`appInput()`、`PaneHeading` 及原生控件封装。
- `HostSelectionFields.swift` 的 `NativeSelectionField`/`AxonChoiceField`：Axon 标准下拉选择外观、整块命中与下方浮层。表单选择复用它们，不用默认 SwiftUI Picker 或仅修改 `.pickerStyle(.menu)` 来冒充标准控件。
- `WorkspaceNavigation.swift`、`PreferencesView.swift`：导航、内容起点、设置提交和反馈。

复用现有浅色外壳与深色顶栏；主操作使用 `Palette.accent`，次操作弱化，SSH/终端和 SFTP 使用既有语义色。成功/失败同时提供文字或图标，不能仅靠颜色。终端与输出区尊重用户终端主题，不将其应用到整个界面。新增控件先复用公共封装，保持点击区域、焦点、禁用态和键盘行为一致。

## 下拉面板与选择项（用户确认的统一规范）

修改下拉、菜单或选择项前，对照用户提供的 [主机选择面板](references/ui/choice-popover.png)、[操作菜单](references/ui/action-menu.png) 与 [方形勾选卡片](references/ui/selection-cards.png)。本规范适用于整个 Axon 的表单、设置、工具栏、弹窗及工作台，不只针对主机编辑页。

- 收起的下拉字段沿用 38pt 高度、Palette.field 背景、8pt 圆角、左侧语义图标、标题和右侧 chevron.down；整块可点，禁用态不可展开。
- 展开面板使用 Palette.sidebar 浅色背景、圆角与锚点箭头；面板内边距 8–16pt，条目圆角 8pt、常规行至少 34pt。悬停／键盘焦点使用 Palette.selected，已选项显示 Palette.accent 勾号；主机等复杂条目可使用白色卡片、标题及 muted 次级信息。分隔线区分操作组，删除等危险操作使用语义危险色。
- 搜索不是每个下拉的必需功能；有搜索时沿用 Axon 搜索字段。长列表可滚动，长名称不能挤出勾号或箭头。不能只统一收起外观而保留展开后的默认 NSMenu／SwiftUI Picker 外观。复用 AxonMenuPopover、AppActionMenu 或现有 JumpHostChooser 的真实浮层样式。
- 单选与多选项均采用图中的方形标记：未选为 muted 描边空方框，选中为 accent 实心方框加白色勾号，整块卡片使用 Palette.selected，未选为浅色背景；文字保持 Palette.text。复用 AxonSelectionMark／AxonSelectionDrawing 或 AxonCheckboxStyle。单选仍互斥，多选仍独立切换；不能因为视觉相同而改变数据或选择语义。开关型设置可保留明确的 switch；普通导航标签不强行加勾选框。
- 保留 Tab、方向键、Return／Space 选择、Escape／点击外部关闭、焦点恢复、无障碍选择状态和底层 enabled。实际验收至少覆盖展开面板、已选／未选、禁用、长名称及键盘选择，不能只截图收起后的字段。

## 布局与操作

- 新增页面同时检查 `App.swift` 路由、`vaultSections`、`WorkspaceNavigation` 和返回行为；进入后侧栏不能消失，原有连接不能被中断。
- 菜单必须具有独立使用价值；文件编辑和传输归属 SFTP。通用外部编辑不绑定 TextStack 品牌，不为单一编辑器新增主导航。
- 不使用横跨整页的输入/下拉框、孤立巨型按钮或无信息的空白卡片。设置表单参照当前约 820–840pt 内容宽度；复杂工作台按信息密度设计，不机械套用统一宽度。
- 使用字段标签及明确必填标识；说明和次要信息弱化。新建空草稿不立即铺满红色错误；提交或编辑相关内容后展示有效校验并保留输入。
- 颜色可选择，可选背景可关闭；作用范围、主机和分组控件紧凑并一致。检查应用实际原生控件尺寸，不能只相信独立渲染测试的外观。
- 操作分清主次，排序边界和不可执行状态禁用。使用 `PreferencesActionButton` 等 `NSViewRepresentable` 按钮时同时传递原生 enabled 与 SwiftUI `.disabled`，验收初次渲染的底层禁用状态；只改变绘制外观不够。整块按钮可点，Tab、焦点、Return/Escape、文本选择/复制及上下文菜单遵循所在页面约定。
- 窄窗口适应布局，避免遮挡、裁切和横向溢出；列表滚动时主要动作仍可达。空、错误、加载、执行、禁用和选中状态都要有清晰反馈。
- 通过 `store.text` 保持中英文文案一致；描述用户行为，不把内部状态码或无关实现细节放入操作界面。
- 最近打开的 SSH/终端始终参与显示；「显示 SFTP」默认关闭，开启后包含 SFTP/本地文件。两类历史独立保留上限，文件记录不能挤掉 SSH；类型清晰标注，按类型重开。

## 交付前 UI 验收（必须执行）

开发代理完成首次实际验收，不把它留给用户：

1. 在真实 SwiftUI/AppKit 渲染中检查受影响页面，使用应用 UI 或 `NSHostingView` 截图；必须打开并观察截图。AI 设计图、代码阅读、编译通过或仅生成截图不能替代检查。
2. 使用代表性的主机、长名称及内容，覆盖正常/空数据和本次涉及的错误、加载、选择、禁用/执行状态。不能只用空列表验证布局；不为验收在用户服务器执行真实命令。
3. 检查支持的窄窗口和常用宽窗口。可参照已有导航测试 1050/1400pt，局部控件另检查收窄布局。确认侧栏、滚动、标签、按钮和主要操作无裁切或遮挡。
4. 验证关键实际路径：进入/返回、筛选/选择、编辑/保存、结果展开等；重要原生控件验证全区域命中、键盘与禁用态。
5. 与相邻成熟页面对照配色、字体层级、间距、输入高度和边框。发现问题自行修复并复验后再交付。

运行对应的有意义测试，尤其路由导航、文件操作、最近记录及行为回归。只有新行为或回归风险需要时补测试；外观变化必须看实际渲染，不能由逻辑测试代替。环境无法渲染或检查交互时报告具体未验证项，不能宣称 UI 已验收。

## 构建与交付

- 应用功能交付读取 `native/scripts/package.sh` 当前版本，递增版本/构建号及对应图标、ZIP 名称；通过相关检查后 release 打包，执行严格 codesign 校验及 ZIP 完整性检查。
- 用户已授权安装时，先备份 `/Applications/Axon.app` 到 `native/dist/backups/`，复制新版到临时安装目录并校验后再替换，失败恢复。遵守工具写权限，skill 本身不增加授权范围。
- 默认保留运行窗口与 SSH/SFTP 会话，不强退、不自动重启；告知用户主动重启后加载新版。只有明确获准中断连接才重启。
- `native/VERIFICATION.md` 记录实际检查、截图位置、测试/跳过项、版本与安装状态；没有执行的检查不能写成成功。
- 最终区分设计预览、源码完成、打包、安装和已运行新版，明确尚未完成项。
