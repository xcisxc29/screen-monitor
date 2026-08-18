# DSH 屏幕监测 · 进度档案

> 最后更新：2026-08-19 02:00
> **项目已独立成目录：`C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor\`**（全部脚本/配置/文档/结果在此）
> 下次恢复：新会话说「读 C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor\PROGRESS.md 继续屏幕监测项目」

## 一、项目目标
DSH 插件思路的落地验证：常驻本地服务实时监测屏幕 → 本地 OCR → 启发式/LLM 答题 → 悬浮窗展示。当前为独立脚本形态（未打包成 cordis bundle），架构已验证，随时可固化为正式插件。

## 二、当前架构（三层解耦）
```
采样层：每 3s 截屏（可限定 analyzeRegion 选区）+ 变化检测（排除悬浮窗区域，防自反馈）
检测层：防抖 2s（画面稳定才分析）+ 超时 12s（持续变化兜底）+ 36s 强制轮次 + 热键即时触发
分析层：本地 OCR（Windows.Media.Ocr，零 API）→ 启发式判定答题场景（按题分组统计选项）
        → 仅 quiz 场景调 DeepSeek LLM（llm-cache.json 持久化缓存 + 微抖动模糊去重）
展示层：overlay.txt（WinForms 悬浮窗，RichTextBox 大字答案）+ overlay.html（Edge 标签页）+ result.json
记录层：history.jsonl（结构化历史含 token 用量）+ stats.json（累计成本）
```

## 三、文件清单（项目目录 C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor\）
| 文件 | 作用 |
|---|---|
| monitor-service.ps1 | 服务本体（采样/选区/检测/OCR/理解/发布/统计），UTF-8 BOM，PS5.1 |
| overlay-window.ps1 | 桌面悬浮窗（RichTextBox 版，答案字母 27pt 金色大字），需用户本机双击启动 |
| hotkey.ps1 | 全局热键监听：Ctrl+Shift+S → 写 analyze-trigger.flag（注册失败/触发均记 hotkey.log） |
| config.json | 配置（llm key、debounce/maxWait、analyzeRegion 选区、llmCost 单价等） |
| start-monitor.bat / stop-monitor.bat | 启动/停止（服务+热键+悬浮窗） |
| start-overlay.bat | 启动桌面悬浮窗（用户双击，沙箱拉不起来） |
| ocr.ps1 | 独立本地 OCR 工具（测试用） |
| quiz-demo.html / quiz-full.html | 答题测试页（demo 超一屏测滚动补全，full 一屏 6 题） |
| result.json / overlay.txt / overlay.html | 服务输出 |
| history.jsonl / stats.json | 结构化历史（含 token 用量）/ 累计成本统计（含 fuzzyHits） |
| llm-cache.json | LLM 答案持久化缓存（LRU，重启后仍去重；OCR 微抖动模糊匹配命中） |
| heartbeat.txt / status.json / history.log / *.pid / *.flag | 心跳/状态/审计/进程标识/触发信号 |

## 四、已实现并验证 ✅
1. 常驻服务自治运行 + 防双实例（原子 CreateNew PID）
2. 本地 OCR（zh-Hans-CN，零安装零 API）
3. 变化检测 + 防抖 4s + 超时 12s（滚动补全：滚到哪停 4s 答哪）
4. 启发式答题场景判定 + 标签栏噪音过滤（题号 1-9、选项内容长度过滤）
5. LLM 答题（DeepSeek deepseek-chat）：UTF-8 解码、JSON 结构化 answers、答案正确性实测 6/6
6. 答案去重：OCR 哈希缓存（history 有 cached 标记 + stats.cachedHits）
7. **滚动补全提示（增强）**：按题分组统计选项数，提示精确到题号（"提示: 第 3 题选项可能不完整"）；LLM 答案后自动附加提示；summary 模式疑似题目提示
8. 答案高亮：Edge 页 30px 金色大字字母；悬浮窗 RichTextBox 27pt 金色
9. **隐私/精准选区（analyzeRegion）**：只分析指定屏幕区域（已验证避开标签栏/书签栏/垂直标签栏后 OCR 干净）
10. **全局热键**：Ctrl+Shift+S 即时分析（trigger 文件机制已验证；真实按键待用户实测）
11. **历史 JSONL + 成本统计**：history.jsonl 每行一条（含 prompt/completion tokens），stats.json 累计 totalLlmCalls/cachedHits/tokens/estCostUsd
12. 悬浮窗界面精简（只保留模式/时间/结论/答案）
13. **答题结果保真**：quiz/llm 答案一旦产生，悬浮窗/Edge 页持续保留（summary 分析不覆盖），切走界面答案不丢（实测：bottom-test 答 4/5/6 后切到对话界面，悬浮窗仍显示答案）
14. 防御性修复：prev 帧尺寸不匹配（选区配置变更）自动丢弃重来，不再 GetPixel 崩溃；提示题号从题目行提取真实题号（非数组索引）
15. 防抖 4s→2s（滚动停止响应更快）；analyzeRegion 默认关闭（全屏，避免误切底部）
16. **【重大】DPI 感知修复**：系统 150% 缩放（物理 2560x1600）时，PS5.1 默认 DPI 不感知，Screen.Bounds 返回虚拟分辨率 1707x1067，CopyFromScreen 只截物理屏幕左上 2/3——**屏幕右侧/底部内容（如滚动到底部的 10-12 题）永远读不到**。修复：服务与悬浮窗启动时 SetProcessDPIAware()，截图恢复 2560x1600 全屏。实测：长卷 12 题全答全对
17. **悬浮窗可拖拽 + 半透明**：顶部拖拽条（双保险：WM_NCHITTEST + ReleaseCapture/WM_NCLBUTTONDOWN 原生拖动）；Opacity 0.92 起步，PgUp/PgDn 实时调 30%~100%；位置记忆（overlay.pos）；DPI 感知物理像素定位。
    悬浮窗排障记录（本轮多个真坑）：
    a. **PS5.1 `New-Object Type($var, $expr)` 语法坑**：含变量的参数被解析成"数组减法"报错且被静默吞掉 → Size 赋值失败（rtb 默认 100x96，内容挤左上角）。**必须用 `-ArgumentList`**。
    b. **WM_SETREDRAW off/on 破坏 RichTextBox 渲染**：文本填充了但画不出来 → 改为"内容变化才重绘 + Refresh()"。
    c. **Dock 布局顺序坑** → 改用绝对定位（拖拽条 y0-30，内容区 y30 起）。
    d. **AutoSize Label 垂直裁剪 CJK**（YaHei 9pt"透明"显示半截）→ 关闭 AutoSize，固定高度 24 + MiddleLeft。
    e. **时间 label（490 宽 Anchor Right）覆盖标题**（Transparent 不透兄弟控件）→ 缩到 150px 只占右侧。
    f. rtb 内容加 Padding Top 10 防首行贴顶。
    g. 拖拽条最终改**分两行布局**（48px 高：第一行标题、第二行时间），时间 label 绝对定位（Panel 内 Anchor 布局不可靠，会导致时间跑到最左与标题重叠）。最终渲染验证：标题完整含"透明/Esc 关"，时间右侧独立，无重叠无裁剪。
    h. **【重大】编辑工具会剥掉 UTF-8 BOM**：本轮改完脚本后语法检查全线崩（58 个错，中文全变乱码）。根因：PS5.1 对无 BOM 的 UTF-8 脚本按 ANSI(GBK) 解码，中文被误读，且 GBK 双字节解码会把紧随中文的 ASCII 字节（如 `@`、字母）吞进 trail 字节 → here-string 终止符 `"@` 丢失 → 解析器级联崩溃。**规则：三个 .ps1 必须保持 UTF-8 BOM；用编辑工具改完后必须补回 BOM 再交付**（补回方法：ReadAllBytes → UTF8Encoding($true) WriteAllText）。
