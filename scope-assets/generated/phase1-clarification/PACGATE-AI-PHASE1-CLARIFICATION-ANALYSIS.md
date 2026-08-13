# Pacgate AI Phase 1 澄清分析与回复策略

- 适用阶段：客户第一轮书面澄清回复准备
- 对应问题源：[PACGATE-AI-PHASE1-CLARIFICATION-QUESTIONS.md](./PACGATE-AI-PHASE1-CLARIFICATION-QUESTIONS.md)
- 工作定位：内部分析底稿，用于筛选优先答复项、识别客户误解、拆分固定交付与后续报价

## 1. 核心判断

1. 客户问题中有相当一部分是有效澄清，尤其集中在硬件、数据流、本地部署、安全边界、验收标准、知识库结构和顾问支持方式。
2. 客户也明显把部分 Phase 2 SaaS 化预期提前带入了 Phase 1。对此不能直接顺着答，否则会把本次本地试点方案说成“客户门户 + 多租户 + 商业化后台 + 计费 + 运维监控”的完整建设承诺。
3. 对 Claude for Legal 和 Lavern 的提问里，存在若干“把开源参考项目直接等同于可立即商用的完整产品”的误解，需要温和纠正。
4. 硬件问题数量多，但本质上可以收敛为三类：当前两节点试点架构、Phase 1 可支撑的模型与负载上限、Phase 2 若扩容时的替代路线与预算区间。没有必要对 20 个问题逐一给出彼此重复的答案。
5. 最有效的书面回复方式不是逐题长文，而是“正文回范围 - 附件回细节”。建议形成 4 份附件：范围边界、硬件 annex、部署与安全 annex、Phase 2 非约束性 options note。

## 2. 建议给客户的回复包结构

1. 主回复函：先明确 Phase 1 性质、本次固定交付、成功标准和双方分工。
2. 附件 A - 范围与交付矩阵：把固定交付、顾问小时、另行报价、暂不支持、待确认逐项列清。
3. 附件 B - 硬件与部署 annex：统一回答 BOM、算力、并发、升级、迁移、保修、部署地点和本地数据流。
4. 附件 C - 系统说明 annex：分别说明系统 1、系统 2 的定位、入口、最小验收场景、人与系统分工。
5. 附件 D - Phase 2 options note：只提供方向和预算级别，不把它写成本次固定承诺。

## 3. 需要明确纠正的客户误解

1. Phase 1 不是完整 SaaS 平台建设。
2. Claude for Legal 不是默认“完全本地、完全独立、无需 Anthropic 生态”的交付物；它本质上是 Anthropic 法律工作流插件 / agent 参考体系，需要说明本次仅做 Pacgate 场景适配与部署支持。
3. Lavern 虽然支持本地 / Ollama / Mistral / Anthropic 多路径，但其 README 也明确表述它不是成熟产品，而是开放式参考实现；不应把它直接承诺为 Pacgate Phase 2 的现成商业内核。
4. Package 3 的 starter authority registry / RAG / context graph 应定义为基础结构和验证环境，不应被理解成一次性导入完整法规库、商业数据库和成熟 GraphRAG 平台。
5. 飞书、微信、邮件、客户门户、多租户、计费、客服等入口和商业化模块，不应默认视为本次固定交付。
6. 当前报价文字没有冻结详细 BOM 和性能 benchmark，因此所有“稳定跑哪些模型、多少并发、多少用户”的回答都应写成“基于最终 BOM 与模型名单确认后的目标值”，而不是无条件承诺。

## 4. 外部事实锚点

1. `anthropics/claude-for-legal` 的公开 README 显示其主形态是 Claude Cowork / Claude Code plugin 与 Managed Agents cookbook，强调 attorney-review-first、MCP connectors、practice profile 和 Anthropic 生态集成。
2. `AnttiHero/lavern` 的公开 README 显示其支持本地模式、Anthropic / Mistral / Ollama provider，但同时明确写出“this is not a product”，并说明当前没有 dense / vector retrieval，也没有公开 benchmark。
3. 因此，本次方案里对两个开源项目的表述更安全的方式应是“部署、验证、适配、吸收其工作流结构与交互模式”，而不是“直接把上游项目原样交付为生产系统”。

