# Pacgate AI - 第一阶段本地试点

面向多租户律师事务所的隐私优先法律 AI 平台。无头 Rust 元数据网关，搭配 deer-flow 检索运行时、qm 协作运行时与 OpenViking 长期记忆模块。

**English:** [README.md](README.md) | [Staff Handbook](docs/PACGATE-LAW-STAFF-HANDBOOK.md)

## 版本：v0.2.37（2026年11月22日）

- **DOCX 红线修订，带 Word 原生修订标记。** 新增三个 MCP 工具——`pacgate_redline_compare`、`pacgate_redline_accept`、`pacgate_redline_reject`——把两份已存文档合成为带真实 `<w:ins>`/`<w:del>` 标记的 `.docx`，审核律师可在 Word 中逐条接受或拒绝修订，而无需阅读叙述式 diff。pacgate-mcp 桥接镜像的对外工具数由 **26 增至 29**。
  - **产物在返回前已通过校验。** `compare()` 会断言：接受全部修订后**精确**还原新文档，拒绝全部修订后**精确**还原原文档。任一不成立即**拒绝返回**，因为这种失败对审核者不可见——他们看到的是看似合理的差异，进而批准了两份文档都不存在的文本。
  - **中文支持，粒度到词。** 在中文合同条款上实测，修订落在变更处而非整句：`12`→`11`、`31`→`30`、`壹`→`贰`、插入 `五`、`专用`→`普通`。评估过的替代库（`redlines`）在中文输入下替换**整句**，因为中文没有可用于分词的空格。
  - **引擎与许可。** `docx-scalpel` 0.13.0（MIT），Docxodus 的 Python 客户端。版本精确锁定；自带自包含的 manylinux wheel。
- **失败结果现在给出下一步动作。** pacgate-mcp 的每一种错误形态都带 `repair_hint`：未配置服务的结果会点名环境变量并明确"重试无意义"；条款被截断时给出**计算所得**的切分尺寸（`suggested_max_chars`、`fraction_read`、`suggested_parts`），数据取自 laya 自身的 token 计数；语言不适用而扣留结论时，会点名替代工具**及其参数**。只描述故障而不给出可改动之处，agent 就只会重复发起同一调用。
- **新增两道闸门。** `test-docx-redline.ps1`（8 项断言：镜像内引擎存在、真实 `w:ins`/`w:del`、双向还原、作者不是引擎默认值、中文粒度按跨度衡量）与 `test-mcp-repair-hints.ps1`（26 项断言，已做变异测试）。二者均纳入 `run-all-checks.ps1`。
- **运维注意（镜像层面）。** `pacgate-mcp` 现依赖 `libicu`。其内置 .NET 宿主在裸 `python:3.12-slim` 上会以*"Couldn't find a valid ICU package installed on the system"* 中止，因此 Dockerfile 安装了 `libicu-dev libssl3 libstdc++6 ca-certificates`。请勿移除该层，也不要将本镜像切换到 Alpine——该 wheel 为 `manylinux_2_28_x86_64`。
- **客户需要做什么。** 拉取下表新标签并重建 `pacgate-mcp`。无 API 变更、无 schema 变更、无配置变更。既有的非红线文档流程不受影响。

## 版本：v0.2.35（2026年11月15日）

- **校验器不再把模型猜测当作残留证据。** `verdict()` 对**任何**存活片段都返回 `Block`，因此一个 `MatchSource::Model` 片段本身即可定案。循环性在于：`verify()` 会针对**已脱敏**文本重新运行检测器，模型检测器可能对脱敏器早已替换掉的文本、或其相邻碎片重新命中，而 `VerifyScope::inside_placeholder` 只排除完全落在占位符内部的片段。于是一个针对"已不存在的文本"的猜测，成了拒绝整份文档的理由。现按**证据类型**区分：规则命中（校验和、模式、上下文）属结构性证据，无条件阻断；模型命中属猜测，不再单独阻断。模型片段仍保留在 `residue` 与 `notes` 中，审核者依然可见。
- **解除了什么限制。** 此前因"仅有模型证据"而被 `blocked` 的文档，现在可以通过脱敏。修复前在本机实测：**868 个分块中有 397 个被阻断，涉及四份文档**，包括《合规律师实用Prompts指南》(144)、《基金律师实用Prompts指南》(108)、《presented-pacgate-ai-平台实战教程》(docx 73 + pdf 70)。台账记录的存活片段是教科书式的占位人名（张三）、已注册的连接器名称（yuandian）与公开机构（黄山市人民政府、保定市国资委、平潭综合实验区国有资产管理局），均非客户身份信息。
- **客户需要做什么。** 拉取 `ghcr.io/jzkk720/pacgate-api:0.2.35`，然后**重新脱敏**受影响的文档：`POST /api/documents/:id/sanitize`，请求体为 `{"data_level":"T3"}`。判定结果在脱敏时计算并存储，因此既有的 `blocked` 记录在重新脱敏前仍为阻断状态，仅拉取镜像不会解除。请使用 `/sanitize`，**不要**用 `/sanitize-rescan`：后者是只读检查，只报告 `chunks_offending`，不会提升任何分块。
- **未变更的部分。** 无 API 变更、无 schema 变更、无配置变更、无新增接口。本次为判定规则修复。其余镜像内容未变，仅因流水线没有按路径过滤而一并重建。