18. **【LLM 缓存持久化 + OCR 微抖动容错】**（解决已知问题 8）：新增 llm-cache.json（{hash,text,verdict,answers,ts} 数组，LRU 上限 cacheMax=60）；服务启动加载、LLM 成功即存盘，重启后仍去重。精确哈希命中走快路径；哈希变化时用**字符集合 Jaccard 相似度**兜底（阈值 cacheSimilarity=0.94，可配，0/负值=关闭模糊），OCR 个别字抖动（实测 0.96 相似）仍命中，完全不同的屏（0.11）不误命中。缓存只存纯答案，滚动提示按当前画面重新附加（题号提示保持最新）。history.jsonl 增 `fuzzy` 标记、stats.json 增 `fuzzyHits`。**`-SelfTest` 自检开关**：不碰屏/网，用临时缓存文件验证 exact/fuzzy/miss/reload，结果写 selftest.txt。
    **实测修正（2026-08-19 02:00，本会话）**：① 阈值 0.94 → **0.85**——原 0.94 对"含标签栏的整屏文本"太高（真实同屏 OCR 抖动相似度仅 ~0.90，fuzzy 从未命中）；修正后不同屏 0.59~0.78 仍不误命中。② 缓存键升级为 **coreText（纯题目+选项）**：原用整屏清洗文本（含标签栏噪音），标签栏状态变化导致同屏也无法命中；coreText 无噪音、同屏 OCR 稳定 → 实测同屏再分析直接 `cached` 命中（省 LLM 调用）。