## 5. 分段 Triage Matrix

交付归类说明：`1` 固定交付，`2` 顾问小时，`3` 另行报价，`4` 暂不支持，`5` 待双方确认。

| 主题 | 问题范围 | 分类 | 优先级 | 交付归类 | 回复方向 | 依据 |
|------|----------|------|--------|----------|----------|------|
| 项目定位 | I-1 至 I-2 | Valid | High | 1 | 明确 Phase 1 是本地 AI 试点与开源法律 AI 部署支持，不包含完整 SaaS 平台建设。 | Proposal |
| 项目定位 | I-3 | Needs Clarification | High | 5 | 可以确认系统 2 面向未来商品化探索，但不能写成“已锁定 Phase 2 主线架构”。 | Proposal |
| 项目定位 | I-4 至 I-5 | Valid | High | 1 / 2 | 用交付矩阵列出可运行系统、仓库、文档、账号和支持边界。 | Proposal |
| 项目定位 | I-6 至 I-8 | Valid | High | 1 / 2 | 成功标准建议写成“本地环境可运行 + 两套系统最小场景跑通 + 可复用资产完成沉淀”。 | Proposal |
| 硬件路线 | II-1 至 II-2 | Valid | High | 5 | 先确认两节点是并行试验、角色拆分还是主备结构，再附硬件 annex 回答。 | Proposal + hardware annex |
| 硬件路线 | II-3 至 II-4 | Needs Clarification | High | 5 | 当前文本未冻结详细 BOM，建议以 pre-PO annex 形式给出主机、Dock、GPU 建议配置。 | Hardware decision pending |
| 硬件路线 | II-5 至 II-8 | Needs Clarification | High | 5 | 模型级别、量化方式、推理速度和并发能力应写成目标区间，取决于最终 GPU、量化与使用场景。 | Hardware benchmark needed |
| 硬件路线 | II-9 至 II-10 | Valid | Medium | 1 / 5 | 可说明节点可独立运行，但不要把 AIPC 方案直接表述为 Phase 2 长期生产架构。 | Proposal |
| 硬件路线 | II-11 至 II-14 | Valid | High | 3 | 若进入 Phase 2，多用户、多客户、强化 RAG 和工作流大概率需要更高性能服务器，应单列方案与报价。 | Phase 2 option |
| 硬件路线 | II-15 至 II-18 | Valid | Medium | 2 / 3 | 数据、配置和知识资产通常可迁移，但性能调优、架构升级与商业化部署不应默认为 Phase 1 内工作。 | Architecture judgment |
| 硬件路线 | II-19 至 II-20 | Valid | Medium | 5 | 把厂商保修、集成支持、性能整改、升级责任拆开说明，避免笼统兜底。 | Commercial clarification |
| 交付与部署 | III-1 至 III-4 | Valid | High | 1 / 2 | 可以先在 Cubecloud 侧完成部署与测试，再交付北京；需说明 Pacgate 是否可远程见证与验收。 | Proposal |
| 交付与部署 | III-5 至 III-7 | Valid | High | 1 / 5 | 用一页数据流图明确哪些数据只在本地，哪些在调试或外部模型调用时会出域。 | Security annex |
| 交付与部署 | III-8 至 III-10 | Valid | High | 1 / 2 | 明确离线时哪些功能仍可工作、管理员权限是否长期保留、以及如何关闭远程权限。 | Security annex |
| Agent OS | IV-1 至 IV-2 | Valid | Medium | 1 | 列出 OpenSpace、Open WebUI、IronClaw、Hermes、Warp ADE、OpenCode 的实际启用程度与用途。 | Product decomposition |
| Agent OS | IV-3 至 IV-4 | Valid | High | 5 | 必须回答授权 / 订阅性质，以及 Phase 1 结束后不续费时哪些功能仍能跑。 | Commercial clarification |
| Agent OS | IV-5 至 IV-6 | Valid | High | 1 / 5 | 把可导出的资产和依赖 Cubecloud 平台的能力分开，降低锁定疑虑。 | Export boundary |
| 系统 1 | V-1 至 V-3 | Valid | High | 1 / 5 | 可确认系统 1 目标是内部律师效率工具，但交付表述应是“适配性部署与验证”，而不是原仓库原样镜像。 | Proposal + Claude README |
| 系统 1 | V-4 | Error | High | 5 | 需要纠正“Claude for Legal 可完全本地独立运行”的假设；上游公开形态更偏向 Anthropic plugin / managed agent 生态。 | Claude README |
| 系统 1 | V-5 至 V-8 | Valid | High | 1 / 2 | 建议优先上线系统 1 做小范围律师试用，但初期不建议一开始就放开给所有律师。 | Rollout strategy |
| 系统 1 | V-9 至 V-12 | Needs Clarification | Medium | 2 / 5 | 现有 AI 工具接入、账号隔离、matter 管理和个人工作区深度，取决于最终入口面与身份策略。 | Surface selection pending |
| 系统 1 | V-13 至 V-14 | Valid | High | 1 / 2 | 最小验收应按真实律师场景定义；法律内容适配由 Pacgate 主导，技术支持与运行验证由 Cubecloud 陪跑。 | Proposal |
| 系统 2 | VI-1 至 VI-3 | Valid | High | 1 / 5 | 可确认 Lavern 是参考仓库与部署对象，但落地上更合理的是 fork / adapt，而不是直接承诺上游原样生产交付。 | Proposal + Lavern README |
| 系统 2 | VI-4 至 VI-6 | Error | High | 5 | 需纠正“Lavern 已是成熟生产系统”的理解；上游 README 明确表示其不是产品，且当前没有 dense / vector retrieval。 | Lavern README |
| 系统 2 | VI-7 至 VI-10 | Needs Clarification | High | 2 / 3 | 可以搭最小商品化原型，但真实客户入口、前端和自动化提交流程不应默认为固定交付。 | Phase 1 boundary |
| 系统 2 | VI-11 至 VI-13 | Valid | Medium | 2 / 3 | 飞书、微信、邮件接入和种子客户内测可做，但更适合作为顾问小时或增项。 | Integration effort |
| 系统 2 | VI-14 至 VI-17 | Valid | High | 1 / 2 | 应把 Human-in-the-loop、仅草稿输出、律师审批后再发客户写成默认安全姿态。 | Legal operating model |
| 双系统关系 | VII-1 至 VII-3 | Valid | Medium | 1 / 2 | 建议共享 matter 结构和部分知识资产，但不要承诺 Phase 1 完成完整双向同步体系。 | Scope control |
| 双系统关系 | VII-4 至 VII-6 | Valid | Medium | 1 / 2 | 优先把 prompt / workflow 改动做成配置与文档层，必要时再通过仓库修改与顾问小时推进。 | Delivery pragmatism |
| 分工与适配 | VIII-1 至 VIII-3 | Valid | High | 1 | 建议把 Package 2 改写为“部署、验证、技术评估、适配陪跑”，明确法律 playbook 与内容归 Pacgate 主导。 | Proposal rewrite |
| 分工与适配 | VIII-4 至 VIII-5 | Valid | Medium | 1 / 2 | 固定周会、问题清单、部署脚本、环境变量清单和故障手册都应显式写入交付件。 | Delivery discipline |
| RAG 与法源 | IX-1 至 IX-4 | Valid | High | 1 | 对权威法源，优先外部法律数据库 MCP；对 Pacgate playbook、模板、客户材料和复核结论，优先私有 RAG。 | Proposal |
| RAG 与法源 | IX-5 至 IX-6 | Valid | High | 1 | authority registry 应定义为结构、字段、版本与流程 starter，而不是大规模法规全文导入承诺。 | Proposal |
| RAG 与法源 | IX-7 至 IX-10 | Needs Clarification | Medium | 5 | 向量库、embedding、chunking、reranking 方案应放进技术 annex；当前不宜过早写死。 | Technical design pending |
| RAG 与法源 | IX-11 至 IX-13 | Needs Clarification | Medium | 2 / 5 | Phase 1 可先做轻量 context graph 结构，成熟 GraphRAG 与深度知识图谱留给后续阶段。 | Phase 2 evolution |
| RAG 与法源 | IX-14 至 IX-16 | Valid | High | 1 | 外部法源与内部经验必须区分来源、可被律师确认 / 驳回 / 标记优先级。 | Governance requirement |
| 律师与客户入口 | X-1 至 X-3 | Valid | Medium | 1 / 2 | 先明确本次真正提供的入口，再把 Bot / 监听 / 自动化作为可选扩展列示。 | Scope control |
| 律师与客户入口 | X-4 至 X-6 | Valid | Medium | 2 | 建议在书面回复中直接给出 3 至 5 个律师可操作场景，并按风险与实施成本给出种子客户入口排序。 | Reply quality |
| 安全与权限 | XI-1 至 XI-4 | Valid | High | 1 / 5 | 需明确默认本地保存、出域条件、IronClaw 作用范围和日志保留策略。 | Security annex |
| 安全与权限 | XI-5 至 XI-7 | Valid | High | 1 / 2 | matter 隔离、客户免责声明、远程运维和外部 MCP / API 的数据出域清单，应列成一张风险表。 | Security annex |
| SaaS 化 | XII-1 至 XII-3 | Irrelevant | High | 3 | 可给三档方向性方案，但必须明确属于 Phase 2 发现与报价，不是本次固定交付。 | Proposal boundary |
| SaaS 化 | XII-4 至 XII-10 | Irrelevant | High | 3 | 客户门户、多租户、账单、运维监控、预算拆分等均应进入后续 discovery / quote。 | Proposal boundary |
| 验收付款 | XIII-1 至 XIII-3 | Valid | High | 1 | 里程碑必须拆成“环境可运行、场景可验证、文档可交接”三层标准。 | Commercial discipline |
| 验收付款 | XIII-4 至 XIII-5 | Valid | Medium | 1 / 2 / 3 | 顾问小时记账方式和增项报价规则要提前写清。 | Commercial discipline |
| 验收付款 | XIII-6 至 XIII-8 | Valid | High | 1 | 即使不进入 Phase 2，也应明确 Pacgate 的数据权、使用权、自研延续权，以及系统 1 / 2 独立验收。 | Exit clarity |
| 开源合规 | XIV-1 至 XIV-3 | Valid | High | 1 / 2 | 开源许可证识别与合规责任需要明确；Pacgate 的二次适配成果与知识资产应归 Pacgate。 | License review |
| 开源合规 | XIV-4 至 XIV-6 | Valid | High | 5 | 需额外写清专有组件依赖和商业化限制，尤其是 future SaaS 时的开源合规边界。 | Claude README + Lavern README + license review |

