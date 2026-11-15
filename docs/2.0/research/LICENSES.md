# 代码、资产与法律文本许可清单（M13-04 调查）

核验日期：2026-11-15。状态：**只读调查完成，权利未整体核清**。本页是 M13-04 的可核验台账，不是授权文件，也不为任何上游代码、字体或生成服务产物指定许可。

方法：`git ls-files`、文件树、仓库内 `ArtSource/` 记录、`Game/export_presets.cfg`、实际导出 PCK 目录解析与哈希；外部事实用官方原始文件核对，入口与结果见第 6 节。凡未能取得正文的条目明确写"未核验"，不引用搜索摘要代替。

状态标签：

- **记录齐全**：仓库内能找到来源入口（任务 ID、提示词、文档或官方许可正文），且与实际文件可对应。
- **有记录但缺许可依据**：来源链存在，但仍缺对该产物"可商用 / 可再分发"的许可正文或账户条款。
- **无来源记录**：仓库内只有成品或原始图，没有书面生成记录。

## 1. 代码

| 对象 | 事实与版本 | 许可依据 | 状态 |
|---|---|---|---|
| Godot 引擎 | `.godot-version` = `4.7.2-stable`；M13 RECORD-01 记录本机 `--version` 为 `4.7.2.stable.official.ed1daf0bf` | `Game/legal/GODOT_LICENSE.txt`，SHA-256 `B0435E3B3E4E55238F05F4B306F30524A1B2E20147810D436EAA554FA6855C80`，与官方 `4.7.2-stable` 的 `LICENSE.txt` 一致（2026-11-15 复核）。引擎 MIT；第三方组件见 `Game/legal/GODOT_COPYRIGHT.txt`，SHA-256 `CB1980C88089573BCACD7221D777C689BB8BBD778799F24C27FCA0FE5F774D6D`，与官方同版本 `COPYRIGHT.txt` 一致。该文件覆盖 `thirdparty/accesskit/*`、`thirdparty/fonts/DroidSans*`、`Inter*`、`JetBrainsMono`、`NotoSans*`、`OpenSans*` 等随引擎内置项 | 记录齐全 |
| GDScript 项目代码 | 178 个 `Game/**/*.gd`、约 44,882 行；17 个 `*.gdshader`；无 `addons/`、无 `plugin.cfg` | 仓库根与全库均无 `LICENSE` / `COPYING`；GitHub `repos/henjicc/yipiantian/license` 与 `repos/the-lazy-me/yipiantian/license` 均返回 404（2026-11-15） | 有记录但缺许可依据（R01） |
| fork 与上游 | `upstream` = `henjicc/yipiantian`，`origin` = `the-lazy-me/yipiantian`；`upstream/main`（`f816a91`）是 HEAD 的祖先，fork 领先 160 个提交；根提交 `8a8b91d`（2026-09-17，作者 henjicc）；全库 432 个提交。即本轮 2.0 工作是在上游历史之上继续修改，不是独立重写 | 同上，无仓库级许可 | 有记录但缺许可依据（R01） |
| 第三方 GDScript 片段 / 插件 | `git ls-files` 无 `addons/`、无 `plugin.cfg`；`Game/**/*.gd` 内检索 `copyright` / `SPDX` / `adapted from` / 外链 URL，除 SVG 命名空间 `http://www.w3.org/2000/svg` 外无第三方署名或来源声明 | 无引入项 | 记录齐全（未发现第三方 GDScript） |
| `native/desktop`（Windows 宿主） | `main.cpp` 514 行，自研 Win32 实现；`README.md` 明确说明 Lively（GPL-3.0）与 tauri-plugin-wallpaper 仅作结构参考，未引入源码或运行时；源码内无第三方版权头 | 无独立许可证文件；属于项目代码的一部分，受仓库级许可缺失约束 | 有记录但缺许可依据 |
| `native/macos_desktop`（GDExtension） | `SConscript` 构建 325 行 `src/macos_desktop.mm` + 31 行头文件，链接外部 godot-cpp；`build.sh` 固定 `GODOT_CPP_COMMIT=2a4c066e1e8c121046e9d35fe91cc8e726861c48`，克隆到 `.local/godot-cpp`，不 vendor 入库 | godot-cpp 该提交的许可文件是 `LICENSE.md`（不是 `LICENSE`，后者 404）：MIT，`Copyright (c) 2017-present Godot Engine contributors`（2026-11-15 复核）。godot-cpp 为静态链接，产物 `Game/macos_desktop.release.dylib` 会随 macOS 包分发；`Game/legal/GODOT_COPYRIGHT.txt` 不含 godot-cpp 条目 | 有记录但缺许可依据（缺随包通知） |
| 项目技能 `.agents/skills/` | 仅开发辅助，位于 `Game/` 之外，不进入导出 PCK（实际 PCK 顶层目录无 `.agents`） | `godot/LICENSE`：MIT，`Copyright (c) 2026 Sascha Becker`；`blender-3d-asset-generation/LICENSE`：MIT，`Copyright (c) 2026 Siamese Cat Dev and Mr A`；`farm-3d-asset-pipeline` 为项目自建，无许可证文件 | 记录齐全（不随游戏分发） |

