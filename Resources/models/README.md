# Live2D 模型目录

每个子目录存放一个 Cubism 4 模型（`*.model3.json` 及其引用的 `.moc3`、贴图、动作与表情文件）。本目录中的模型在构建时打包进应用；用户模型亦可放入 `~/Library/Application Support/DeskPet/models/`，无需重新构建。Live2D 模型及 Cubism Core 不纳入版本库，使用前须确认其许可条款。

## pet-map.json

模型目录下可选的 `pet-map.json` 将应用的语义动作映射至该模型的动作组（`group`）、组内序号（`index`，省略时随机）与表情（`expression`）。语义动作共 11 种：`idle`、`happy`、`wave`、`nod`、`shake`、`think`、`surprised`、`sleepy`、`shy`、`eat`、`sad`。

```json
{
  "scale": 0.95,
  "offsetY": 0,
  "defaultExpression": "F01",
  "hitAreas": { "head": ["Head", "Face"] },
  "motions": {
    "idle":      { "group": "Idle" },
    "happy":     { "group": "TapBody", "index": 0, "expression": "F05" },
    "wave":      { "group": "TapBody", "index": 1 },
    "nod":       { "group": "TapBody", "index": 2 },
    "shake":     { "group": "TapBody", "index": 3, "expression": "F03" },
    "think":     { "group": "Idle", "expression": "F06" },
    "surprised": { "group": "TapBody", "index": 4, "expression": "F04" },
    "sleepy":    { "group": "Idle", "expression": "F07" },
    "shy":       { "group": "TapBody", "index": 5, "expression": "F02" },
    "eat":       { "group": "TapBody", "index": 0, "expression": "F05" },
    "sad":       { "group": "Idle", "expression": "F03" }
  }
}
```

| 字段 | 含义 |
| --- | --- |
| `scale` | 模型相对于舞台（320×340 CSS 像素）适配尺寸的缩放系数，默认 0.95 |
| `offsetY` | 模型底边的竖直偏移（CSS 像素，正值向下） |
| `defaultExpression` | 回到 `idle` 时恢复的表情 |
| `hitAreas.head` | 视为“头部”的 HitArea 名称（子串匹配，不区分大小写）；模型未定义 HitArea 时，以包围盒上部 32% 作为头部 |
| `motions` | 语义动作映射；未列出的动作按默认规则选取动作组。条目可含 `params`（参数 ID → 目标值），在该动作期间平滑覆盖模型参数，用于模型未提供的表情（如耳朵下垂） |
| `idleActions` | 待机期间随机播放的动作列表（`group`、`index`），间隔由 `idleActionSeconds`（秒，默认 `[18, 45]`）决定 |
| `states.sleep` | 睡眠状态下持续覆盖的参数（如闭眼、低头） |
| `gaze` | 视线跟随所驱动的参数及幅度；省略时，若模型使用 Cubism 2 风格参数名（`PARAM_ANGLE_X` 等）则自动采用对应映射 |
| `name`、`look` | 设置界面中显示的名称；提供给语言模型的外形描述 |
| `credit` | 模型要求的版权标注，显示于“设置 → 通用 → 形象”下方 |

动作组与表情名称以模型的 `*.model3.json` 中 `FileReferences.Motions` 与 `FileReferences.Expressions` 的定义为准。说话期间，应用逐帧设置 `Groups` 中 `LipSync` 组所列参数（缺省为 `ParamMouthOpenY`）以驱动口型。

## 兼容性说明

Cubism Core 5.1 及以后版本将绘制顺序由 `drawables.renderOrders` 移至 `Model.getRenderOrders()`；pet.js 在加载 Core 后为 `Model.fromMoc` 注册兼容映射，使 pixi-live2d-display 0.4.0 可与 Cubism SDK for Web 5-r.5（Core 6.0.1）配合使用。已验证的模型：Live2D 官方示例 Tororo、Hijiki（Cubism 2.1 转换至 Cubism 4 运行时格式）。
