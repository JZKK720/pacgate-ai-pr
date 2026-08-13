# Pacgate AI - 第一阶段建设计划书
## Cubecloud.io 本地法律 AI 试点方案 - 2026年5月修订版

> **合同签署前文件**
> 本修订版反映 Pacgate 当前的采购方向：先启动第一阶段本地部署与实操试点，而不是一开始就购买完整的 SaaS 平台。
> 本仓库中 Cubecloud 已完成的原型工作，继续作为售前架构与研究支持材料。
> 完整 Pacgate SaaS 报价将明确延后，待第一阶段试运行、操作模式与学习成果被验证后再行提出。

---

## 执行摘要

Pacgate 眼前真正的采购决策，并不是立刻为完整的 Pacgate SaaS 建设买单，而是先启动一个**私有的第一阶段法律 AI 试点**。这个试点的价值在于：先让律所拥有可日常使用的本地 AI 能力，先在真实工作中学习两套优秀开源法律 Agent 的运行方式，并同步开始沉淀未来自有平台真正需要的知识结构、context graph 与 RAG 工作基础。

因此，这一版提案把第一阶段明确定位为一个**商业化试点包**，而不是完整软件建设合同。Cubecloud 负责安装两套本地 AI 系统，完成两套法律 Agent 应用的 Pacgate 适配，启用起步版知识与检索层，并在 Pacgate 学习、运行和判断未来产品方向的过程中，继续提供顾问陪跑支持。

在这一版第一阶段方案中，Cubecloud 提供并交付：

1. **两套 AIPC 级本地 AI 系统**，搭载 Cubecloud 标准本地 AI 层与 Agent OS 表层，并配套外接 GPU Dock。
2. **两套面向 Pacgate 的法律 Agent 应用定制部署**，作为实操与学习计划的核心：
   - **Claude for Legal 适配版本**，重点参考其 practice bundle、playbook、connector 以及律师审核型工作流执行方式。
   - **Lavern 适配版本**，重点参考其本地多 Agent 编排、对抗式审查、验证闭环与交付件导向能力。
3. **起步版私有知识基础设施**，帮助 Pacgate 开始整理 authority materials、客户先例、matter 文件夹、context graph 约定与本地检索流程。
4. **长期顾问与陪跑支持**，单独计费，覆盖远程或现场支持、工作流调优、connector 规划、MCP 扩展，以及未来第二阶段发现与规划。

这样的结构同时符合客户的反向报价意见，也符合 Cubecloud 自身的 services-first rollout 模式：先把真正可用的本地系统部署起来，从真实使用中学习，再去报价更大的 Pacgate SaaS agentic platform，而不是反过来先卖一个范围过大的产品建设包。

### 商业快照

| 商业视图 | 当前工作报价基线 |
|----------|--------------|
| 第一阶段固定交付小计 | **USD 16,612 / CNY 119,600** |
| 含 3 个工作日首次交付现场安装与培训 | **已包含在固定交付内，不另收费** |
| 可选 40 小时远程顾问预留（1 年有效） | **USD 2,778 / CNY 20,000**（独立服务订单，详见《可选服务与附加费用清单》） |
| 可选年度许可续费（第 2 年起） | **USD 611 / CNY 4,400 / 年**（独立服务订单，按初始许可费 25% 计，详见《可选服务与附加费用清单》） |
| 可选 5 天现场支持包 | **CNY 43,200 参考价**（独立服务订单，差旅另计，详见《可选服务与附加费用清单》） |
| 差旅与住宿 | 单独按次确认或实报实销 |
| 第二阶段 SaaS 建设报价 | 延后到第一阶段试点成功之后 |

> 本提案中的 USD 报价已含税。文中 CNY 金额按参考汇率 **USD 1 = CNY 7.20** 换算展示，且尚未计入额外 3.5% 增值税；最终开票币种、汇率与税务处理在签约时确认。

### 第一阶段现在买到的内容