补充事实：`Game/legal/GODOT_COPYRIGHT.txt` 是官方原文件的完整拷贝，因此引擎内嵌的 Rust `accesskit`、DroidSans 等组件已由该文件覆盖；导出产物中的 `/Users/runner/.../accesskit_*` 调试路径属于引擎模板自带字符串，不是本项目引入的新依赖。

## 2. 资产（`Game/art`）

`Game/art` 跟踪文件 860（含 `.import`）；非导入资源 435 个：GLB 182、PNG 128、JPG 91、SVG 13、OGG 5、WAV 4，余为字体、图标、`.res`/`.tres`、着色器和清单。`ArtSource/` 跟踪 1,323 个文件，含 35 份 README、135 份 Tripo `task.json`、119 份 `reference*.png`、119 份 `audit.json`、79 份生成/来源记录 JSON。

除特别注明外，三维资产与大部分二维图标的来源链为"内置图片工具参考图 → Tripo 图生模型 → Blender 整理"，逐项任务 ID、积分与参数记录在对应 `ArtSource/**/README.md` 与 `task.json`。这些记录证明**来源可追溯**，不等于**服务条款允许商用与再分发**。

| 类别 | 数量 | 仓库内记录入口 | 状态 |
|---|---:|---|---|
| 角色 `characters/farmer` | 8 | `ArtSource/Characters/Farmer/README.md`；绑定/动作任务 `12115ad3…`、`c46423cb…`；道具 `task.json`；动画审计 `animation-20260919/audit.json` | 有记录但缺许可依据 |
| 作物 `crops` | 84 | `ArtSource/Crops/Autumn2026/README.md` + `image-records.json`、`Crops/P2Stages20260919/README.md`、`Crops/Greens/README.md`、`Crops/Radish/README.md`、各 `task.json` | 有记录但缺许可依据 |
| 摆件 `decorations` | 11 | `ArtSource/Decorations/{Flowerpot,Jar,Lantern}/README.md`；灯笼 P2 重制记录在 `Lantern/README.md` | 有记录但缺许可依据 |
| 环境 `environment` | 203 | `ArtSource/Environment/README.md` 及 `Archipelago`、`Islets`、`House`、`Kitchen`、`Bamboo`、`Boat`、`Tree`、`Trees`、`Lotus`、`Soil`、`Trellis`、`Modules`、`CourtyardLife`、`Backdrop`、`ParametricKit`、`ProceduralBridge` 各 README + `generation-record.json` / `image-records.json` | 有记录但缺许可依据 |
| 农具 `tools` | 8 | `ArtSource/Tools/20260919-icon-tools/README.md`（4 件任务与积分）、`20260919-water-bucket/README.md` | 有记录但缺许可依据 |
| 音频 `audio` | 9 | `ArtSource/Audio/README.md`、`score.json`、`seasons.json`、`compose_*.py`；明确为程序合成，无外部采样或曲库 | 记录齐全（不依赖生成服务条款） |
| UI 字体 `ui/fonts` | 3 | `Game/art/ui/fonts/字体来源.txt`（现役子集，2,037,988 B，SHA-256 `3358727A…1624`，与记录一致）；`ArtSource/UI/Fonts/汇文明朝体-原始.ttf` 24,426,256 B，SHA-256 `1EA5D045…8D9C`，与记录一致 | 有记录但缺许可依据 |
| UI 生成图标（toolbar/animals/decorations/crops 的 weeds、till、luffa） | 约 30 | `ArtSource/UI/toolbar-icons.json`、`animal-icons.json`、`decoration-icons.json`、`tending-icons.json`、`Trellis/README.md`、`Crops/Autumn2026/image-records.json` | 有记录但缺许可依据 |
| UI 程序绘制 | 13 个 SVG（`actions/*`、`basket`、`harvest`、`moon`、`sow`、`sun`、`water`、`camera`） | `ArtSource/UI/README.md` 说明为项目 SVG 曲线；`actions/*` 与六枚状态图标均有说明。`camera.svg` 由提交 `caf9954` 引入，README 未逐项点名 | 记录齐全（`camera.svg` 仅提交级来源） |
| UI 圆盘/木框 `ui/radial_menu` | 22 | `ArtSource/UI/RadialMenu/generation.json`、`materials-generation.json`（工具、原始文件名、提示词、处理步骤、哈希） | 有记录但缺许可依据 |
| UI 淡彩材质 `ui/pigment` | 10 | `ArtSource/UI/Pigment/README.md` + `generation.json` + `build_materials.py`（2 张源图，按 token 派生运行图） | 有记录但缺许可依据 |
| UI 建造缩略图 `ui/construction` | 10 | `ArtSource/UI/README.md`：Godot 4.7.2 离线渲染现有资产，重建入口 `scripts/render-construction-icons.gd` | 记录齐全（派生物，随上游资产状态） |
| UI 工笔植物角 `ui/botanical_corners` | 9 | 只有 `ArtSource/UI/BotanicalCorners20260921/raw/*-source.png`（1254²）与运行图（1024²），**无生成记录 JSON、无 README** | 无来源记录 |
| UI 厨房图标 `ui/kitchen` | 4 | 无文字记录；但 `pickled_greens.png`、`root_soup.png`、`stir_fry.png` 与 `ArtSource/Environment/Kitchen/20260918/*-reference.png` 哈希完全相同，`slices.png` 与 `CourtyardLife/20260918/slices-reference.png` 哈希相同 | 有记录但缺许可依据（记录未点名，可用哈希追溯） |
| UI 门前工具图标 `ui/crops/porch-sow.png`、`porch-water.png` | 2 | 无文字记录；哈希与 Tripo 服务预览图 `porch-seed-basket-9cf828c2/preview.png`、`porch-watering-can-01c93223/preview.png` 完全相同（512×512） | 有记录但缺许可依据（记录未点名，可用哈希追溯；直接使用服务预览渲染图） |
| 历史字体 `ArtSource/UI/历史字体/NotoSerifCJKsc-Regular.otf` | 1 | `ArtSource/UI/README.md` 记录官方来源、版本 2.003、SHA-256；`OFL.txt` 为官方 SIL OFL 1.1 正文 | 记录齐全（**不在 `Game/` 内，不随包**） |

