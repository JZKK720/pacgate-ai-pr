# 资料收集目录 · 附录 A —— Agent 角色编排（Big Law 模式）v0.2

> 用途：以美国 Big Law 的人力流水线（pyramid / leverage model）为组织隐喻，定义本所 AI 系统的 agent 角色、分工与责任边界。**定位为内部展示与参考资料**：正式交付技术方的是《资料收集目录_百宸回填_第一二部分》（只描述人类角色与工作流程，agent 编排由技术方自行设计）；本附录随附供参考，不构成交付要求。
> v0.2 更新：新增 2.1 双金字塔对照表（美国职级→本所人类层→Agent），通用约束新增"利冲墙与权限子集"原则，与回填件 v1.1 的治理/支持角色对齐。
> 定位：**组织层设计**。与 `01_总路线图` 的技术分层（模型路由/法域包/skill）正交：本表定"谁干什么、谁向谁交、谁能拍板"，路由与密级仍按总路线图与 RBAC 表执行。
> 填写人：Sylvie ｜ 2026-07-10 ｜ 状态：初稿待合伙人确认
> 红线（不变）：**全部 agent 输出均为供律师复核的草稿；对外签发权、法律结论确认权永远在人类律师，任何 agent 不得成为"署名律师"。**

---

## 一、评估结论：Big Law 模式为什么适合做 agent 编排

**核心判断：成立，且已被业界验证；但要"取其流程，弃其经济学"。**

### 1.1 为什么映射得好

Big Law 一个 matter 的标准流转是：
**Intake（立案/利冲）→ 任务分解（staffing）→ 专业组分派 → 各组作业 → 交叉审阅/内部辩论 → 升级（escalation）→ 合伙人终审 → 交付**。

这条流水线天然具备 agent 化的四个条件：

1. **分工颗粒度清晰**——每个环节输入/输出定义明确（数据室→审查表→问题清单→报告章节），正是 agent 之间 handoff 需要的接口。
2. **金字塔底层 = 吞吐层**——junior 干的本来就是"高度程式化 + 大批量"工作（文档审阅、抽取、核引文、做表），是 LLM 最强的场景。Harvey 总裁 Gabe Pereyra 的表述："firms are deeply hierarchical … the more junior parts of this hierarchy are focused on throughput — organizing vast troves of data or executing largely rote tasks. As these tasks become increasingly delegated to agents, intelligence replaces hierarchy."
3. **自带质量门**——Big Law 的 second-pair-of-eyes、cite-check、partner sign-off 就是现成的多级校验设计，直接对应本所"来源分级 + 引文核验 + 律师复核硬关卡"三原则。
4. **升级路径明确**——"超出授权即上报"的 escalation 规则，可直接翻译成 agent 的置信度阈值 + P0 一票否决上报机制。

### 1.2 必须修正的三点（Big Law ≠ 照抄）

1. **经济学倒置**：Big Law 金字塔为"计费杠杆 + 培养管线"而存在；agent 版底层近乎零边际成本，**杠杆率不再受人数限制，瓶颈移到律师复核带宽**。Pereyra 概括为 "a surplus of intelligence bottlenecked by judgment"。→ 设计含义：底层尽管并行放宽，**所有输出必须为"可快速复核"而设计**（三态表、diff/redline、可点验引用、风险分级摘要），否则省下的 associate 时间会原样变成合伙人复核时间。
2. **层级要浅**：人类金字塔 5–7 级是管理幅度所迫；agent 之间通讯每多一跳就多一次失真。Lavern 作者 Antti Innanen 的实测教训："agents can talk past each other; checking loops catch mistakes but sometimes introduce new ones; adding more agents does not automatically produce better output — the problems are mostly in communication."→ **压成 3 层：编排层 / 专业作业层 / 校验层**，人类律师在顶。
3. **并行有边界**：多 agent 并行适合**读密集、可切分**任务（尽调、检索、批量审查）；Anthropic 自家多智能体研究系统的工程结论也是 orchestrator-worker 在可并行研究任务上大幅优于单 agent（代价是 token 消耗成倍）。但**单文档顺序修改**（合同 redline 定稿）并行会产生写冲突——用"单主笔 + 校验员"而非 swarm。→ 尽调线用金字塔，交易文件线用"主笔-复核"双人组。

### 1.3 业界验证：确有人按此做成