| 本提案当前包含 | 现在就有价值的原因 |
|----------------|--------------------|
| 两台本地 AI 机器 | 让 Pacgate 立即拥有私有的日常 AI 工作基础设施 |
| Cubecloud 标准 AI 层与 Agent OS 表层 | 让聊天、审查、搜索、安全与自动化落在同一操作层上 |
| 两套法律 Agent 应用适配 | 让 Pacgate 能在真实工作中并行比较两种开源法律系统模式 |
| 起步版 context graph 与 RAG 设置 | 立即开始沉淀长期内部知识资产，而不是等未来平台再做 |
| 首次交付现场安装与培训（3 个工作日） | 两套系统上架、联网、基础部署验证与关键用户操作培训，不另收费 |
| 40 小时远程顾问支持（1 年有效） | 部署后工作流调优、connector 规划、知识库增量指导、Phase 2 技术评估与系统级远程排障 |

### 第一阶段暂时不买的内容

| 延后到后续阶段 | 延后的原因 |
|----------------|-----------|
| 完整 Pacgate SaaS 报价 | 客户当前不希望先购买完整平台 |
| 最终的多租户 Pacgate Web 产品 | 需要先从本地试点中获得真实操作模式 |
| 面向终端客户的 SaaS 定价模型 | 应基于已验证的法律工作流与支持成本来决定 |
| 更广泛商业化的 OEM / licensing 经济模型 | 应在试点成功之后再谈，而不是现在先锁死 |

---

## 范围参考

| 参考项 | 在本提案中的作用 |
|--------|------------------|
| 客户反向报价意见 | 先从两套本地 AI 系统、两套法律 Agent 与顾问支持开始 |
| Cubecloud operating layer | OpenSpace、Open WebUI、IronClaw、Hermes、Warp ADE、OpenCode 作为标准本地表层 |
| 第一阶段实施锚点 | Claude for Legal 与 Lavern |
| 市场与商业模式参考 | Harvey、Crosby、Moritz |
| 支撑型实现参考 | Mike 与 Suzie Law |
| 未来平台蓝图 | 本仓库现有的 `pacgate-ai/` Rust workspace |
| 研究资料 | `scope-assets/` 中的法律 AI 调研材料与相关建设文件 |

---

## 竞争格局与差异化

> 研究基础：Harvey、Crosby、Moritz、Claude for Legal、Lavern、Mike 与 Suzie Law，并结合 Cubecloud 的本地优先交付模式，以及 Pacgate 当前先上硬件与法律 Agent 的决策方向。

### 市场地图

| 公司 / 系统 | 模式 | 交付姿态 | 对 Pacgate 的意义 |
|-------------|------|----------|-------------------|
| **Harvey** | 企业级法律 Copilot | Cloud SaaS | 是法律 AI 质量、信任与文档工作流的标杆，但不是 Pacgate 当前首先要买的模式 |
| **Crosby** | Agentic law firm | 云端服务 | 证明窄工作流、清晰打包与透明收费可以先于大平台完成商业化 |
| **Moritz** | AI 驱动的 MSO 平台 | 云服务 + 律师网络 | 证明 services-first rollout 与清晰边界能够更快落地 |
| **Claude for Legal** | 开源法律插件与工作流系统 | 自托管 / 适合 managed agent | 是 practice bundle、playbook、connector 与审查型工作流打包的强参考 |
| **Lavern** | 开源多 Agent 法律系统 | 本地或混合 | 是本地部署、 specialist agents、对抗审查与验证闭环的强参考 |
| **Pacgate AI - 第一阶段** | 由律所自有并控制的本地试点系统 | 两套本地 AI 系统由 Pacgate 控制 | 让 Pacgate 在承诺完整 SaaS 之前，先自己学习、运行并沉淀私有法律知识资产 |

### Harvey - 质量标杆，而不是当前采购路径

Harvey 仍然是生产级法律 AI 质量的重要参照，尤其体现在结构化文档工作流、可验证引用与耐久型 Agent 编排方面。Pacgate 仍应吸收这些质量经验，但第一阶段 **并不** 打算复制 Harvey 的整个云平台。当前真正需要吸收的是更窄的结论：高质量法律 AI 不只是模型接入，而是工作流设计、审查闸门与证据处理能力。

### Crosby 与 Moritz - 对 rollout 顺序的商业启示

Crosby 与 Moritz 更重要的价值不是底层技术，而是商业验证。它们都说明：法律 AI 完全可以先从更窄的范围、更清晰的包装、更强的服务组件做起，再进入更大的平台扩张。这一点与 Pacgate 当前方向高度一致：