## 6. 最值得优先进入工作板的议题

1. 锁定 Phase 1 边界语言，避免被问卷“带偏”为完整 SaaS 建设。
2. 给出硬件 annex，不再逐项口头解释 AIPC / eGPU / 并发 / 模型问题。
3. 单独说明 Claude for Legal 与 Lavern 的“参考价值”和“非承诺部分”。
4. 把 Package 2 和 Package 3 的表述改成“技术陪跑 + starter 结构”，避免客户理解成法律内容外包或完整法源库建设。
5. 把种子客户、飞书 / 微信 / 邮件入口、客户门户测试，全部挪到顾问小时或 Phase 2 options note。
6. 将验收标准拆成系统 1 与系统 2 两张表，避免“混在法律 Agent 适配”里无法验收。

## 7. 推荐的客户回复风格

1. 先承认客户问题合理，再把问题重新归并到几个真正的决策点，不要逐题防守。
2. 对范围外内容不直接说“不做”，而是说“本次 Phase 1 先完成本地验证与基础沉淀，商业化入口和多租户平台建议在 Phase 2 discovery 中展开”。
3. 对上游开源项目不做夸大承诺，统一使用“部署、验证、适配、吸收其工作流结构”这类表述。
4. 对硬件性能使用“目标区间 + 前提条件 + 升级路线”，不要使用孤立数字承诺。
5. 对数据与安全边界尽量画成表格或流程图，减少歧义。