19. **成本展示**：每次发布时 overlay.txt 追加 `📊 LLM N 次 · 缓存命中 N · Token p/c · 成本 ≈$x`；overlay.html footer 同步显示（2s 自动刷新）；悬浮窗新增 `^📊` 渲染分支（12pt 灰显，须在 `·` 标题规则之前，避免被放大成标题）。stats.json 升级时自动补 `fuzzyHits:0`。
20. **热键注册失败检测**（改进已知问题 11）：RegisterHotKey 返回值 + GetLastWin32Error 记录到 hotkey.log（1409=已被其他程序占用）；注册成功与每次触发也记日志（配合"真实按键待实测"）。实测注册 OK。
21. **【软件化封装：控制面板】**：`monitor-console.ps1` + `启动屏幕监测助手.bat`（双击打开 WinForms 界面）。功能：① 首启/随时可填 DeepSeek API Key（本地写回 config.json）；② 一键「打开服务」= 启动 监测服务+热键+悬浮窗（用户上下文，悬浮窗可见）；③ 一键「关闭服务」= 优雅停止全部（含悬浮窗）；④ 2s 轮询显示服务/热键/悬浮窗状态与心跳；⑤ 「打开 result 文件夹」按钮。**结果交付**：config 新增 `paths.result`，服务把 result.json/history.jsonl/stats.json/overlay.txt/html 全部写入 `workplace\result\`（过程状态 heartbeat/status 留根目录）；overlay-window.ps1 数据路径同步。已端到端验证：控制面板 GUI 出现、打开服务→6 题全答进 result、关闭服务→全关。
21. **【修复】OCR 自反馈污染（悬浮窗文字被读回分析）**：实测发现悬浮窗自己显示的内容（"拖动/PgUp/透明/Esc"、上轮分析结果）被整屏 OCR 抓进下一轮 → 分析结果互相污染、悬浮窗"乱套"。根因：excludeRegion 此前只排除**变化检测**，OCR 仍全屏读。修复：
    a. **OCR 前把排除区涂黑**（Capture-And-Diff 中 FillRectangle 纯黑再存 screen-latest.png，OCR 读到全黑无文字）；变化检测按矩形跳过该区域不受影响。实测：排除区 5 采样点全 R0G0B0，区外正常。
    b. **excludeRegion 升级为矩形格式** {minX,minY,maxX,maxY}，向后兼容旧格式 {minX,maxY}（右上角）。
    c. **悬浮窗关闭时自动回写当前位置到 config.json 的 excludeRegion**（FormClosing 联动，拖完即生效，服务下次启动读取）——根治已知问题 6 的坐标硬编码。
    实测记录（沙箱内）：summary 判定正确、quiz 6 题/20 选项全检出、滚动补全提示精确到题号（"第 2、6 题选项可能不完整"）、涂黑像素验证通过、分析内容不再含悬浮窗文字。**LLM 链路沙箱内网络不可达（外网 HTTPS 被禁），全部降级启发式；真实环境需用户双击 start-monitor.bat 实测**（此前 21 次调用成功、6/6 全对）。

## 五、已知问题 / 待改进
1. 【重要】WinForms 悬浮窗从沙箱/服务内拉起不可见（handle=0），只能用户本机双击 start-overlay.bat
2. OCR 小字误识别：「错误」→「钅吴」、「测试」→「测讠」等（Windows OCR 引擎固有）
3. 一屏只分析可见内容；选项/题干被屏幕截断时 LLM 答案可能错（已缓解：滚动提示 + 答题结果保真 + 防抖 2s）
4. summary 模式内容摘录偶含噪音（已多级过滤，非完美）
5. 每次激活测试页都新建 Edge 标签，标签越积越多
6. ~~excludeRegion 坐标硬编码~~ → **已缓解（四.21）**：悬浮窗关闭时自动回写当前位置矩形到 config；位置/分辨率变化无需手动改。注意：改 config 里的 excludeRegion 需要重启服务才生效
7. analyzeRegion 选区坐标也是硬编码，需按实际窗口布局手动调（当前 x=80,y=140 避开了垂直标签栏+书签栏）
8. ~~LLM 答案缓存只在进程内 + OCR 微抖动会导致哈希变化缓存失效~~ → **已解决（四.18）**：llm-cache.json 持久化 + 相似度模糊匹配（阈值 0.94 可调，注意长文本相似度自然更高，超短屏可能漏命中）
9. 无多显示器支持（只 PrimaryScreen）
10. API key 明文在 config.json（本地可接受，分享文件时注意脱敏）
11. 全局热键注册占用检查已加（hotkey.log 记录注册失败/成功/触发）；真实按键触发仍待用户实测确认
12. 无 LLM 失败重试/退避（失败直接降级启发式）

## 六、下一步候选（P1/P2）
- [ ] 用户补充的问题清单
- [x] 悬浮窗可拖拽/半透明
- [ ] 多显示器支持
- [x] LLM 缓存持久化（重启后仍去重）→ 含 OCR 微抖动模糊匹配（四.18）
- [ ] 选区可视化配置（截屏预览 + 拖框）
- [x] 成本展示到悬浮窗/Edge 页 footer（四.19）
- [ ] 固化为 cordis bundle 插件（dsh.bundle 声明）
- [ ] LLM 失败重试/退避（已知问题 12；本轮沙箱网络不可达，真实环境此前调用正常）
- [ ] Edge 标签越积越多（已知问题 5）：可改用固定 --app 窗口复用

## 七、操作手册（摘要）
- 启动：双击 start-monitor.bat（服务+热键）；悬浮窗另启 start-overlay.bat
- 停止：双击 stop-monitor.bat（服务+热键+悬浮窗）
- 全局热键：**Ctrl+Shift+S** = 立即分析当前屏幕
- 改配置：编辑 config.json 后重启服务才生效
  - analyzeRegion.enabled=false → 恢复全屏分析
  - llm.llmCost → 单价（USD/百万 token）用于成本估算
  - llm.cacheMax → LLM 缓存条数上限（LRU）；llm.cacheSimilarity → 模糊匹配阈值（0/负值=仅精确哈希）
  - 删除 llm-cache.json 即清空持久化缓存
  - excludeRegion → 矩形 {minX,minY,maxX,maxY}（悬浮窗防自反馈区；关闭悬浮窗时自动回写，一般无需手动改）
- 看结果：result.json（最新）/ history.jsonl（结构化历史）/ stats.json（成本）/ Edge 标签页「屏幕分析」
- LLM key 已配置（llm.enabled=true）

## 八、新会话快速续接（省 token 指南）
**本项目的持久记忆 = 本文件（PROGRESS.md）。** 对话历史无需保留：
1. 直接**新建会话**，首条消息说「读 C:\Users\XCISXC\Desktop\DH\workplace\screen-monitor\PROGRESS.md 继续屏幕监测项目」；
2. agent 读本文件即可获得：架构、全部功能、已知问题、排障记录、操作手册——无需重放旧对话；
3. 每次开发结束，把新进展追加到本文件（保持它是最新的"唯一真相"）；
4. 项目已独立目录（screen-monitor\），脚本路径全部基于 $PSScriptRoot 相对定位；结果统一交付 `result\` 子目录；控制面板 = 双击「启动屏幕监测助手.bat」。