1. 先从受控、清晰的操作范围开始。
2. 先用真实工作去学习，而不是过早销售一个过宽的平台。
3. 再把真实使用转化为后续的包装、定价与产品决策。

### Claude for Legal - practice bundle 与 legal connector 的参考模型

Claude for Legal 是第一阶段的重要参考，因为它给出了一个 Pacgate 可以立即学习并改造的实际结构：

| 相关能力 | 为什么适合第一阶段 |
|----------|--------------------|
| Practice-area plugin bundles | 让 Pacgate 按法律领域组织工作流，而不是只靠通用提示词 |
| Cold-start interview 与 practice profile | 很适合沉淀 Pacgate 自己的 playbook 与操作规则 |
| MCP connectors | 对未来文档系统、研究源与内部工具连接有直接参考价值 |
| Named workflow agents | 适合重复型法律审查任务与定时监测任务 |
| Lawyer-review guardrails | 符合 Pacgate 对正式法律输出必须由律师控制的要求 |

这一部分的核心不是照搬品牌，而是学习一种结构：如何把法律工作流、playbook、profile 与 connector 打包成真正可运行、可持续迭代的系统。

### Lavern - 本地多 Agent 法律工作的参考模型

Lavern 是第一阶段的另一个关键参考，因为它与 Pacgate 当前强调的本地优先、边用边学路径非常贴合：

| 相关能力 | 为什么适合第一阶段 |
|----------|--------------------|
| 本地或混合运行模式 | 让敏感工作尽量留在 Pacgate 控制的硬件内 |
| Multi-agent specialist team model | 给 Pacgate 一个可观察、可拆解的 Agent 架构样本 |
| Evidence 与 counter-evidence debate | 有利于提升法律审查质量与对抗式检查能力 |
| Ten-pass verification loop | 有利于输出可审核的交付件，而不是普通聊天记录 |
| Deliverable-first posture | 比通用聊天机器人更适合法律工作产出 |

Lavern 的特殊价值在于它把体系结构展示得很清楚。Pacgate 团队可以直接观察 Agent、证据、验证与交付件是如何组合在一起的，再决定未来哪些部分应变成 Pacgate 自有产品逻辑。

### Mike 与 Suzie Law 的支撑型模式

Mike 与 Suzie Law 在本提案中仍然重要，但它们是 **支撑性模式**，而不是第一阶段点名交付的两套系统。

| 支撑模式 | 来源 | 第一阶段意义 |
|----------|------|--------------|
| DOCX tracked changes 与清晰审查界面 | Mike | 对 Pacgate 未来的起草与红线工作流有参考价值 |
| 引用纪律与来源落地 | Mike + Suzie Law | 对 Pacgate 的内部审查与审计姿态有直接意义 |
| Workflow library 与 persona pack | Suzie Law | 可作为 Pacgate 工作流目录的种子结构 |
| Local-first 知识存储与检索 | Suzie Law | 适合用于第一阶段的 RAG 与知识索引约定 |

### 为什么第一阶段应该这样开始

1. 让 Pacgate 立即获得有用的私有 AI 能力，而不是继续等待完整产品建设。
2. 让 Pacgate 在自己的机器上并行观察两种强势开源法律系统模式。
3. 与 Cubecloud 现有硬件、操作表层与 services-first 交付方式保持一致。
4. 为 Pacgate 自己的 legal context graph 与 RAG 资产建立现实起点。
5. 通过延后大型 SaaS 范围，降低产品判断错误与范围膨胀风险。
6. 保留未来走向 Pacgate SaaS 系统的可信路径，但不要求现在就承担那笔承诺。

---

## 第一阶段架构摘要