### 字体特别说明

- `Game/art/ui/fonts/字体来源.txt` 自述"是来源和字体内元数据的如实转录，不是新制许可文本。所提供目录未包含单独许可文件"。
- 读取字体 `name` 表核对：`Copyright = "Public Domain"`、`Huiwen-mincho`、`Version 1.00;January 14, 2021`，与记录一致。
- 第三方字体站页面（猫啃网）在 2026-11-15 未能取回可引用正文；搜索结果摘要提到"允许个人和企业免费使用，包括商业用途"，**该摘要不作为证据**，需取得字体发布方原始授权说明或与版权字段一致的许可正文。
- 目录名标为 `GBK1.001`，字体内版本为 `1.00`；两者不一致已由记录说明，按实际元数据为准。
- 游戏内"关于"页（`Game/ui/game_menu.gd`）只写"字体内版权标记：Public Domain"，不构成许可正文。

## 3. 法律文本与导出包

| 项 | 事实 |
|---|---|
| `legal/` 目录 | 只有 `Game/legal/GODOT_LICENSE.txt`（1,149 B）与 `Game/legal/GODOT_COPYRIGHT.txt`（100,108 B）。没有项目 LICENSE、没有字体许可正文、没有第三方通知清单 |
| 导出预设 `include_filter` | 两个预设都包含 `art/ui/fonts/字体来源.txt,legal/GODOT_LICENSE.txt,legal/GODOT_COPYRIGHT.txt`；macOS 另加 `macos_desktop.*.dylib,native/macos_desktop/*.gdextension`。`export_filter="all_resources"`，即 `Game/` 下全部资源入包（`development/`、`tests/` 只在 `exclude_filter` 中排除部分场景样例） |
| 本机导出 PCK 实测 | Windows 1,245 条、macOS 1,249 条。两者都含 `legal/GODOT_LICENSE.txt`、`legal/GODOT_COPYRIGHT.txt`、`art/ui/fonts/字体来源.txt`；macOS 另含 `macos_desktop.debug.dylib`（350,608 B）、`macos_desktop.release.dylib`（350,560 B）与 `native/macos_desktop/macos_desktop.gdextension`；两者都含 12 条 `development/*`（隐藏模型检查页，`check-release-pack.ps1` 有白名单） |
| 商店/发行通知现状 | `发行材料/来源与通知.txt` 只在 `scripts/package-release.ps1`（Windows 发行）中复制到包的 `notices/`；`scripts/build-macos.sh` 与 `build-macos.yml` 不复制该文件，macOS 包内也没有 `notices/`。PCK 内不含 `来源与通知.txt` |
| 官方要求 | Godot 4.7 文档《Complying with licenses》：引擎含"兼容但不被 MIT 覆盖"的第三方软件，需要"在最终产品文档中明确引用其版权声明与许可正文"；建议随发行附 `COPYRIGHT.txt`；并"必须把许可正文提供给用户"；同时应为自用资产（贴图、模型、声音、音乐、字体）另附第三方通知（2026-11-15 查阅） |

