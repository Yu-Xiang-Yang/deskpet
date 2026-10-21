# DeskPet：macOS 桌面宠物与科研助手

**中文** | [English](README.en.md)

DeskPet 是一款原生 macOS 桌面宠物应用。Live2D 角色以透明窗口常驻于其它窗口之上，具备待机动作、视线跟随、随音乐律动与头顶对话气泡；用户经由键盘与角色对话，对话内容与动作切换均由大语言模型（LLM）生成。应用另提供作息提醒、每日任务简报，以及支持文献、新闻、行情与天气检索并渲染 Markdown 与 LaTeX 的科研模式。

本仓库仅包含 DeskPet 自身的源代码，以 MIT 许可证发布。Live2D Cubism Core 与 Live2D 模型受 Live2D Inc. 的许可协议约束，不包含于本仓库，须由使用者自行获取（见第 5 节）。

## 1. 功能概览

| 模块 | 说明 |
| --- | --- |
| 角色渲染 | Live2D 模型（Cubism 3/4 运行时格式，PixiJS WebGL 渲染），于“设置 → 通用 → 形象”中切换，缺省优先使用 Tororo；未找到模型或 Cubism Core 时以气泡提示 |
| 交互 | 拖动移动并记忆位置，角色可贴至屏幕左右边缘与菜单栏下沿；靠近屏幕顶部、上方容纳不下气泡时，气泡改为显示于角色下方（最新一条紧邻角色）；透明像素区域的点击穿透至下层窗口；单击头部触发摸头反应，单击身体打开对话输入框；全局快捷键（默认 ⌥Space，可更换或关闭）呼出或收起输入框；右键菜单。显示层级三选一（右键菜单“显示层级”或“设置 → 通用”）：始终置顶、普通窗口（可被其它窗口遮挡），或仅在桌面（位于桌面图标之上、所有应用窗口之下，气泡亦随之被遮挡，提醒仍以系统通知送达） |
| 对话气泡 | 用户消息与角色回复以气泡形式堆叠于头顶，最多保留 3 条：新气泡位于底部，较早的气泡上移并降低不透明度，各自计时后淡出（科研回答按长度停留 10–30 s，右上角“×”可立即关闭）；指针停留于气泡上时暂停计时，移开后重新计时；窗口伸出屏幕边缘时，气泡与对话输入框自动收回屏幕内 |
| 对话 | 模型以结构化 JSON 返回 `reply`、`motion`、`remind`、`weather_city`、`remember` 与 `forget` 字段：`motion` 驱动 11 种语义动作，`remind` 创建一次性提醒，`weather_city` 请求查询其它城市天气后再作答，`remember` 与 `forget` 写入或删除记忆库条目 |
| 音乐律动 | 经 Core Audio 进程对象检测其它应用的音频输出（无需授权，持续 1.5 s 以上视为播放）；默认经系统音频监听（Core Audio process tap，需“系统音频录制”授权）分析约 150 Hz 以下的低频能量以检测节拍，由节拍间隔中位数估计速度，驱动抬头状态下的半拍速左右摆动；未获授权或关闭“跟随真实节拍”时按约 112 BPM 摆动；播放期间角色不进入睡眠 |
| 主动行为 | 按设定间隔发出闲聊气泡（本地语料与模型生成按比例混合）；按“自由走动”设置的间隔（偶尔 15–30 分钟、适中 5–10 分钟、活泼 2–4 分钟）沿当前高度跳跃挪位，或在上下方向移动（见“攀爬窗口”），用户打字期间（20 秒内有按键）顺延至停顿后；随机播放舔爪、挠耳等待机动作；用户离开 5 分钟后进入睡眠状态 |
| 猫叫 | 猫形象（`pet-map.json` 中 `"voice": "cat"`）在摸头时发出呼噜声，打招呼、提醒、淘气行为及约 30% 的回复与闲聊时发出叫声；素材为 CC0 真猫录音（见 THIRD_PARTY_NOTICES.md），共 9 段叫声与 1 段呼噜，按情境分为普通、短促、颤音、生气（降调放慢）、委屈五类，每次随机选段并微调播放速率。可在“设置 → 通用”中关闭或调节音量；无声音播放时暂停音频输出，且自身的声音不计入音乐检测 |
| 攀爬窗口 | 仅在“始终置顶”层级下生效。自由走动时，位于地面的角色有一半概率跳上附近应用窗口的上边沿；位于窗口上时，随机沿边沿行走、跳至其它窗口或跳回地面。可站立的边沿取自其它应用的可见窗口（窗口位置信息无需屏幕录制权限），被前方窗口遮挡的部分及距菜单栏过近、容纳不下角色的边沿不计入。脚底位置按模型画面最低不透明像素实时测量，以使爪子恰好落在边沿上。站在窗口上时每 0.2 秒检查一次：窗口移动则随之移动，窗口关闭、最小化或边沿被遮挡则加速下落至下方的窗口边沿或地面。用户将角色拖放至窗口边沿时亦在该处站立 |
| 淘气行为 | 可在“设置 → 通用”中关闭。自发行为每 8–15 分钟至多一次，仅在用户在场且未打字、非科研模式、聊天框关闭时发生，随机为以下三种之一：装睡 40–90 秒；跳至无相邻显示器的屏幕外缘、隐藏约 40% 身体偷看 25–45 秒；跳至鼠标指针下方（单次至多 520 pt）。进行中单击桌宠即结束并作出“被发现”的回应，提醒到达时亦自动结束。另有被动行为：15 秒内摸头 4 次后闹脾气、跳开 260 pt，此后 30 秒内拒绝摸头。播放音乐时以跟随节拍律动为先，上述自发行为暂停，改为与律动相容的三种：每 4–8 分钟以气泡跟唱一次（用户打字时跳过）；每 3–6 分钟于强拍（超过 1 分钟未遇强拍则任一拍）原地跳起一次；连续播放 2 分钟以上的音乐停止 8 秒后请求再放一首（20 分钟内至多一次） |
| 提醒 | 吃饭、上下班（可限定工作日）、久坐、喝水、25 分钟专注计时；以气泡、动作与系统通知同时呈现，通知提供“10 分钟后再提醒”操作 |
| 科研模式 | 角色的一种状态，由右键菜单或状态栏菜单开关；开启期间聊天框的输入交由科研助手回答，问题与回答以气泡呈现：回答气泡支持 Markdown 与 KaTeX、可滚动，单击打开完整对话；角色暂停自由走动 |
| 消息列表 | 菜单栏图标与右键菜单中的“消息列表”子菜单，列出最近 12 个对话；完整窗口支持对话列表、搜索、重命名、删除与继续提问 |
| 每日任务 | 每天首次启动或当天首次有操作时，依次执行“设置 → 每日任务”中的任务（每行一项），结果以气泡呈现并保存为“每日简报 · M月D日”；该功能始终启用检索工具 |
| 记忆库 | 对话中出现的长期有效信息（偏好、过敏、重要日期、长期计划等）由模型经 `remember` 字段自动写入，并以“📝 记下了”气泡提示；用户可要求遗忘（`forget` 字段按关键词删除）。条目在“设置 → 记忆”中查看、手动添加与删除；按时间由新到旧附加于闲聊、科研与每日任务的系统提示词（上限 2400 字符）。去重规则：规范化后相同、互相包含，或仅存在少量字符插入（较短文本按序保留于较长文本且长度比 ≥ 0.7）时，以新表述替换旧条目；词语替换视为不同事实 |
| Claude 用量 | 若已安装 [Claude Usage Widget](https://github.com/Yu-Xiang-Yang/claude-usage-widget)，只读其写入 `~/Library/Application Support/ClaudeUsageWidget` 的 `quota.json` 与 `history.json`（桌宠本身无需登录）：菜单“Claude 用量”列出 5 小时额度、每周额度及按模型计的每周额度（含重置倒计时）、今日与近 7 天的 token 数与估算成本；“让桌宠报告一下”以气泡播报；闲聊的上下文附带用量，可直接询问剩余额度。每分钟读取一次：5 小时或每周额度达到 70%、90% 时各提醒一次（每个额度窗口内），5 小时额度用至 90% 以上后进入新窗口时提示额度恢复；数据超过 20 分钟未更新时不提醒。可在“设置 → 提醒”中关闭 |
| 天气变化提醒 | 依据“主人信息”中的城市，每 20 分钟获取一次 Open-Meteo 逐小时预报并与当前天气比较：当前无降水而 3 小时内降水概率 ≥ 60%（或降水天气代码且概率 ≥ 40%）时提醒带伞；6 小时内出现雷暴、大雨、大雪或风速 ≥ 45 km/h 时发出预警（两类各 6 小时内至多一次）；17:00 后若明日最高气温较今日变化 ≥ 6 °C 或明日降水概率 ≥ 70%，每日提醒一次。提醒以气泡、动作与系统通知呈现，可在“设置 → 提醒”中关闭或立即检查 |
| 主人信息 | “设置 → 主人信息”中的所在城市（闲聊上下文附带当地天气，缓存 30 分钟）与自由文本背景，附加于闲聊、科研与每日任务的系统提示词 |
| 检索工具 | Claude 另可使用服务端 `web_search`；两种服务均可调用客户端工具 `search_arxiv`、`search_semantic_scholar`、`search_news`、`get_stock_quotes`、`get_weather` 与 `fetch_webpage`（详见第 6 节） |

## 2. 系统要求

- macOS 14 或更高版本（音乐节拍跟随需要 macOS 14.2 或更高版本）；
- Xcode Command Line Tools（提供 `swiftc`，无需完整 Xcode）；
- 构建时需要网络连接，用于下载固定版本的前端库。

## 3. 构建与安装

```bash
./build.sh
```

```bash
./build.sh install
```

`./build.sh` 生成 `build/DeskPet.app`；`./build.sh install` 另将其复制至 `/Applications`（无写入权限时为 `~/Applications`）。首次构建时，`scripts/fetch-vendor.sh` 下载以下前端库至 `Resources/web/vendor/` 并逐一校验 SHA-256：pixi.js 6.5.10、pixi-live2d-display 0.4.0（Cubism 4 构建）、marked 12.0.2、DOMPurify 3.1.6、KaTeX 0.16.11（含 woff2 字体）、highlight.js 11.10.0。运行时不访问任何 CDN。

未配置签名证书时，应用以 ad-hoc 方式签名，每次重新构建后签名改变，macOS 将再次请求钥匙串与“系统音频录制”授权。在“钥匙串访问 → 证书助理 → 创建证书…”中创建名称为 `DeskPet Code Signing`、身份类型为“自签名根证书”、证书类型为“代码签名”的证书后，`build.sh` 即以其签名，授权在重新构建后仍然有效。

## 4. 模型服务配置

首次启动且钥匙串中不存在 API key 时，应用自动打开“设置 → 模型”页。

| 服务 | 配置项 | 说明 |
| --- | --- | --- |
| Claude (Anthropic) | API key、模型名（默认 `claude-opus-5-5`）、拒答回退开关 | 通过 Messages API 流式调用；宠物对话使用 `effort: low` 与结构化输出，科研对话使用 `effort: high`；开启回退时，对支持的模型附带 `fallbacks: "default"`（beta `server-side-fallback-2026-07-01`） |
| OpenAI 兼容接口 | Base URL、模型名、API key | 预设 OpenAI、DeepSeek、通义千问（DashScope）、Moonshot 与 Ollama；本地服务（`localhost`）可不填 key；宠物对话使用 JSON 模式，科研检索依赖函数调用（tools） |

API key 保存于 macOS 钥匙串（service 为 `local.deskpet`），不写入磁盘明文或 UserDefaults。部分模型（如 DeepSeek）偶尔将工具调用以其原生标记写入正文；应用在流式输出中隐藏此类标记，并将其解析为工具调用执行。

## 5. Live2D：获取与安装

Live2D Cubism Core 依据 Live2D Proprietary Software License 分发，Live2D 示例模型依据 Live2D Free Material License 提供；两者均禁止再分发，因此本仓库不包含任何 Live2D 文件。仓库中的 `Resources/model-maps/` 仅包含本项目为示例模型 Tororo 与 Hijiki 编写的动作映射（`pet-map.json`），不含模型数据。

1. 在 [Cubism SDK for Web](https://www.live2d.com/en/sdk/download/web/) 页面阅读并同意许可协议后，下载 SDK（其中 `Core/live2dcubismcore.min.js` 即 Cubism Core）。
2. 在 [Tororo & Hijiki](https://www.live2d.com/en/learn/sample/tororo-hijiki/) 页面阅读并同意示例数据使用条款后，下载模型。
3. 运行安装脚本（参数可为 zip 文件或已解压的文件夹）：

```bash
scripts/install-live2d.sh ~/Downloads/CubismSdkForWeb-5-r.5.zip ~/Downloads/tororo_hijiki_ja.zip
```

脚本将 Cubism Core 与两只猫的运行时文件复制至 `~/Library/Application Support/DeskPet/models/`，并附上对应的 `pet-map.json`。其它 Cubism 3/4 模型可直接放入该目录下的子文件夹，再于“设置 → 通用 → 形象”中选择；映射文件格式见 [Resources/models/README.md](Resources/models/README.md)。

使用 Live2D 示例模型的作品须标注：This content uses sample data owned and copyrighted by Live2D Inc.

**发布注意事项。** 根据 Live2D 的发布许可规定，允许用户加载任意模型的应用可能属于“可扩展型应用”（Expandable Application），此类应用的公开发布不适用个人及小规模事业者的免许可条款，须事先经 Live2D 审核并签订专门的发布许可协议。本仓库仅以源代码形式发布；分发预编译应用之前，应向 Live2D 确认适用条款。

## 6. 科研模式与检索工具

- 进入方式：角色右键菜单或状态栏菜单中的“科研模式”开关。开启后首个问题新建一个科研对话，此后的问题追加至该对话；“开始新的科研话题”另起对话；“联网检索（较慢）”开关控制是否提供检索工具。
- 回答篇幅：默认先给出结论，正文控制在 300–600 字；用户明确要求时再展开。
- 工具循环：单轮最多 3 次模型调用（至多 2 轮工具调用，第 3 次调用禁止工具）；同一轮的全部工具调用并行执行，结果合并为一条消息回传；`pause_turn` 时原样回传后继续。
- 检索工具：

| 工具 | 数据来源 | 说明 |
| --- | --- | --- |
| `search_arxiv` | arXiv API | 预印本检索 |
| `search_semantic_scholar` | Semantic Scholar API | 已发表论文检索 |
| `search_news` | Bing News RSS，失败时 Google News RSS | 新闻按时间倒序 |
| `get_stock_quotes` | Yahoo Finance | 股票、指数与 ETF 行情，6 位 A 股代码自动换算为 `.SS`/`.SZ` |
| `get_weather` | Open-Meteo | 当前天气与 1–7 天预报，支持中文地名 |
| `fetch_webpage` | 任意公网网页 | 仅允许公网 http/https 地址，提取正文至约 6000 字符 |

- 稳定性：单次请求超时 12 s；HTTP 429/503 仅重试一次，同一主机此后 60 s 内直接返回错误，以便模型改用其它来源；相同检索 10 分钟内复用缓存。
- 历史回放：Claude 的助手消息以原始内容块保存，并在后续请求中原样回传，使历史保持只追加；切换服务后，历史以纯文本形式回放。

## 7. 数据存储与网络访问

| 内容 | 位置 |
| --- | --- |
| 对话记录 | `~/Library/Application Support/DeskPet/conversations/*.json` |
| 记忆库 | `~/Library/Application Support/DeskPet/memories.json` |
| Live2D 模型与 Cubism Core | `~/Library/Application Support/DeskPet/models/` |
| 设置、窗口位置、提醒与天气提醒状态 | UserDefaults（域 `io.github.yu-xiang-yang.deskpet`；早期版本的 `local.deskpet` 设置在首次启动时自动迁移） |
| API key | 钥匙串（service `local.deskpet`） |

应用仅向以下地址发起网络请求：所选模型服务的 API 地址、`export.arxiv.org`、`api.semanticscholar.org`、`www.bing.com`、`news.google.com`、`query1.finance.yahoo.com`、`api.open-meteo.com` 与 `geocoding-api.open-meteo.com`，以及模型通过 `fetch_webpage` 指定的公网网页。系统音频仅在本机实时分析节拍，不录制、不保存、不上传。环境变量 `DESKPET_DIR` 可覆盖数据目录并启用测试钥匙串项，供测试使用。

## 8. 目录结构

```
DeskPet/
├── build.sh                  构建与安装脚本（swiftc，无 Xcode 工程）
├── Sources/
│   ├── Core/                 与界面无关的逻辑：JSON、SSE 解析、回复解析、提醒规则、天气提醒规则、记忆去重、本地化
│   ├── LLM/                  LLMProvider 协议、Anthropic 与 OpenAI 兼容实现、检索工具与天气服务
│   └── App/                  AppKit/SwiftUI：宠物窗口、对话输入框、消息列表、科研引擎、设置、提醒、记忆库、天气监测、音乐监测
├── Resources/
│   ├── web/                  pet.html/js/css（角色与气泡）、research.html/js/css（消息列表）、md.js（Markdown 与公式）
│   ├── model-maps/           示例模型 Tororo 与 Hijiki 的动作映射
│   └── models/               随应用打包的 Live2D 模型目录（默认为空）
├── Tests/                    自检、集成测试与模拟 API 服务器
└── scripts/                  前端库下载、Live2D 安装、图标生成、测试脚本
```

## 9. 测试

```bash
scripts/selftest.sh
```

```bash
scripts/integration-test.sh
```

- `selftest.sh` 编译 `Sources/Core`、`Sources/LLM`、`Sources/App/MemoryStore.swift` 与 `Tests/main.swift`，共 98 项检查，覆盖 SSE 解析、两种流式累加器（含正文中工具调用标记的隐藏与解析）、服务端回退后的内容块清理、请求体字段、宠物回复解析（含记忆字段）、提醒规则、记忆去重与持久化、天气变化提醒规则，以及新闻、行情、网页与天气工具的辅助函数。
- `integration-test.sh` 启动 `Tests/mock_server.py`（模拟两种 API 的流式响应，按 7 字节分片写出），以真实 HTTP 流验证工具循环、thinking 块原样回放、回退请求头、HTTP 错误信息与 JSON 模式；检索工具调用真实的 arXiv、Semantic Scholar、新闻、行情与天气接口（需要网络）。

## 10. 许可与致谢

- DeskPet 源代码以 [MIT 许可证](LICENSE) 发布。
- 第三方组件与数据来源的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 天气数据由 [Open-Meteo.com](https://open-meteo.com/) 提供（CC BY 4.0）。
- Live2D 及 Cubism 为 Live2D Inc. 的商标或注册商标；本项目与 Live2D Inc. 无关联。