```
┌────────────────────────────────────────────────────────────────────────────┐
│                    PACGATE AI - 第一阶段本地试点                           │
├────────────────────────────────────────────────────────────────────────────┤
│  设备 A：Cubecloud 本地 AI 节点                                            │
│  - AIPC 标准单元 + 外接 GPU Dock 搭配                                      │
│  - Cubecloud 表层：Open WebUI、OpenSpace、IronClaw、Hermes               │
│  - 法律 Agent 应用 A：Claude for Legal 适配版                              │
│  - 主要用途：playbook、connector、结构化工作流执行                         │
├────────────────────────────────────────────────────────────────────────────┤
│  设备 B：Cubecloud 本地 AI 节点                                            │
│  - AIPC 标准单元 + 外接 GPU Dock 搭配                                      │
│  - Cubecloud 表层：Open WebUI、OpenSpace、IronClaw、Hermes               │
│  - 法律 Agent 应用 B：Lavern 适配版                                        │
│  - 主要用途：多 Agent 对抗审查、验证闭环、交付件输出                       │
├────────────────────────────────────────────────────────────────────────────┤
│  共享私有层                                                                 │
│  - Cubecloud Agent OS 表层                                                  │
│  - 通过 Ollama / 审批模型运行本地模型                                       │
│  - 起步版 authority registry 与 matter 文件夹                               │
│  - 本地 context graph 约定与向量索引                                       │
│  - 设备间私有网络连接，并预留未来扩展节点                                   │
├────────────────────────────────────────────────────────────────────────────┤
│  延后到未来状态                                                             │
│  - 完整 Pacgate SaaS 平台                                                   │
│  - 自定义多租户产品栈                                                       │
│  - 更广泛的面向客户包装与定价                                               │
└────────────────────────────────────────────────────────────────────────────┘
```

### 第一阶段中的 Cubecloud 表层角色

| Cubecloud 表层 | 第一阶段作用 |
|----------------|-------------|
| **OpenSpace** | 团队控制与共享记录界面，用于工作流可视性与交接视图 |
| **Open WebUI** | 私有 AI 工作空间，用于本地聊天、搜索、检索与任务执行 |
| **IronClaw** | 安全与策略边界表层，用于敏感流程控制与批准路径 |
| **Hermes** | 记忆、任务跟进与定时工作流支持 |
| **Warp ADE** | 面向技术调优、MCP 工作与未来工作流工程的共享环境 |
| **OpenCode** | 本地代码与配置迭代表层，用于调整 prompt、connector 与辅助工具 |

### 哪些架构内容继续延后

本仓库现有的 `pacgate-ai/` Rust workspace 仍然有价值，但现在它被定位为 **未来产品蓝图**，而不是第一阶段的报价交付范围。等第一阶段运行成功之后，Pacgate 再决定哪些部分应进入未来的专有 SaaS 或私有多租户系统。

---

## Phase 0 - 售前基线 *(已完成)*

**Owner：** Cubecloud R&D  
**Status：** 已完成  
**商业处理方式：** 已包含在售前工作中

### 已经准备好的基线资产

| 资产 | 当前角色 |
|------|----------|
| `pacgate-ai/` Rust workspace 脚手架 | 未来 Pacgate 平台蓝图 |
| 架构图与概念页面 | 对齐讨论与商业说明材料 |
| 建设计划与研究文件 | 商业与技术叙事支持 |
| 开源法律 AI 调研集 | 第一阶段定制决策的参考材料 |

Phase 0 仍然有意义，因为它让 Pacgate 看到了更长期的方向，但它不再被描述为眼前这笔付费建设的主线。

---

## Workstream 1 - 两套本地 AI 系统与 Cubecloud 标准层

**Owner：** Cubecloud deployment team  
**商业角色：** 第一阶段核心包  
**主要结果：** 两套可立即投入日常使用与实验的 Pacgate 本地 AI 系统

### 交付内容

| 交付项 | 范围 |
|--------|------|
| 两套 AIPC 级系统 | 下单前确认最终硬件 BOM |
| 外接 GPU Dock 搭配 | 根据所选本地模型与负载配置 |
| Cubecloud 标准 AI 层 | 本地推理运行时、模型接入、表层集成与部署基线 |
| Agent OS 表层启用 | 按第一阶段 agreed scope 启用 OpenSpace、Open WebUI、IronClaw、Hermes、Warp ADE、OpenCode |
| 私有网络基线 | 节点间安全连接，并为后续私有扩展预留基础 |
| 本地存储与安全基线 | matter 文件、authority materials 与审查输出保留在 Pacgate 控制范围内 |

### 验收标准

1. 两台机器都能进入可用的 Cubecloud 操作表层。
2. 本地模型与获批工作流能在 Pacgate 控制的硬件上运行。
3. Pacgate 可以用这两套系统进行内部法律审查与知识工作，而不依赖公有 SaaS 控制平面。

---

## Workstream 2 - 法律 Agent 应用 A：Claude for Legal 适配