## 4. 模型与推理后端（当前不分发）

| 对象 | 事实 | 许可 | 状态 |
|---|---|---|---|
| 权重文件 | `.local/models/Qwen3-4B-Q4_K_M.gguf`（2,381.6M）、`.local/models/Qwen3-4B-Q8_0.gguf`（4,082.1M）。`git ls-files` 无 `.gguf`；两个 PCK 内 `.gguf` / `Qwen` 字符串计数为 0。忽略来源是 `.gitignore` 的 `/.local/`，**没有 `*.gguf` 规则**：`git check-ignore` 实测 `weights.gguf`、`Game/model.gguf`、`test.onnx` 都不被忽略，放到 `.local/` 之外会被跟踪 | HF API `Qwen/Qwen3-4B-GGUF` 许可标签 `apache-2.0`（revision `bc640142…`）；仓库内含 `LICENSE`（Apache-2.0 正文），`NOTICE` 返回 404 | 记录齐全（当前不分发） |
| llama.cpp 后端 | `Game/ai/llama_cpp_backend.gd` 仅按配置路径启动外部 `llama-completion`；仓库内无二进制、无源码、无库文件。本机 `b12400`（commit `3e41ae69d`）位于 `.local/tools/llama-b12400/`，包内 `LICENSE` 为 MIT `2023-2026 The ggml authors`；固定提交 `32bdc3a…` 的官方 LICENSE 一致 | MIT（库）；权重不在此许可覆盖范围 | 记录齐全（当前不分发） |
| 其他候选（Gemma 3、MiniCPM4.1、Llama 3.2、MLX、mlx-lm） | 结论见 `docs/2.0/research/MODEL-CANDIDATES.md`、`M9/RECORD-01-model-selection.md`；未集成、未随包 | 各自模型卡与官方许可 | 记录齐全（未采用） |

若将来分发权重或推理二进制，需要携带：所用模型的 `LICENSE` 全文；Apache-2.0 的版权与许可声明、NOTICE（若上游提供）与修改说明；llama.cpp 的 MIT 正文与 ggml 版权行；若一并分发 MLX / mlx-lm 或 Python 运行时，还需各自 MIT 通知与依赖清单。当前这些文件都未放入 `Game/legal/`。

## 5. 记录缺口与不一致