| 案例 | 模式 | 与本所的相关性 |
|---|---|---|
| **Crosby**（AI-native 律所，Bain Capital Ventures 投资，客户含 Cursor） | "A lawyer oversees a swarm of AI agents"：专业 agent 做初审/redline/风险评分/对手方反应预测，**执业律师终审担责**；按份计费、多数合同 1 小时内返回 | 证明"agent 干活 + 律师把关"在真实执业中商业闭环；其 playbook 机制（客户定义红线，agent 按 playbook 作业）与本所 Playbook 优先级最高的判断一致 |
| **Harvey**（Workflow Agents / Agent Builder） | 明确以 associate 为隐喻："agents … complete specific tasks, similar to how a junior associate would handle structured legal work"；Paul Weiss 等把合伙人打法编码为 workflow 交给系统跑 | 证明"把所内方法论编码为 agent 编排"是头部所正在走的路；本所 practice profile + skill 骨架就是同一思路 |
| **Lavern**（Antti Innanen，2026.4，即本目录已调研对象） | 66 个 agent 的"律所"：partner agent 先访谈定 context → 分解 → 专业组作业 → 内部辩论 → orchestrator 综合；**本地模型、数据不出机、30 分钟轮询的 retainer 模式** | 与本所"本地大模型 + Agents + 数据不出境"部署前提几乎同构；其失败教训（通讯失真、检查环引入新错）是本表 1.2 的直接依据。详见所内《Lavern Agentic 律所深度调研（2026年5月）.pdf》 |
| **dd-agents**（开源，本所方案 B 底座） | 9 域专家并行 + Red Flag Scanner + Judge + Executive Synthesis 的流水线，含交叉引用、溯源、质量门 | 本身就是一个"尽调 deal team"的 agent 化实现，改写清单已就绪 |
| **学术侧**：LawLuo（模拟律所接待-分派-作业协作）、Chatlaw（角色对齐 MoE 多 agent）、MASER（多 agent 法律交互仿真） | 多 agent 按律所角色分工在检索、文书、咨询任务上优于单模型 | 佐证角色化分工的有效性；亦提示评测集（本所 Step5）是保证协作质量的前提 |

**结论：方向正确、有活案可抄；本所差异化在"中国法内容 + 本地部署 + 密级/法域机制"，编排骨架不必自创。**

---

## 二、Agent 角色编排总图（三层 + 人类顶点）

```
                    ┌─────────────────────────────┐
 人类（非 agent）    │  主办合伙人 —— 终审签发（硬关卡）│  ← Big Law: signing partner
                    │  承办律师 —— 逐项复核/确认结论   │  ← Big Law: supervising associate
                    └──────────────┬──────────────┘
                                   │ 升级/交付
 编排层             ┌──────────────┴──────────────┐
 (1个)              │ A1 事项统筹 Agent（Matter Manager）│  ← Big Law: senior associate running the deal
                    └──┬─────────┬─────────┬──────┘
                       │分派      │分派      │分派
 专业作业层         ┌───┴──┐  ┌───┴──┐  ┌───┴───┐
 (按需并行)         │A3 九域 │  │A4 检索│  │A2 立案 │   ← Big Law: practice-group associates /
                    │专家组  │  │Agent │  │利冲Agent│      library & conflicts department
                    └───┬──┘  └───┬──┘  └───┬───┘
                        │ 产出全部过 ↓
 吞吐层             ┌────┴────────┴─────────┴────┐
 (低tier·大批量)     │ A7 文档流水 Agents（OCR/分类/│   ← Big Law: paralegals / staff attorneys
                    │ 抽取/审查表/脱敏关卡）        │
                    └──────────────┬─────────────┘
                                   ↓ 所有上行成果强制经过
 校验层             ┌──────────────┴─────────────┐
 (质量门)           │ A5 引文核验 + A6 反方复核     │   ← Big Law: cite-check + second-partner review
                    └────────────────────────────┘
                    A8 成文 Agent（report-assembly）→ 交承办律师
```

层级只有三跳（编排→作业→校验），任何成果上行到人类前必过校验层。

### 2.1 双金字塔对照：美国 Big Law 职级 → 本所人类层 → Agent 角色

> 阅读逻辑：美国大所的完整职级（7 级）先按"信息流与责任流"压缩为本所四个功能层（见回填件 v1.1 §1.1.1，压缩原则：压掉人事职级差异，保留谁分解/谁分析/谁复核/谁签发）；agent 角色再对位到各功能层。**压缩是两步映射的第一步，本表把两步串成一张图。**

