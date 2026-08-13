# Awesome Legaltech 资源清单（中文整理 · 含免费/付费标注）

> 来源：[Vaquill-AI/awesome-legaltech](https://github.com/Vaquill-AI/awesome-legaltech)
> 整理日期：2026-06-22 ｜ 用途：Pacgate「AI 律所系统」与「一人法务系统」选型参考

## 免费 / 付费图例

- 🟢 **免费 / 开源** — 完全免费，或开源可自托管（self-host），无强制付费。
- 🔵 **免费档 / Freemium** — 有免费层或免费配额，进阶功能/更高用量需付费。
- 🟡 **付费 / 商业** — 商业产品，需订阅或按量付费（部分提供试用/演示）。

> 说明：定价随时变动，下方标注基于仓库描述与公开信息；正式采购前请以官网为准。带 ⭐ 为对自研 AI 系统最直接有用项。

## 目录

1. [⭐ 法律数据 API](#1-法律数据-api)
2. [⭐ 机器学习数据集与语料](#2-机器学习数据集与语料)
3. [⭐ 法律 AI 模型与嵌入](#3-法律-ai-模型与嵌入)
4. [⭐ 法律 MCP 服务器](#4-法律-mcp-服务器)
5. [全栈法律 AI 平台](#5-全栈法律-ai-平台)
6. [法律检索平台](#6-法律检索平台)
7. [⭐ 文书自动化与起草](#7-文书自动化与起草)
8. [知识产权与专利技术](#8-知识产权与专利技术)
9. [合同全生命周期管理（CLM）](#9-合同全生命周期管理clm)
10. [公证与电子签名](#10-公证与电子签名)
11. [电子取证与文档审阅](#11-电子取证与文档审阅)
12. [案件管理与法律运营](#12-案件管理与法律运营)
13. [电子计费与法律支出管理](#13-电子计费与法律支出管理)
14. [面向消费者的法律服务（B2C）](#14-面向消费者的法律服务b2c)
15. [合规与 RegTech](#15-合规与-regtech)
16. [在线纠纷解决（ODR）](#16-在线纠纷解决odr)
17. [司法可及性与公益技术](#17-司法可及性与公益技术)
18. [⭐ 奠基性研究论文](#18-奠基性研究论文)

---

## 1. 法律数据 API

> 专为将判例、法规、法律文书检索进应用而设计的 API。数据集/语料几乎全部免费见第 2 节。

- 🟡 **Vaquill AI API** — 800万+美国判决 + US Code/CFR，语义检索 + 引文核验（开发者 API，付费；网页检索有免费档）。
- 🔵 **CourtListener REST API** 🇺🇸 — 900万+判决/案卷/法官；免费档 + 语义检索端点。
- 🔵 **LegiScan API** 🇺🇸 — 全美50州+国会立法 JSON；免费档每月3万次，进阶付费。
- 🟢 **Open States API v3** 🇺🇸 — 州议员/法案/投票/委员会，免费 REST API。
- 🟢 **USPTO Open Data Portal API** 🇺🇸 — 专利档案/检索/PEDS，免费。
- 🔵 **EPO Open Patent Services (OPS)** 🇪🇺 — 免费 RESTful API，注册用户有配额。
- 🔵 **The Lens Patent & Scholarly API** 🌍 — 1.4亿+专利记录；学术非商用免费档。
- 🟢 **EUR-Lex Webservice & CELLAR SPARQL** 🇪🇺 — 欧盟立法/判例/元数据，免费（24语言）。
- 🟢 **JudiLibre API（法国最高法院）** 🇫🇷 — 官方判例开放 API，注册免费。
- 🟢 **UK Parliament Open Data API** 🇬🇧 — 程序数据 + Hansard 辩论，免费（开放议会许可）。
- 🟢 **Bundestag Open Data** 🇩🇪 — 1949年至今全会记录与文件，免费 XML/JSON。
- 🟢 **Regulations.gov / Federal Register API** 🇺🇸 — 联邦规章/案卷/公众意见，免费。

---

## 2. 机器学习数据集与语料

> 🟢 本节几乎全部为免费/开放研究资源（部分含非商用许可，商用前请核对 License）。

### 2.1 数据抓取与处理工具（均 🟢 开源）
Juriscraper、Eyecite、LegalCrawler、Blackstone 🇬🇧、French Legal Case Anonymization 🇫🇷、ContextGem、Opennyai 🇮🇳、CiteURL、Open Australian Legal Corpus Creator 🇦🇺。

### 2.2 预训练语料与批量数据（均 🟢 免费/开放）
Pile of Law 🇺🇸 256GB、MultiLegalPile 🌍 689GB、LeXFiles 🌍 190亿token、Indian Kanoon Dataset 🇮🇳、JRC-Acquis 🇪🇺、EUR-Lex 🇪🇺、Open Australian Legal Corpus 🇦🇺、S2ORC（法律子集）、CourtListener Bulk Data 🇺🇸、RECAP Archive 🇺🇸、Caselaw Access Project 🇺🇸 690万、Oyez Audio 🇺🇸、WIPO Lex 🌍、SSRN/OpenAlex 🌍、HUPD 🇺🇸 450万+、IL-TUR 🇮🇳、gitlaw-jp 🇯🇵、open-source-legislation 🌍。

### 2.3 按任务划分的数据集（均 🟢 免费/开放，部分非商用）
- **判决预测（LJP）**：CAIL2018 🇨🇳、ECtHR、ILDC 🇮🇳、NyayaAnumana 🇮🇳、CaseSumm 🇺🇸、IndianBailJudgments-1200、Supreme Court Database 🇺🇸。
- **文本分类**：LexGLUE、LEDGAR、CUAD、AsyLex 🇨🇭。
- **法律问答**：CaseHOLD 🇺🇸、COLIEE 🇨🇦🇯🇵、JEC-QA 🇨🇳。
- **法律摘要**：BillSum、EUR-Lex Sum、Multi-LexSum、mteb/legal_summarization、IN-Abs/UK-Abs、Swiss SLDS 🇨🇭。
- **语义检索/IR**：opinions-synthetic-query-512、LexTREC、CLERC、MLEB、german_legal_sentences 🇩🇪、JurisTCU 🇧🇷。
- **合同分析**：CUAD、MAUD、ToS;DR、ContractNLI。

---

## 3. 法律 AI 模型与嵌入

### 3.1 大语言模型（LLM）
- 🟢 **SaulLM-7B / 54B / 141B**（MIT 开源权重）。
- 🟢 **Lawma-8B / 70B**、**InLegalBERT**（印度）、**Pasal.id**（印尼，开源）。
- 🟢 **NyayaSahayak**（印度，开源）。
- 🟢 **ChatLaw**（中文，CC BY-NC，非商用）、**DISC-LawLLM**（中文，Apache 2.0）。
- 🟢 **AdaptLLM/law-LLM、law-chat**、**InternLM-Law**（Apache 2.0）、**Lawyer-LLaMA**、**Fuzi.Mingcha**（均中文/英文开源）。
- 🟢 **Aalap-Mistral-7B**（Apache 2.0）、**llama3-8b-Lawyer**（MIT）、**SL-Llama-3.2-1b**（CUAD 微调）。

> 全部为开源权重，可本地部署/微调；自行托管的算力成本另计。

### 3.2 嵌入与 BERT 类模型
- 🟡 **voyage-law-2 / voyage-4**（Voyage AI，付费 API）。
- 🟡 **Kanon 2 Embedder**（MLEB 第1，付费 API）。
- 🟢 **Legal-BERT、CaseLawBERT、LegalBert (JHU)、EmuBERT、Lawformer**（开源权重）。
- 🟢 基准 **MLEB**（开源评测）。

### 3.3 多语种与区域模型
- 🟢 **OpenGPT-X / Teuken-7B**（欧洲，全24种欧盟语言，开源）。
- 🟢 **LawBench Models**（中国，开源评测）。

---

## 4. 法律 MCP 服务器

> 🟢 本节全部为开源/免费项目（连接的底层数据源本身可能另有免费档或付费，如 PACER、Clio）。

- **Vaquill AI MCP**（连 800万+美国判决 + US Code/CFR；底层 API 付费）。
- **CourtListener MCP**（DefendTheDisabled / Travis-Prall / khizar-anjum 三实现）。
- **agentic-ops/legal-mcp**（集成 Clio 等案管，需各自账号）。
- **LegalContext MCP**、**adeu（Word 修订红线引擎）**。
- ⭐ **Master Claude for Legal**（MIT，开源）— Claude 法律技能包：10份参考文档 + 5起步技能（NDA 分流/版本对比/会议简报/引文核验/状态综合）+ 3套律所模板。**最值得直接借鉴。**
- 各法域：Korean Law 🇰🇷、Yargı 🇹🇷、Taiwan Legal DB 🇹🇼、ayunis-legal 🇩🇪、Pasal 🇮🇩、auslaw 🇦🇺🇳🇿、law-scrapper 🇵🇱、Emilie 🇨🇭、Mahender22/legal-mcp 🇺🇸（含 PACER，PACER 付费）、EU Compliance MCP 🇪🇺、legifrance/droit-francais/French Law MCP 🇫🇷、SEC EDGAR MCP 🇺🇸、mcp-cerebra-legal-server。

---

## 5. 全栈法律 AI 平台

**🟡 商业 / AI 原生（均付费，多提供演示/试用）**
Harvey AI、Thomson Reuters（CoCounsel/Westlaw）、LexisNexis（Lexis+ AI）、Legora、Eudia、DeepJudge、Prest0、HODOS+CASEFLOW、Crosby、Manifest OS、Enter、Lexroom.ai、Vesence、Eve Legal、Supio、GC AI、Orbital。

**🟢 开源（免费 / 可自托管）**
- ⭐ **Suzie Law** — 可自托管的 Harvey 替代：12业务领域人格、160+智能体工作流、带引文文档问答、修订红线、DOCX 起草、19法域统一检索。
- **Mike** — 文档对话助手（BYOK，自带 API Key）。
- **Stella** — TypeScript 法律工作区。
- **CourtListener（源码）** — 最大美国法院数据开放档案的 Django 源码。
- **dd-agents** — 并购尽调多智能体平台（Apache 2.0）。

---

## 6. 法律检索平台

### 6.1 开放/免费综合
🟢 **WorldLII**、**CommonLII**、**GlobaLex (NYU)**。

### 6.2 按法域（官方/免费门户）
> 除特别标注外，以下官方门户均 🟢 免费。
- **美国 🇺🇸**：🔵 Vaquill AI（freemium）、🟢 CourtListener、🟡 PACER（按页计费）、🟢 Caselaw Access Project、🟢 GovInfo、🟢 eCFR、🟢 OpenStates、🟢 AI Laws by State、🟢 Google Scholar Case Law。
- **英国 🇬🇧**：🟢 BAILII、Find Case Law、legislation.gov.uk。
- **欧盟 🇪🇺**：🟢 EUR-Lex、CURIA、HUDOC、N-Lex、EU Publications Office。
- **德国 🇩🇪**：🟢 OpenJur、OpenLegalData、Gesetze im Internet。
- **法国 🇫🇷**：🟢 Legifrance、Judilibre。
- **印度 🇮🇳**：🟢 Indian Kanoon、India Code、Supreme Court of India、eCourts。
- **土耳其 🇹🇷**：🔵 Avukatistan。
- **中国 🇨🇳 / 日本 🇯🇵**：🟢 中国裁判文书网、国家法律法规数据库（NPC）、北大法律信息网、日本 e-Gov Law Search。
- **巴西 🇧🇷**：🟢 LexML Brasil、STF、CNJ Dados Abertos。
- **其他**：🟢 AustLII、CommonLII、WorldLII。

### 6.3 国际法院与法庭（🟢 均免费）
ICJ、ICC Case Law、WTO、Inter-American Court、ITLOS、PCA、ICSID、African Court。

### 6.4 各大洲官方门户（🟢 均免费，节选）
拉美：Ley Chile 🇨🇱、SUIN-Juriscol 🇨🇴、SPIJ 🇵🇪、IMPO 🇺🇾。中东：BOE 🇸🇦、UAE Legislations 🇦🇪、Al-Meezan 🇶🇦、Knesset 🇮🇱、Manshurat 🇪🇬、SGG 🇲🇦。东南亚：Singapore Statutes Online 🇸🇬、AGC Malaysia 🇲🇾、Ratchakitcha 🇹🇭、VBPL 🇻🇳、Philippines SC E-Library 🇵🇭。东亚：HK e-Legislation 🇭🇰、NPC 🇨🇳。东欧/北欧/大洋洲等亦有官方免费门户（详见原仓库折叠区）。
> 例外：挪威 **Lovdata** 🔵（基础免费 + Pro 付费档）。

### 6.5 AI 研究工具
- 🟢 **开源**：LawGlance、OLAW（哈佛）、Justicio 🇪🇸、Lex (i.AI) 🇬🇧、GraphRAG Legal Cases、legal-tech-chat。
- 🟡 **商业（付费）**：Vaquill AI（🔵 含免费档）、Leya、Paxton AI、EvenUp、Lexlegis.AI 🇮🇳、HAQQ、Blue J、Bloomberg Law、vLex/Vincent AI、Casetext/CoCounsel、Lex Machina、Docket Alarm、Manupatra 🇮🇳。

---

## 7. 文书自动化与起草

- 🟢 **Docassemble**（开源，引导式访谈/文档装配金标准）。
- 🟢 **Suffolk LIT Lab Assembly Line**（开源）。
- 🟢 **open-agreements / CommonAccord**（开源）。
- 🟢 **adeu**（开源，Word 修订红线）。
- 🟢 **Accord Project Template Archive**（开源，智能法律合同模板）。
- 🟡 **Spellbook**、**Clearbrief**、**HotDocs**、**ContractExpress**、**Litera**、**Gavel**（均付费/商业）。

---

## 8. 知识产权与专利技术

> 🟡 本节全部为付费/商业平台。
PatSnap、Anaqua、AltLegal、Trademarkia（🔵 商标检索有免费查询）、Solve Intelligence、DeepIP、Ankar、Patlytics。

---

## 9. 合同全生命周期管理（CLM）

- 🟡 **付费/商业**：Ironclad、Icertis、ContractPodAi(Leah)、DocuSign CLM、Robin AI、Luminance、LexCheck、Lexion、Legartis、LawGeex、Juro、Avvoka、Ivo、SpotDraft。
- 🟢 **开源/免费**：Wraft、contract-review-agent（本地优先）、legal-redline-tools。

---

## 10. 公证与电子签名

- 🟡 **DocuSign**（付费，全球电子签标准）。
- 🟡 **Proof（原 Notarize）**（付费，远程在线公证 RON）。
- 🟢 **OpenSign**（开源，免费 DocuSign 替代，6.3k+ stars）。

---

## 11. 电子取证与文档审阅

- 🟡 **付费/商业**：Relativity、Everlaw、Nuix、Reveal AI、Exterro、Logikcull、IPRO。
- 🟢 **开源**：FreeEed（AI 跨平台取证，含 OCR）。

---

## 12. 案件管理与法律运营

- 🟡 **付费/商业**：Clio（含 Clio Duo AI）、Litera、NetDocuments、Filevine、Mitratech、MyCase、Smokeball、CosmoLex、Darrow、Legalyze.ai、Theo AI、Briefpoint、Bridge Legal、Pattern Data、Steno、Veritext、Qualia、Doma。
- 🟢 **开源**：ClinicCases（法学院诊所）、ArkCase（政府/法律）、J-Lawyer（德国）、Elint AI（区块链案管）。
- 注：Burford Capital、Omni Bridgeway 为诉讼融资机构（非软件采购）。

---

## 13. 电子计费与法律支出管理

> 🟡 全部为付费/商业：Brightflag、SimpleLegal、CounselLink。

---

## 14. 面向消费者的法律服务（B2C）

> 多为 🔵 Freemium 或 🟡 付费（按文书/订阅计费）。
LegalZoom、Rocket Lawyer、HelloPrenup、DoNotPay（🟡 订阅）、Klaro Legal、JustiGuide、Boundless、Visalaw.ai、Docketwise、Hello Divorce、Trust & Will、Wealth.com、SoloSuit。

---

## 15. 合规与 RegTech

- 🟡 **付费/商业**：Drata、Vanta、ComplyAdvantage、Corlytics/Clausematch、Certa、OneTrust、NAVEX、Kira Systems、Sphere、Persefoni。
- 🟢 **免费/学术**：Climate Case Chart（2600+全球气候诉讼案例库）。

---

## 16. 在线纠纷解决（ODR）

- 🟡 **TylerTech E-Filing**、**Modria**（付费/政府采购）。
- 🟢 **Kleros**（区块链众包司法协议，开源协议；参与涉加密代币）。

---

## 17. 司法可及性与公益技术

> 🟢 全部为非营利/学术/政府，面向公众免费。
Free Law Project、Harvard CAP、Suffolk LIT Lab、A2J Author/CALI、Legal Services Corporation、ProBono.net、Upsolve、JustFix、AsylumConnect、EFF、ABA Free Legal Answers、Recidiviz、Clear My Record、World Justice Project、HiiL。

---

## 18. 奠基性研究论文

> 🟢 论文均可在 arXiv/SSRN/ACL 免费获取；🟡 仅 Ashley 教材为付费出版书。
- 🟢 LEGAL-BERT（2020）、LexGLUE（2022）、LegalBench（2023）、GPT-4 Passes the Bar Exam（2023）、SaulLM-7B（2024）、MultiLegalPile（2024）、Large Legal Fictions: Profiling Legal Hallucinations（2024，幻觉率 69–88%，必读）。
- 🟡 Artificial Intelligence and Legal Analytics（2017，Kevin Ashley，剑桥出版教材）。

---

## 速查小结：自研系统可优先白嫖的「免费/开源」组合

- **数据底座（🟢 全免费）**：CourtListener / Caselaw Access / EUR-Lex / Legifrance / Indian Kanoon / 中国裁判文书网 + NPC 数据库；批量语料用 Pile of Law、MultiLegalPile。
- **模型（🟢 开源权重）**：SaulLM（MIT）、DISC-LawLLM / InternLM-Law（Apache 2.0，中文）、Legal-BERT 系列嵌入；如需更强检索嵌入再考虑 🟡 voyage-law-2 / Kanon 2。
- **MCP / 工程脚手架（🟢）**：Master Claude for Legal（技能包）、Suzie Law（自托管全栈）、CourtListener MCP、adeu（Word 红线）。
- **文书自动化（🟢）**：Docassemble + Suffolk Assembly Line + Accord Project。
- **需付费的环节**：高质量嵌入 API、商业全栈平台（Harvey/CoCounsel/Lexis+）、企业 CLM、电子签（DocuSign）、电子取证、案管（Clio）——可按预算逐步替换开源方案。

---

*定价标注基于仓库描述与公开信息，可能随时间变化；采购前以各产品官网为准。各国免费判例门户原仓库以折叠列表逐国罗列（200+法域），如需某法域完整链接可单独提取。*

---

## 附录 A：`claude-for-legal` 与 `Master Claude for Legal` 的区别，及本地化改造说明

> 背景：项目已从 GitHub 下载「Claude for Legal」，计划改造成**本地部署模型版 + 中国法律化**版本。本节澄清两个同名易混仓库的区别，并说明改造思路。

### A.1 两者是不同的两个仓库、不同作者

**`anthropics/claude-for-legal`（官方，项目已下载的这个）**
Anthropic 官方出品（约 7.6k stars），是一个**按业务领域划分的插件市场（plugin marketplace）**。包含 commercial / corporate / employment / ip / litigation / privacy / product / regulatory / ai-governance 等垂直插件，外加 law-student、legal-clinic、legal-builder-hub（技能安全审查/信任层）、managed-agent-cookbooks（定时智能体）、以及外部厂商插件 cocounsel-legal（Thomson Reuters）。每个插件 = 技能（slash 命令）+ 定时 agent + 实务画像（`CLAUDE.md` 冷启动访谈）+ MCP 连接器。覆盖面大、结构完整、持续维护。

**`sboghossian/master-claude-for-legal`（第三方，MIT，HAQQ Legal AI 维护）**
从 Anthropic 两场 2026 法律 webinar + HAQQ 落地经验提炼的**精简技能包/学习资料**：10 份参考文档（职业特权 privilege、核验、长文档、业务领域）、5 个起步技能（NDA 分流、版本对比、会议简报、引文核验、状态综合）、3 套律所模板，外加一份 51 题评测数据集。体量小、偏「上手教程 + 最佳实践」。同作者还有更小的 `mini-claude-for-legal`。

> 一句话：**官方的是「全套垂直插件框架」，Master 是「一份提炼好的入门技能包 + 评测集」。** 以官方版为主干，Master 当参考资料读——尤其它的 privilege/核验参考文档和 51 题评测集，是做中国法律评测集的现成模板。

### A.2 重要提醒：两个仓库都没有「模型」也没有法律数据

它们本质是 **Markdown 写的技能/提示词 + 参考文档 + MCP 连接器配置**，运行时架在 Claude（API 模型）之上。因此改造是**两条独立的轴**，不要混为一谈：

**1. 本地部署模型（换底座）** — 难点在运行时，不在内容。Claude Code 的插件/slash 命令运行时绑定 Claude；换成本地开源模型（Qwen、DISC-LawLLM 等）有两条路：
- 保留技能里的**提示词/方法论内容**，移植到自有 Agent 框架去调本地模型（推荐，内容复用率高）；
- 或用一个 OpenAI 兼容网关把本地模型接进来。结论：技能的**文字内容能复用，运行时框架基本要重写**。

**2. 中国法律化（换内容）** — 工作量更大，因为插件深度内嵌英美法假设，需逐项替换：
- **引文核验规则**：美国判例/Bluebook 引用 → 中国法条/裁判文书引用规范；
- **业务技能 playbook**：合同审查按《民法典》合同编、劳动法、公司法重写；
- **连接器**：CourtListener / SEC EDGAR → 中国裁判文书网、北大法宝、国家法律法规数据库（NPC）的 MCP；
- **privilege/核验参考**：中国无英美「律师-当事人特权」同等制度，改写成保密义务/执业道德规范。

### A.3 建议改造路径

以官方 `claude-for-legal` 的插件架构为骨架 → 先只挑 1 个领域（如合同审查）做中国化垂直切片 → 用本地开源中文法律模型跑通 → 拿 Master 的评测集思路建一套中国法评测题 → 验证后再扩展其他领域。

**参考链接**
- [anthropics/claude-for-legal](https://github.com/anthropics/claude-for-legal)
- [sboghossian/master-claude-for-legal](https://github.com/sboghossian/master-claude-for-legal)

---

## 附录 B：`dd-agents` 与中国并购尽调适配

> 背景：评估开源并购尽调多智能体系统 `dd-agents` 是否可用于中国法下的并购业务。

### B.1 dd-agents 是什么

`due-diligence-agents`（PyPI 包名 `dd-agents`，作者 Zohar Babin，Apache 2.0）是一套**并购（M&A）尽职调查多智能体系统**。把整个数据室（data room，海量合同/财务/各类 PDF、Word、Excel）喂进去，**13 个 AI 智能体并行从 9 个专业域**审阅，自动**交叉引用**单一审阅人忽略的跨域关联，并把每条发现**溯源到具体页码、条款、原文引用**。

- **9 个领域专家**：法律、财务、商业、产品技术、网络安全、人力、税务、监管合规、ESG。
- **4 个编排/综合智能体**：Judge（对抗式质检）、Executive Synthesis（跨域定级 + Go/No-Go 结论）、Red Flag Scanner（快速红黄绿分级）、Acquirer Intelligence（对照买方投资逻辑）。
- 38 步流水线 + 5 道阻断式质量门 + 31 项 QA 校验；输出交互式 HTML 报告、14 页 Excel、逐条 JSON。
- 工程关键点：**本地执行、不回传数据、只读数据室**；**模型无关**（Anthropic / Bedrock / Vertex，也支持 GPT、Gemini、**DeepSeek**、本地模型走 Anthropic 兼容网关）；**智能体人格用 Markdown 编辑、改 focus_areas / 定级无需写代码**；支持 **100+ 语言多语种 OCR**。
- 明确定位「加速团队与顾问」，不替代律师/会计师做最终结论。

### B.2 能否用于中国法下的并购

**架构层面：很适配，可直接用。** 价值不依赖法域——「把一屋子合同跨域交叉核验并溯源到原文」中国并购同样痛。三个特性正好对上：模型可换 DeepSeek/本地中文法律模型，解决数据合规与成本；多语种 OCR 处理中文扫描件；智能体人格 Markdown 改写，无需碰 Python。

**内容层面：必须做实质性中国法本地化，不能开箱即用。** 现有法律/监管/税务/HR focus_areas 全为英美法 + 美国监管框架（change of control 五子类、隐私按 GDPR/CCPA、税务按 NOL/transfer pricing 等）。详见单独文件《dd-agents 中国法智能体改写清单》。

### B.3 落地建议

沿用其**流水线骨架 + 交叉引用 + 溯源 + 质量门**（最难自研的部分），把 9 个 `dd-config/agents/*.md` 人格文件按中国法重写，模型接 DeepSeek 或本地中文法律模型，先用 1–2 单真实交易脱敏数据室验证召回率与引用准确性。思路与附录 A 一致：**复用工程框架，替换法律内容**。

**参考链接**
- [zoharbabin/due-diligence-agents](https://github.com/zoharbabin/due-diligence-agents)