1. `ui/botanical_corners` 9 张运行图只有原始 PNG，无生成记录；提交 `56ab73a`（2026-09-21）是唯一来源线索。
2. `ui/kitchen` 4 张与 `ui/crops/porch-sow|porch-water` 2 张没有书面记录，只能靠哈希与 `ArtSource` 参考图/服务预览图对应。
3. `Game/art/environment/parametric_kit` 的 `house_material_atlas.png`、`bamboo_gongbi_atlas.png`、`tree_trunk_color.jpg`、`tree_cluster_color.jpg` 在 README 中有说明（其中房屋材质有 `house-generation-record.json`），但竹材图集与树木贴图没有逐文件提示词记录。
4. `Game/art/ui/camera.svg` 只见于提交，README 未逐项列出。
5. `制作留档/` 目录在当前检出中不存在，但仓库内 51 个 Markdown 引用它；按里程碑通用约定，"正式正文不能只链接不可取得的个人路径"。这不影响资产来源链（`ArtSource/` 自带记录），但影响依赖留档的验收复核。
6. `docs/task/首个可发布版本/…/5.1-核对资产权利与渠道提交要求.md` 记录"用户暂缓商业／授权核验"，与 2026-11-14 起恢复核验的现状冲突，需要登记更新，不能删除历史结论。
7. 10 份 `ArtSource` README 末尾保留"商业授权核验按用户要求暂不执行"，应标注为历史状态而非当前结论。
8. 生成服务（Tripo、内置 imagegen）在任何仓库文件中都没有账户级条款快照或产物权利说明；记录只有任务 ID、积分与参数。

## 6. 已核验的外部入口

| 来源 | 用途 | 结果 |
|---|---|---|
| `https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/LICENSE.txt` | 引擎 MIT 正文 | SHA-256 与 `Game/legal/GODOT_LICENSE.txt` 一致 |
| `https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/COPYRIGHT.txt` | 第三方版权汇总 | SHA-256 与 `Game/legal/GODOT_COPYRIGHT.txt` 一致 |
| `https://docs.godotengine.org/en/4.7/about/complying_with_licenses.html` | 发行合规要求 | 已查阅：第三方署名、`COPYRIGHT.txt`、资产通知、许可正文须提供给用户 |
| `https://raw.githubusercontent.com/ggml-org/llama.cpp/32bdc3a89e6528d3e419024c833c5dabf32c7541/LICENSE` | llama.cpp 许可 | MIT，`2023-2026 The ggml authors`；与本机 b12400 包内 LICENSE 一致 |
| `https://raw.githubusercontent.com/godotengine/godot-cpp/2a4c066e1e8c121046e9d35fe91cc8e726861c48/LICENSE.md` | godot-cpp 许可 | MIT，`2017-present Godot Engine contributors`；同提交 `/LICENSE` 为 404 |
| `https://huggingface.co/api/models/Qwen/Qwen3-4B-GGUF` | 权重许可标签 | `apache-2.0`，revision `bc640142c66e1fdd12af0bd68f40445458f3869b` |
| `https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/LICENSE` | 权重许可正文 | Apache License 2.0；`NOTICE` 不存在 |
| `gh api repos/{henjicc,the-lazy-me}/yipiantian/license` | 仓库级许可元数据 | 两者均 404 |
| 猫啃网汇文明朝体页面 | 字体授权线索 | 2026-11-15 未能取回可引用正文；不使用搜索摘要作为依据 |
| Tripo 服务条款 | 生成产物权利 | 未取得可访问正文（403/404）；不推断条款内容 |

## 7. 复核命令

```bash
# 资产与记录规模
git ls-files Game/art | grep -vE '\.import$|\.uid$' | wc -l
git ls-files ArtSource | grep -c 'task.json'

# 引擎许可校验
shasum -a 256 Game/legal/GODOT_LICENSE.txt Game/legal/GODOT_COPYRIGHT.txt

# 模型权重未入库 / 未入包
git ls-files | grep -iE '\.gguf|\.safetensors'
git check-ignore -v weights.gguf   # 预期不忽略

# 导出包内法律文本（M13 RECORD-01 的 PCK 解析方法）
# 期望条目：legal/GODOT_LICENSE.txt、legal/GODOT_COPYRIGHT.txt、art/ui/fonts/字体来源.txt
```