| 美国 Big Law 职级 | 本所人类层（回填件 v1.1） | Agent 对应 | 说明 |
|---|---|---|---|
| Equity / Non-equity Partner（signing partner） | 合伙人（第4层） | **无 agent** | 终审签发是人类硬关卡，永不 agent 化 |
| Second Partner Review / Opinion Committee（复核职能） | 第4层职能（或 Counsel 兼任） | A6 反方复核 | 人类合伙人复核前的机器预检 |
| Counsel（Of / Special Counsel） | 并入第3/4层职能 | — | 非独立流程环节，故无独立 agent |
| Senior Associate（deal captain） | 主办律师（第3层） | A1 事项统筹 | 分解、分派、汇总、升级 |
| Mid-level Associates + 各组 specialist（tax/IP/employment 借调） | 承办律师（第2层，分条线） | A3 九域专家 + A4 检索 | 矩阵式"单域负责制"的 agent 化 |
| Junior Associate（cite-check 职能） | 第1层职能 | A5 引文核验 | Big Law 的 cite-checking 传统 → 全系统反幻觉枢纽 |
| Junior Associate / Staff Attorney / Paralegal | 助理/实习律师（第1层） | A7 文档流水 + A8 成文 | 吞吐层，低 tier 大批量 |
| Conflicts Department + 律所 General Counsel | 风控/利冲合规岗（治理） | A2 立案利冲 | 利冲墙规则由此岗定义，agent 执行 |
| Managing Partner / Executive Committee | 管理合伙人（治理） | 无专设 agent；**治理看板**（远期可参照 Harvey Spectre 式"律所运营 agent"） | Spectre 即公司运营 agent 原型：监控全所事件流自主处置运营性任务，见附录来源 |
| Legal Secretary | 行政秘书（支持） | A8 的交付流程人类对口 | 归档/用印/发送为人工动作，agent 只备料 |
| Marketing/BD ／ Billing | 市场·BD ／ 财务·计费（支持） | 远期可选（业绩标书 agent / 计费 agent） | 若建，权限继承人类角色边界：BD 仅脱敏聚合数据、计费与知识库隔离 |

---

## 三、角色卡（准确描述 · 分工 · 责任边界）

> 通用约束（适用于全部 agent，逐条对应总路线图八原则）：
> ① 输出必须带**来源分级**标注（权威核验/元典辅助/内部模板/模型推断）；② **无声补充禁止**——检索稀薄即报告并停；③ 密级按 RBAC 表（A/B/C/D/E），D 级凭据任何 agent 不可见；④ 法域为运行时参数，无包法域不得用模型知识顶替；⑤ 下游 agent 不得改写上游的事实记录，只能追加"异议/存疑"标注（保全审计链）；⑥ **权限子集原则**：任何 agent 的可调用范围恒为其人类对口角色权限的**子集**——agent 不得比它服务的人权限更大；⑦ **利冲隔离墙对 agent 同样生效**——检索/RAG 范围按事项隔离，agent 不得跨墙调用被隔离事项的任何内容（含向量库层面的隔离，需技术方在索引结构中落实）。

### A1 · 事项统筹 Agent（Matter Manager）
- **Big Law 对应**：主办资深 associate（跑 deal 的人）/ staffing coordinator。
- **职责**：接收已立案事项 → 按 practice profile 11 章分解任务 → 分派给 A2–A4/A7 → 维护检查清单与进度 → 汇总各域 findings → 产出执行摘要（deal-team-summary）→ 组织升级。
- **输入/输出**：输入=matter profile + 数据室索引；输出=任务分派单、进度台账、执行摘要草稿。
- **责任边界**：**不做任何领域实体分析**（防止编排者自己越权下结论）；不得跳过 A5/A6 校验直接上行；发现 P0（前置审批未过/一票否决项）必须即时上报承办律师，不得等批处理。
- **模型 tier**：Main（复杂分解/综合）；机械台账走 Low。
- **对应资产**：dd-agents Executive Synthesis + deal-team-summary skill。

### A2 · 立案与利冲 Agent（Intake & Conflicts）
- **Big Law 对应**：new business intake / conflicts department。
- **职责**：新事项结构化访谈（当事人、对手方、关联方、交易类型、法域）→ 企查查/内部客户档案跑利冲 → 识别文件管辖法（交律师确认）→ 建 matter-workspace 并登记台账。
- **责任边界**：只产出**事实性核查结果**（关联关系图谱、命中记录）；"是否构成利冲、是否可承接"的判断权在合伙人；未完成利冲核查的事项，A1 不得启动作业（硬顺序）。
- **模型 tier**：Low/Mid；数据仅 A + 授权 B 级。
- **对应资产**：cold-start（尽调立项版）+ 企查查连接器。