**Owner：** Cubecloud legal-agent adaptation team  
**商业角色：** 第一阶段核心包  
**主要结果：** 一套基于 Claude for Legal 结构、适配 Pacgate 的法律工作流系统

### 适配重点

| 领域 | 第一阶段目标 |
|------|--------------|
| Practice bundles | 优先覆盖 Pacgate 初期重点：数据合规、AI 产品合规、Web3 / RWA 合规 |
| Practice profile | 沉淀 Pacgate 的审查姿态、升级规则、交付风格与律师审批边界 |
| Workflow packaging | 准备一小套可用的法律审查命令与工作流 |
| Connector planning | 明确未来文档系统与研究系统的 MCP / 集成优先级 |
| Review guardrails | 确保输出保持为律师审核前的草稿材料，而不是自动法律意见 |

### 这台机器为什么重要

它会成为 Pacgate 学习“法律团队如何组织重复型工作流、playbook 规则与 connector”的最直接参考样本，而无需马上投入完整自研平台。

---

## Workstream 3 - 法律 Agent 应用 B：Lavern 适配

**Owner：** Cubecloud legal-agent adaptation team  
**商业角色：** 第一阶段核心包  
**主要结果：** 一套基于 Lavern 模式、适配 Pacgate 的本地多 Agent 法律系统

### 适配重点

| 领域 | 第一阶段目标 |
|------|--------------|
| Specialist roles | 选出适合 Pacgate 的一组法律 Agent 角色与审查行为 |
| Debate pattern | 在确实能提升质量的地方引入 evidence / counter-evidence 审查 |
| Verification loop | 保留多轮验证闭环，确保输出在交付前被审查 |
| Local run mode | 在策略要求下尽可能让文档处理留在 Pacgate 控制硬件内 |
| Deliverable packaging | 输出备忘录、审查结果或红线准备材料，而不是普通聊天记录 |

### 这台机器为什么重要

它会成为 Pacgate 观察“更 agentic、更本地化的法律系统如何运行”的实践样本，尤其是当编排、挑战与验证被当作第一性设计问题来处理时会是什么样。

---

## Workstream 4 - 起步版法律 Context Graph、知识库与 RAG

**Owner：** Cubecloud knowledge-workflow team  
**商业角色：** 第一阶段核心包  
**主要结果：** Pacgate 开始建立自己的私有法律知识资产，而不是只运行孤立聊天工具

### 交付内容

| 交付项 | 范围 |
|--------|------|
| 起步版 authority registry | 组织法律法规、监管规则、内部指导、先例笔记与工作材料 |
| Matter 文件夹规范 | 建立文档、输出与审查痕迹的可复用存储结构 |
| Context graph 约定 | 定义 authority、client、matter、template 与 output 的关系逻辑 |
| 本地 RAG starter | 为第一批工作语料启用私有索引与检索 |
| Retrieval usage guidance | 定义哪些来源可信、律师如何复核、哪些部分仍然保留人工 |

### 设计原则

第一阶段并不承诺一个完成版企业知识平台。它交付的是一套 **可用的起步系统**，让 Pacgate 可以先建立习惯、文件结构与来源集合，为未来的专有平台打基础。

---

## Workstream 5 - Onboarding、操作手册与交接

**Owner：** Cubecloud delivery and enablement team  
**商业角色：** 第一阶段核心包  
**主要结果：** Pacgate 能清楚理解两套系统各自的角色，并能有把握地投入使用

### 交付内容

| 交付项 | 范围 |
|--------|------|
| 用户 onboarding 会议 | 面向日常法律使用场景的入门培训 |
| 操作 playbook | 说明何时使用哪一台机器，以及如何审查输出 |
| Workflow demonstrations | 用 Pacgate 场景演示样例工作流 |
| Safety 与 review guidance | 明确律师审批与来源复核边界 |
| 交接材料 | 为 Pacgate 后续持续内部实验提供实用说明 |

---

## Workstream 6 - 持续顾问支持、现场协助与第二阶段发现

**Owner：** Cubecloud advisory team  
**商业角色：** 按时计费服务线（独立服务订单）；客户已选购 40 小时顾问预留  
**主要结果：** Pacgate 在内建能力过程中持续得到专家支持

### 固定交付已包含的现场服务

| 服务 | 时长 | 费用 |
|------|------|------|
| 首次交付现场安装与培训 | 3 个工作日 | 已包含在固定交付内，不另收费 |

