# 第三方组件与数据来源

DeskPet 源代码以 MIT 许可证发布。下列组件与数据来源由各自的权利人依其许可提供，不属于本项目的 MIT 授权范围。

## 构建时下载的前端库

以下文件由 `scripts/fetch-vendor.sh` 在构建时下载至 `Resources/web/vendor/`（不纳入版本库），并随构建产物一同打包。

| 组件 | 版本 | 许可 |
| --- | --- | --- |
| [PixiJS](https://github.com/pixijs/pixijs) | 6.5.10 | MIT |
| [pixi-live2d-display](https://github.com/guansss/pixi-live2d-display) | 0.4.0 | MIT；其中包含的 Live2D Cubism Framework 适用 [Live2D Open Software License](https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html) |
| [marked](https://github.com/markedjs/marked) | 12.0.2 | MIT |
| [DOMPurify](https://github.com/cure53/DOMPurify) | 3.1.6 | Apache-2.0 或 MPL-2.0 |
| [KaTeX](https://github.com/KaTeX/KaTeX) | 0.16.11 | MIT |
| [highlight.js](https://github.com/highlightjs/highlight.js) | 11.10.0 | BSD-3-Clause |

## 随项目分发的音频素材

`Resources/web/sounds/` 中的猫叫为真实录音剪辑而成（截取单声、淡入淡出、归一化后转为 AAC），原始录音均以 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) 发布，不要求署名，此处注明以示感谢。

| 文件 | 来源 | 作者 |
| --- | --- | --- |
| `meow1`–`meow4` | [BigSoundBank #0098 “Small mewing of a cat”](https://bigsoundbank.com/small-mewing-of-a-cat-s0098.html) | Joseph Sardin |
| `mew1`–`mew3`、`trill1`、`trill2`、`purr` | [OpenGameArt “cat purr meow”](https://opengameart.org/content/cat-purr-meow)（`cat_mewfood`、`cat_softmew`、`cat_mewpurr`、`cat_mewpurr2`、`cat_purrsleepy_loop`） | Kerzoven |

## 不包含于本项目、须由使用者自行获取的组件

| 组件 | 许可 | 说明 |
| --- | --- | --- |
| Live2D Cubism Core（`live2dcubismcore.min.js`） | [Live2D Proprietary Software License](https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html) | 禁止再分发；自 Cubism SDK for Web 获取 |
| Live2D 示例模型 Tororo、Hijiki | [Live2D Free Material License](https://www.live2d.com/eula/live2d-free-material-license-agreement_en.html) 及 [示例数据使用条款](https://www.live2d.com/en/learn/sample/model-terms/) | 禁止再分发素材本身；使用时须标注 “This content uses sample data owned and copyrighted by Live2D Inc.” |

`Resources/model-maps/` 中的 `pet-map.json` 为本项目编写的动作映射配置，仅引用模型中的动作组与参数名称，不含模型数据，适用本项目的 MIT 许可证。

## 运行时访问的数据服务

| 服务 | 用途 | 条款 |
| --- | --- | --- |
| [Open-Meteo](https://open-meteo.com/) | 天气与地名解析 | 数据以 CC BY 4.0 提供，须注明来源；免费接口限非商业用途 |
| [arXiv API](https://info.arxiv.org/help/api/tou.html) | 预印本检索 | arXiv API 使用条款 |
| [Semantic Scholar API](https://www.semanticscholar.org/product/api) | 论文检索 | Semantic Scholar API 许可协议 |
| Bing News RSS、Google News RSS | 新闻检索 | 各服务的使用条款 |
| Yahoo Finance | 行情查询 | 各服务的使用条款；非官方接口，可能随时变更 |

使用者应自行确认上述服务条款是否适用于其使用场景。