### A3 · 九域专家 Agent 组（Practice-Group Associates）
- **Big Law 对应**：各专业组的 mid-level associate（公司/税务/劳动/监管…各管一段）。
- **成员**：Legal / Finance / Commercial / ProductTech / Cybersecurity / HR / Tax / Regulatory / ESG，focus_areas 按《dd-agents 中国法智能体改写清单》执行。
- **职责**：仅在本域内，对 A7 预处理后的材料做实体分析：识别问题 → 按本所口径定级（P0–P3）→ 给法律依据（中国法引用格式：法律名+条款号/案号）→ 标记跨域线索（如 HR 发现的社保欠缴抄送 Finance/Tax）。
- **责任边界**：**严格单域**——不得对他域下结论，只能"抄送线索"；每条 finding 必须三态（有问题/无问题/资料不足），资料不足不得推断补齐；严重度定级是**建议级**，最终定级由承办律师确认；中国特有前置审批类（经营者集中/安审/国资程序/牌照）统一 P0 上报，不得自行降级。
- **模型 tier**：实质法律推理默认 Main（质量优先，原则 2）；证据摘录走 Mid。
- **对应资产**：dd-agents 9 个人格文件（中国化改写后）。

### A4 · 法律检索 Agent（Research Associate / Library）
- **Big Law 对应**：research associate + 图书馆员。
- **职责**：法规/案例检索（北大法宝、元典、国家法规库、裁判文书网）→ 时效性核验（现行有效/已修订/已废止）→ 按 authority_level 分级返回带出处的检索包。
- **责任边界**：只做**检索与客观归纳**，不得给"应如何适用"的结论；每条结果必须带可点验出处与检索时间；库内无结果时报告"检索稀薄"，禁止用模型知识或 web 填补（原则 6）。
- **模型 tier**：Mid；调用境内法源 MCP。

### A5 · 引文核验 Agent（Cite-Checker）
- **Big Law 对应**：cite-checking junior / 校对席。
- **职责**：对**所有上行成果**逐条核验：法条是否真实存在且现行有效、案号是否真实、引用与原文是否相符（元典核验 API + 法规库比对）。输出核验标记：✔通过 / ✘失败 / ⚠无法核验。
- **责任边界**：**只判真伪，不判优劣**；✘/⚠ 项不得删改，退回产出 agent 并在台账留痕；核验失败率超阈值（建议 5%）时整批退回并报 A1。**A5 是全系统反幻觉枢纽，任何绕过 A5 的交付路径均为违规。**
- **模型 tier**：Low + API 调用（机械比对为主）。

### A6 · 反方复核 Agent（Second-Partner Review / Devil's Advocate）
- **Big Law 对应**：second partner review / opinion committee 的挑战机制。
- **职责**：对 A1 汇总稿做三件事：① Red-flag 扫描（中国并购杀手项清单：未申报经营者集中、国资程序瑕疵、社保大额欠缴、权属瑕疵、两套账、数据出境违规、外资准入禁止、重大涉诉/被执行）；② 跨域一致性检查（同一事实在不同章定级矛盾、协议套内数字/定义冲突）；③ 反方立场挑战——对每个"无问题"结论问"漏了什么"，输出质疑清单。
- **责任边界**：只能**追加质疑与标注**，无改写权、无否决权；质疑由原作业 agent 回应或由承办律师裁断；与 A5 分设（真伪 vs 完备性），不得合并省略。
- **模型 tier**：Main（最高风险单可启用双模型并行 + 分歧标记，原则 2）。
- **对应资产**：dd-agents Red Flag Scanner + Judge；VCPE 套内一致性引擎。

### A7 · 文档流水 Agents（Paralegal Pool）
- **Big Law 对应**：paralegals / staff attorneys / 文档中心。
- **职责**：OCR、文件分类与数据室索引、结构化抽取、批量文件审查表（tabular-review，带类型列/三态/反编造）、**脱敏关卡**（上云前去标识化，原则 3 的执行者）。
- **责任边界**：**纯机械，零判断**——任何需要法律判断的字段标"待律师"；抽取必须可溯源到原文件页码/条款号；脱敏输出必须过人工关卡（每单必审或抽审，待决项 5）后方可出本地。
- **模型 tier**：Low（占绝大多数 token，省成本主战场）。
- **对应资产**：tabular-review + diligence-issue-extraction skill + OCR 连接器。

### A8 · 成文 Agent（Report Assembly / 文书装配）
- **Big Law 对应**：负责定稿排版的 junior + word processing。
- **职责**：按 practice profile（11 章目录、定级口径、引用规范、免责声明）把已过校验的 findings 装配成 docx 报告/审查意见/redline 交付件。
- **责任边界**：**只装配不创作**——内容一律来自上游已核验成果，缺内容留【待补】占位，禁止生成填充；免责声明与"供律师复核草稿"水印为强制模板项，不可删除。
- **模型 tier**：Mid/Low。
- **对应资产**：report-assembly 成文技能（待样本定稿）。