### 承接自 v0.2.34（未改动，仍有效）

以下内容已随 0.2.34 发布并继续有效，单列于此，不再作为后续版本的变更重复陈述。

- **文档正文读取统一为一个准入判断。** `/api/documents/:id/download` 会拒绝 `pending` 文档，而 `/api/documents/:id/extract` 却返回其正文——租户校验是它唯一的校验。二者现均调用 `pacgate_api::egress::assert_readable`，且**每次读取与每次拒绝都写入审计行**（`document.read`，含 `purpose`、`document_state`、`data_level` 与 `outcome`）。根因是结构性的而非笔误：每个 handler 各自维护一条规则，因此后来新增的第三个 handler 无规则可继承。`documents.rs` 现已锁定返回正文的 handler 清单，新增而未接入该统一入口者会导致测试失败。
- **`/extract` 不再返回脱敏前的 spans。** `document_spans.text` 保存的是抽取器当时读到的文本，而去标识任务从不重写该表——脱敏产物写入 `kb_chunks`。因此 `sanitized` 文档的缓存抽取会在 `spans[].text` 中返回**原始正文**，而顶层 `text` 字段看起来却是干净的；仅对 `text` 加闸会得到一个"读起来像已修完"的半修结果。现在已脱敏文档的抽取只从 `kb_chunks` 返回脱敏后的 `text`，且不返回 spans，因为脱敏文本没有可对应的页面坐标。这是真实的能力收缩，在此明示，而非留给使用者自行发现。
- **无法解析的 `max_data_level` 一律拒绝，不再悄然放宽。** `kb_search` 曾以 `.and_then(from_code).unwrap_or(T3)` 解析密级上限，于是请求 `T1` 但拼写有误的调用方会拿到 `T3` 内容——过滤恰在"披露更多"的方向上失效，且返回 200、毫无提示。未传该参数仍默认 `T3`；传了但无效现返回 400。这才使手册中"检索不会悄然放宽范围"成为对代码的描述，而非意图。
- **外部连接器检索移除 `data_level`。** 该参数曾被校验、以"tagged for audit"记入日志，随后被丢弃——`SearchQuery` 并无密级字段，因为连接器返回的是无百宸密级的第三方结果，且当时没有任何代码写入审计行。接受该参数构成虚假的合规信号，故现返回 400，MCP 工具也不再提供该参数。真正执行过滤的是 `/api/kb/search`。
- **边界规则现已有真实执行，并如实报告无法执行的部分。** `EnforcementPoint` 声明了三个变体、每个都带注释说明红线在何处执行，随后在 SOUL 人格定义中被写入 35 次，**却从未被读取**——全仓检索该字段只返回其自身声明。于是所有标记为 `WorkflowGate` 或 `ApiMiddleware` 的规则，实际行为与 `AgentPrompt` 完全相同，但在人格源码中读起来却像一个平台级控制，包括 `"No legal conclusion without Sylvie's review"` 与 `"Block any output with unverified citations"`。两项改动关闭此缺口：
  - **提示词不再宣称不存在的控制。** `pacgate_core::enforcement::render_rules_for_prompt` 将规则拆分为 `enforced outside the model` 与 `self-check` 两节。此前 35 条规则全部以同一格式置于单一 `BOUNDARY RULES (red lines)` 标题下，等于告诉模型存在 16 个外部闸门。
  - **现有一道闸门已真正建成：引证与原文核验。** `enforcement::evaluate_turn` 将 `CitationRef.verbatim` 与被引文档的**脱敏**正文比对（沿用智能体工具所用同一 fail-closed 的 `sanitised_text` 契约——核验器也是一个读取方）。引文未找到、或来源无法读取，均判定为不支持。全角/半角标点与抽取产生的空白已归一化，PDF 换行不会造成误判；但数字被篡改仍会判定为不符。
  - **其余所有对外宣称的闸门均报告为 `not_implemented`，而非通过。** `ChatResponse.enforcement` 与新增的 `SsePayload::Enforcement` 帧携带逐条规则结论，并写入 `audit_log`（`chat.boundary_gate.evaluated` / `.violated`）。流式路径同样执行闸门：只在缓冲端点上生效的闸门，等于有两套代码路径的建议。
  - 2026-11-09 实测：16 条声明外部执行的规则中，**1 条已建成、15 条未建成**。`pacgate-persona` 锁定这两个数字，使规则无法被悄悄重新贴标——已通过把一条 `AgentPrompt` 规则改标为 `WorkflowGate` 做反向验证，测试套件随即失败。