覆盖内容：两套系统上架与联网、Cubecloud 标准 AI 层基础部署验证、Agent OS 表层启用确认、关键用户操作培训（面向日常法律使用场景的入门指导）。

### 可选顾问与现场支持（独立服务订单）

| 服务 | 计费方式 | 订单文件 |
|------|---------|----------|
| 远程顾问支持 | CNY 500 / 小时 | 《远程顾问服务订单》 |
| 20 小时远程顾问预留 | CNY 10,000 | 《远程顾问服务订单》 |
| 40 小时远程顾问预留 | CNY 20,000（1 年有效） | 《远程顾问服务订单》 |
| 现场 workshop 或 troubleshooting | 按小时或按天，另加差旅 | 《现场服务订单》 |
| 5 天现场支持包 | CNY 43,200 参考价，另加差旅 | 《现场服务订单》 |
| Workflow 与 prompt 优化 | 按小时或按任务估算 | 《远程顾问服务订单》 |
| MCP / connector 规划 | 按小时或按任务估算 | 《远程顾问服务订单》 |
| 第二阶段 SaaS discovery | 在完整建设报价前单独开展 | 另行约定 |

### 原则

咨询与陪跑不是附属项，而是这套第一阶段方案的核心部分。Pacgate 需要通过它把两台机器的试点，逐步转化为真正的内部知识、流程设计与未来产品方向。顾问与现场支持通过独立服务订单签署，不与 HWOS / LegalAgent 合同捆绑，客户可按需选购。本合同客户已选择购买 40 小时远程顾问预留（CNY 20,000，1 年有效）。

---

## 延后第二阶段 - Pacgate SaaS Agentic System

本提案刻意 **不** 对完整第二阶段 SaaS 建设进行报价或承诺。只有在第一阶段已经证明操作模式有效、并让 Pacgate 获得足够证据之后，才应该开启下一轮报价。

### 若试点成功，第二阶段可能讨论的内容

1. Pacgate 自有品牌的多租户法律 AI 产品设计。
2. 基于真实 Pacgate 使用数据的自定义 workflow engine 与 matter model。
3. 面向重复客户交付的文档生成与红线工具包装。
4. 面向客户的包装、定价、支持与治理模型。
5. 判断当前 Rust workspace 应成为主产品核心、私有部署层，还是混合架构的一部分。

---

## 技术栈摘要

| 层级 | 第一阶段当前定位 |
|------|------------------|
| 本地硬件 | 两套 Cubecloud AIPC 级系统，外接 GPU Dock 搭配在下单前确认 |
| 操作层 | Cubecloud Agent OS 表层：OpenSpace、Open WebUI、IronClaw、Hermes、Warp ADE、OpenCode |
| 本地 AI 运行时 | Ollama 与获批本地模型栈，在政策允许时可接入获批外部提供商 |
| 法律 Agent 参考 A | Claude for Legal 的 playbook、practice profile、bundle 与 connector 结构 |
| 法律 Agent 参考 B | Lavern 的本地 specialist agent、对抗审查、验证与交付件结构 |
| 知识层 | 起步版 authority registry、matter 文件夹、context graph 约定与本地检索流程 |
| 未来自定义平台参考 | `pacgate-ai/` Rust workspace 及相关架构材料 |

### 关于未来自定义平台的说明

本仓库中的 Rust 架构在战略上仍然重要，只是它现在从眼前的商业范围中退出，转而成为未来产品规划材料，直到试点真正证明 Pacgate 下一步应该建设什么。

---

## 风险登记表

| 风险 | 可能性 | 影响 | 缓解方式 |
|------|--------|------|----------|
| 硬件 BOM 确认过早或过晚 | 中 | 中 | 在 PO 前确认最终 AIPC + 外接 GPU Dock 搭配，并在报价锁定前完成 |
| 第一阶段被第二阶段期待挤爆 | 高 | 高 | 严格维持边界：现在是 pilot，SaaS 报价放后面 |
| 开源法律系统需要比预期更多的 Pacgate 适配 | 中 | 中 | 把法律 Agent 交付定位为 adaptation 与 enablement，而不是现成替代品 |
| 初期检索来源不完整 | 高 | 中 | 先从精挑细选的 starter corpus 开始，并在顾问支持下逐步扩展 |
| 用户把 AI 草稿误当成最终法律意见 | 中 | 极高 | 在每条工作流中保留律师审查闸门与操作手册 |
| 私有网络与本地知识习惯在交付后缺乏负责人 | 中 | 中 | 提供交接材料，并在学习期保持持续顾问支持 |