### 交易文件线的变体（B4）：主笔–复核双人组
尽调线（读密集、可切分）用上述金字塔；**合同起草/redline（写密集、单文档）不用 swarm**：
- **主笔 Agent**（= A3 相应域专家兼任）：单线程持笔，按 playbook 出 redline；
- **复核 Agent**（= A6）+ **引文核验**（= A5）串行把关；
- 承办律师逐条接受/拒绝修订（Word 修订模式交付）。

---

## 四、责任边界总表（谁能做什么 · 一页速查）

| 权限 | A1 统筹 | A2 利冲 | A3 九域 | A4 检索 | A5 核验 | A6 反方 | A7 流水 | A8 成文 | 承办律师 | 合伙人 |
|---|---|---|---|---|---|---|---|---|---|---|
| 任务分派 | ● | — | — | — | — | — | — | — | ●（改派） | ● |
| 领域实体分析 | ✕ | ✕ | ●本域 | ✕ | ✕ | ✕ | ✕ | ✕ | ● | ● |
| 风险定级 | 汇总 | ✕ | 建议级 | ✕ | ✕ | 质疑 | ✕ | ✕ | **确认级** | 终审 |
| 修改上游内容 | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ● | ● |
| 追加标注/质疑 | ● | ● | ● | ● | ● | ● | ● | ✕ | ● | ● |
| 法律结论 | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ● | ● |
| 对外交付/签发 | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | ✕ | **●唯一** |
| P0 即时上报义务 | ● | ● | ● | ● | ● | ● | ● | ● | ● | 接收 |

**升级链**：任何 agent 置信不足/检索稀薄/P0 → A1 → 承办律师 → 合伙人。跨级上报仅限 P0。
**硬关卡（不可绕过）**：利冲未清不开工 ｜ 脱敏未过不上云 ｜ A5 未过不上行 ｜ 律师未确认不定级 ｜ 合伙人未签发不出所。

---

## 五、【待确认】（并入资料收集目录第五节清单）

1. 本附录三层编排与技术方拟部署能力（Mike/Suzie Law/Crosby/Moritz）的映射：建议技术方 agent **对号入座**本表 A2/A4/A7 等角色，不另设平行体系（对应原【待确认】6）。
2. A5 核验失败率退回阈值（建议 5%）与 A6 双模型并行的启用范围（对应待决项 14）。
3. 一单多法域时 A1 统筹 vs 按文件分工（对应原【待确认】7）。
4. 律师复核带宽测算：B1 试点单按"agent 产出复核耗时/单"计量，作为扩大并行度的依据。

---

## 附：本附录依据的外部来源

- Harvey/Gabe Pereyra 论述与 Spectre：[Harvey's Spectre Agent Points to 'Law Firm World Model'](https://www.artificiallawyer.com/2026/04/03/harveys-spectre-agent-points-to-law-firm-world-model/)、[How Autonomous Agents Will Transform Legal](https://www.harvey.ai/blog/autonomous-agents-legal-is-next)、[Harvey Workflow Agents](https://www.harvey.ai/platform/workflow-agents)
- Crosby：[官网](https://crosby.ai/)、[Forbes 报道](https://www.forbes.com/sites/rashishrivastava/2026/03/31/why-this-ai-law-firm-is-ditching-the-billable-hour/)、[Bain Capital Ventures](https://baincapitalventures.com/insight/crosby-is-redefining-legal-work-with-ai-powered-contract-automation/)
- Lavern：[I Built An Agentic 'Law Firm', Now What?](https://www.artificiallawyer.com/2026/04/07/i-built-an-agentic-law-firm-now-what/)（另见所内 Lavern 深度调研 PDF）
- 金字塔结构变化：[The Death of the Associate Pyramid](https://www.lawyer-monthly.com/2026/01/ai-breaking-law-firm-associate-pyramid/)、[Axios: AI threatens Big Law's talent pipeline](https://www.axios.com/2026/05/02/ai-lawyers-law-firms-artificial-intelligence)
- 学术：[Chatlaw（角色对齐多 agent）](https://arxiv.org/abs/2306.16092)、[MASER](https://arxiv.org/abs/2502.06882)、[LLM-based legal agents 综述](https://www.oaepublish.com/articles/aiagent.2025.06)
- 工程：dd-agents [zoharbabin/due-diligence-agents](https://github.com/zoharbabin/due-diligence-agents)；Anthropic 多智能体研究系统工程经验（orchestrator-worker 并行适用边界）

*本附录为系统设计文档，不构成法律意见。*