- **本地服务代理修复。** 未设置 `*_PROXY` 时，`reqwest` 0.12 会采用操作系统代理，而该配置不带本机回环豁免。由此产生两个后果，现均由 `pacgate_core::http::local_service_client` 关闭（清除平台代理，同时保留运维显式配置的 `HTTP(S)_PROXY` 用于远程供应商）：
  - **在 Windows 上，回环调用直接失效。** 平台设置不会绕过 `127.0.0.0/8`，因此发往 `http://127.0.0.1:<port>` 的调用被送到代理并返回 `502 Bad Gateway`。2026-11-04 实测：`pacgate-agent` 12 个测试中 6 个因此失败，设置 `NO_PROXY` 后 12 个全部通过。现豁免 `localhost`、`127.0.0.0/8`、`::1`、`*.local` 与 `host.docker.internal`。
  - **已部署容器不会继承代理**（实测：运行中的 `pacgate-api` 无任何 `*_PROXY` 变量），因此客户端访问 Ollama、OCR 与向量嵌入的调用并未受影响。为避免某台机器或某个镜像设置了代理后把内部流量静默转走，这些客户端同样改用新的构造函数。
- Rust 元数据核心：12 个 crate + 4 个 WASM crate，冒烟/智能体/工作流/集成测试全部通过
- 15 个文件共 220 个 YAML 工作流模板
- 30 个法律角色人格（20 个业务领域 + 10 个 SOUL）
- Rust `default_router()` 中有 10 个数据源连接器（元典、北大法宝、企查查、法源开、CourtListener、SEC EDGAR、GLEIF、Vaquill、EUR-Lex、OpenCorporates）——deer-flow MCP 面暴露 17 个已启用服务器
- RAG 检索（pgvector + tsvector + Ollama 嵌入，T1-T4 数据分级过滤）— 完全本地运行
- OpenViking 记忆模块：经 qm 桥接的 ov-remember / ov-search / ov-read，deer-flow 内 MCP 召回
- 认证体系（JWT + argon2 + SOUL 解析中间件）
- pacgate-api 镜像：`ghcr.io/jzkk720/pacgate-api:0.2.37`（公开；LLM 路由遵循 `OLLAMA_BASE_URL`，支持按租户模型覆盖）
- deer-flow 封装镜像：`ghcr.io/jzkk720/deer-flow-pacgate:0.2.37`（公开）
- pacgate-mcp 桥接镜像：`ghcr.io/jzkk720/pacgate-mcp:0.2.37`（公开；暴露 **29** 个 MCP 工具，含文档/工作流与 DOCX 红线）
- deer-flow 前端封装镜像：`ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.2.37`（公开；构建时烘焙网关地址）
- OCR 服务镜像：`ghcr.io/jzkk720/ocr-service:0.2.37`（公开；PaddleOCR 抽取，自 0.1.16 起为一等镜像）
- qm 协作桥接已验证（Python CLI，HARNESS=pi，真实 Ollama）
- 客户部署包已入库：`deploy/client-bundle/` — 全新克隆安装路径已验证
- 知识图谱：935 节点、2220 条边、49 个社区
- 面向员工的用户手册（中英双语）位于 `docs/PACGATE-LAW-STAFF-HANDBOOK*.md`，附 PDF 导出

### 模型策略（2026年8月30日确定）

工作流各层级在设备本地运行。**客户运行时**（`deploy/client-bundle/deer-flow-config.yaml`）默认使用本地 `ornith-1.5:9b/35b` 与 `nemotron-3.5-lightning:30b` 用于检索；`nomic-embed-text` 用于 RAG 嵌入。**开发/CI 参考配置**（`deploy/deer-flow-pacgate/config.yaml`）使用云端路由的 `deepseek-*-cloud` 标签以提速。qm 通过 `PI_MODEL` 使用 `glm-5.3-flash:cloud`。事务所接受对话生成提示词经 ollama.com 处理；文件存储、RAG 与记忆抽取始终不离开 AIPC。`ollama signin` 为云端标签模型的安装前置条件。

## 快速部署

在每台 AIPC 上克隆仓库并按手册操作：

```powershell
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
```

完整分步安装指南见 `deploy/AIPC-DEPLOYMENT-HANDBOOK.md`。GHCR 运行时镜像为公开包，无需 `docker login`。

## 系统架构