---

## 附录 A - 第一阶段报价结构

> 下表金额用于展示第一阶段当前的客户沟通报价基线。
> 具体硬件型号、顾问费率、差旅假设与可选项，后续都可以调整，不需要因此改动提案的整体包结构。
> 下表中的 CNY 金额按参考汇率 **USD 1 = CNY 7.20** 换算展示；签约与开票时再按最终约定确认。

### 报价摘要

| 类别 | 工作金额（USD / CNY） |
|------|----------|
| Package 1 - 硬件与本地 AI 基础层 | **USD 11,056 / CNY 79,600** |
| Package 2 - 两套法律 Agent 交付 | **USD 4,167 / CNY 30,000** |
| Package 3 - 起步版知识与 RAG 启用 | **USD 1,389 / CNY 10,000** |
| **第一阶段固定交付小计** | **USD 16,612 / CNY 119,600** |
| 可选初始远程顾问预留（40 小时） | **USD 2,778 / CNY 20,000** |
| **差旅前的第一阶段工作预算** | **USD 19,390 / CNY 139,600** |

### Package 1 - 两套本地 AI 系统与 Cubecloud 标准层

| 项目 | 数量 | 工作金额（USD / CNY） | 说明 |
|------|------|-----------------------|------|
| Cubecloud AIPC 标准单元 | 2 | USD 6,111 / CNY 44,000 | 两套本地 AI 节点 |
| 外接 GPU Dock + 审批显卡套件 | 2 | USD 972 / CNY 7,000 | 两套外接 GPU Dock 搭配 |
| 本地内存 / 存储升级 | 2 | USD 694 / CNY 5,000 | 两套节点的内存与存储升级 |
| Cubecloud 标准 AI 层部署 | 2 个包 | USD 1,389 / CNY 10,000 | 每台本地节点各完成一轮部署 |
| Cubecloud Agent OS 表层启用 | 2 个包 | USD 1,056 / CNY 7,600 | 每台本地节点各完成一轮表层启用 |
| 私有网络基线配置 | 2 个包 | USD 833 / CNY 6,000 | 覆盖两套系统之间的私有网络基线 |
| **Package 1 合计** | | **USD 11,056 / CNY 79,600** | |

### Package 2 - 法律 Agent 应用交付

| 项目 | 数量 | 工作金额（USD / CNY） | 说明 |
|------|------|-----------------------|------|
| 面向 Pacgate 的 Claude for Legal 适配 | 1 | USD 1,389 / CNY 10,000 | 覆盖 practice profile、starter workflow 与 playbook 对齐 |
| 面向 Pacgate 的 Lavern 适配 | 1 | USD 1,389 / CNY 10,000 | 覆盖本地多 Agent 设置、审查行为与验证闭环 |
| Pacgate playbook / workflow tailoring | 2 个包 | USD 556 / CNY 4,000 | 对应两套本地系统的工作流 tailoring |
| 初始工作流演示与审查边界设置 | 2 个包 | USD 833 / CNY 6,000 | 对应两套系统的演示与审查边界说明 |
| **Package 2 合计** | | **USD 4,167 / CNY 30,000** | |

### Package 3 - 起步版 Context Graph、知识与 RAG 启用

| 项目 | 数量 | 工作金额（USD / CNY） | 说明 |
|------|------|-----------------------|------|
| 起步版 authority registry 设置 | 1 个包 | USD 208 / CNY 1,500 | 初始来源结构、分类与操作规则 |
| Matter 文件夹与 context graph 约定 | 1 个包 | USD 417 / CNY 3,000 | matters、sources 与输出材料的组织方式 |
| 本地 retrieval / RAG starter 设置 | 1 个包 | USD 556 / CNY 4,000 | 初始导入、检索模式与复核流程 |
| 交接与使用说明 | 1 个包 | USD 208 / CNY 1,500 | 操作说明与内部延续材料 |
| **Package 3 合计** | | **USD 1,389 / CNY 10,000** | |

### Package 4 - 顾问与支持服务