```
nginx :8081
├── /          -> pacgate-api :8080（Rust, Axum）
├── /api/      -> pacgate-api :8080
├── /research/ -> deer-flow :8001（Python, LangGraph）
└── qm :8182   ->（独立运行，经 qm up 启动）

Postgres :5432（元数据库）
OpenViking :1933（长期记忆模块，MCP）
Ollama :11434（原生安装，GPU/NPU）
```

两台 AIPC 完整运行同一套栈，各自独立可用。

## 主要目录

| 路径 | 用途 |
|------|------|
| `pacgate-ai/crates/` | Rust 工作区（12 个 crate） |
| `pacgate-ai/wasm-crates/` | WASM 沙箱 crate（文档校验、规则引擎、引用核对、条款解析） |
| `pacgate-adapters/python/` | deer-flow 适配器（176 行） |
| `pacgate-adapters/typescript/` | qm 合约库（8 项测试） |
| `deploy/client-bundle/` | 客户部署包（compose、install.ps1、nginx、qm 引导脚本） |
| `deploy/client-delivery/` | 客户交付包（文档 PDF + README 索引） |
| `deploy/handbooks/` | 集成手册（deer-flow/qm + OpenViking + pacgate 网关）+ 渲染脚本 |
| `deploy/qm-pacgate/` | qm 部署目录（配置、沙箱、桥接工具） |
| `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` | 双 AIPC 分步安装指南 |
| `deploy/SETUP-AND-OPERATIONS-ZH.md` | 完整三天驻场安装指南（中文版） |
| `deploy/DEPLOYMENT-GUIDE.md` | 工程师级部署细节 |
| `docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md` | 员工使用手册（非技术向） |
| `docs/` | 方案页、建设计划、进度报告卡 |
| `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md` | 第一阶段商务与技术计划 |

## GHCR 镜像

Pacgate 运行时镜像均为**公开**（已验证匿名拉取）。源码仓库保持私有。所有镜像由 `.github/workflows/build-ghcr.yml` 构建并推送到 GHCR，以确保两台 AIPC 保持同步。

**`ghcr.io/jzkk720/*` 是唯一的镜像命名空间，也是 `deploy/client-bundle/compose.prod.yaml` 唯一引用的命名空间。** 它同时是代码主仓库，发布全部五个镜像。`ghcr.io/pacgate-ai/*` 为遗留镜像：旧版本标签仍可拉取，但不再发布新版本，因此出现 `pacgate-ai` 引用即表示该文档已过时。若发现此类引用，请改用下表中的 `jzkk720` 标签。

> 2026-09-22 更正。本段此前表述相反（称 `pacgate-ai` 为唯一命名空间、`jzkk720` 不发布镜像且大多 404）。该说法在 plan 016 迁移命名空间之前成立，此后一直被反向描述。撰写时已验证：五个 `jzkk720/*:0.1.19` 镜像匿名拉取均返回 HTTP 200，`pacgate-ai/*:0.1.14` 仍可拉取但已被取代。

| 镜像 | 内容 | 基础镜像 |
|-------|----------|------|
| `ghcr.io/jzkk720/pacgate-api:0.2.37` | Rust 二进制 + SQL 迁移 | `rust:1.94-bookworm` -> `debian:bookworm-slim` |
| `ghcr.io/jzkk720/pacgate-mcp:0.2.37` | pacgate-api MCP 桥接（**29** 个工具，含文档/工作流/红线） | `python:3.12-slim` + `libicu` |
| `ghcr.io/jzkk720/deer-flow-pacgate:0.2.37` | deer-flow 后端 + Python 适配器 | `ghcr.io/bytedance/deer-flow-backend`（固定 SHA） |
| `ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.2.37` | deer-flow Next.js 检索界面（构建时烘焙网关地址） | `node:22-alpine` |
| `ghcr.io/jzkk720/ocr-service:0.2.37` | PaddleOCR 抽取服务（自 0.1.16 起为一等镜像） | `python:3.12-slim` |

每个镜像同时带有 `:latest` 标签，与版本标签保持同步。

qm 不使用 GHCR 镜像，通过入库的 `deploy/qm-pacgate/` 目录以 `qm up` 启动。

构建/推送流程与 owner 命名空间决策见 `deploy/README-BUILD.md`。

## 测试

```powershell
cd pacgate-ai
cargo check
cargo test -p pacgate-api --test smoke
cargo test -p pacgate-agent
cargo test -p pacgate-workflow --test yaml_loader
```

集成测试需要 `localhost:5433/pacgate_test` 上的 Postgres：

```powershell
$env:PACGATE_TEST_DATABASE_URL='postgres://hermes:changeme@localhost:5433/pacgate_test'
cargo test -p pacgate-api --test integration -- --ignored
```

TypeScript 适配器测试：

```powershell
cd pacgate-adapters/typescript
npm test
```

## 许可

私有仓库。第一阶段全部交付成果的版权归 Pacgate 所有。商务条款见 `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md`。