| 服务线 | 计费方式 | 工作费率（USD / CNY） |
|--------|----------|-------------------------|
| 远程顾问支持 | 按小时 | USD 70 / 小时 / CNY 500 / 小时 |
| 现场支持 | 按天 | 单独报价 + 差旅 |
| 现场支持 | 按小时 | 单独报价 + 差旅 |
| 差旅与住宿 | 实报实销或单独报价 | 按每次出行确认 |
| 额外 workflow / connector 工作 | 按小时或按范围估算 | USD 70 / 小时 / CNY 500 / 小时或单独 mini-SOW |

### 可选顾问预留示例

| 预留方案 | 工作金额（USD / CNY） |
|----------|-----------------------|
| 20 小时远程顾问 | USD 1,389 / CNY 10,000 |
| 40 小时远程顾问 | USD 2,778 / CNY 20,000 |
| 5 天现场支持 | 单独报价 + 差旅 |

### 建议付款结构

| 里程碑 | 触发条件 | 工作金额（USD / CNY） |
|--------|----------|-----------------------|
| Deposit | 硬件确认 + 第一阶段 kickoff / 采购启动 | USD 9,967 / CNY 71,760 (60%) |
| Milestone 1 | 两套本地系统安装并可运行 | USD 4,984 / CNY 35,880 (30%) |
| Final handover | 起步版知识 / RAG 交接完成 | USD 1,661 / CNY 11,960 (10%) |
| Advisory billing | 按月后付 | 按工时与材料结算 |

### 报价假设

1. 上述硬件金额，基于两套适配本次试点的 AIPC 级系统与外接 GPU Dock 组合，而不是更大规模的企业工作站集群。
2. 上述适配费用，基于 Pacgate 第一阶段试点所需的定向 tailoring，而不是从零建设全新的法律产品。
3. 文中 USD 报价已含税。CNY 金额按 **USD 1 = CNY 7.20** 的参考汇率展示，且尚未计入额外 3.5% 增值税；最终开票币种、汇率与税务处理在签约时确认。
4. 差旅、客户自有研究订阅与第三方数据源许可，不包含在固定交付小计中。
5. 超出约定试点范围的额外 MCP connector、workflow pack 或部署扩容工作，均单独报价。

### 本报价明确排除的内容

1. 本附录不包含完整 Pacgate SaaS 建设报价。
2. 不包含第二阶段面向终端客户的 SaaS 运营定价。
3. 不包含后续商业化阶段的 OEM licensing 结构。
4. 不包含更大范围的终端客户平台定价。

### 第二阶段开启前的决策闸门

Pacgate 与 Cubecloud 应在以下问题有了第一阶段证据之后，再开启下一轮报价：

| 决策问题 | 第一阶段需要的证据 |
|----------|--------------------|
| 哪些工作流的使用频率足够高，值得产品化？ | 真实机器使用记录、律师反馈、工作流日志 |
| 哪些法律 Agent 模式应该变成 Pacgate 自有特性？ | 对 Claude for Legal 与 Lavern 的并行学习结果 |
| Pacgate SaaS 平台真正应该采用什么数据模型？ | Matter 文件夹、authority pattern、context graph 使用方式与 RAG 行为 |
| Pacgate 面向下游客户应采用什么商业模式？ | 试点交付成本、支持负担与工作流复用度 |

### 摘要

| 类别 | 当前工作商业姿态 |
|------|--------------|
| 硬件与本地 AI 系统 | USD 11,056 / CNY 79,600 |
| 两套法律 Agent 应用交付 | USD 4,167 / CNY 30,000 |
| 起步版知识 / RAG 启用 | USD 1,389 / CNY 10,000 |
| 第一阶段固定交付小计 | **USD 16,612 / CNY 119,600** |
| 可选 40 小时顾问预留 | **USD 2,778 / CNY 20,000** |
| 差旅前的第一阶段工作预算 | **USD 19,390 / CNY 139,600** |
| 完整 Pacgate SaaS 建设 | 延后到第一阶段试点成功之后 |

---

*Prepared by Cubecloud Limited for Pacgate Law*  
*根据客户反馈与第一阶段试点方向修订 - 2026年5月29日*  
*开源参考系统仍遵循各自许可证。Pacgate 定制部署、适配与支持交付，以最终服务协议为准。*