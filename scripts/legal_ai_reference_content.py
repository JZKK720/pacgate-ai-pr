"""Content for the local-first legal AI stack reference.

Single source of truth for the bilingual (EN / ZH) reference document.
Every block carries its English and Chinese text side by side so the two
renders can never drift apart in structure, table count or ordering.

Facts in the tables were read from the running codebase (crate sources,
route table, workflow YAML, persona table, connector registry, redaction
policy) and from the shipped compose definition. Do not add a number that
was not read from one of those places.

`block` types
  h1 / h2 / h3      heading
  p                 paragraph
  quote             standfirst / callout
  bullets           list of (en, zh)
  figure            (file under docs/diagrams/svg, caption en, caption zh)
  table             headers, rows, widths, optional note
  pagebreak         page break in the DOCX render
"""

# Role names replace every product, vendor and internal service name.
BANNED_PATTERNS = [
    r"pacgate",
    r"deer[-_ ]?flow",
    r"(?<![a-z0-9])qm(?![a-z0-9])",
    r"openviking",
    r"volcengine",
    r"jzkk720",
    r"deermem",
    r"cubecloud",
]

TITLE_EN = "Local-First Legal AI Stack"
TITLE_ZH = "本地优先法律 AI 技术栈"
SUBTITLE_EN = "Semantics, interfaces and capabilities of the legal agent chain and its harness"
SUBTITLE_ZH = "法律智能体链路与执行框架的语义、接口与能力"
DOC_KIND_EN = "System reference"
DOC_KIND_ZH = "系统参考手册"

# The author and creator fields land in the PDF and DOCX metadata, so they are
# part of the redacted surface: a role name there, never a firm or vendor name.
AUTHOR = "Firm delivery engineering"
SUBJECT_EN = SUBTITLE_EN

BLOCKS = []
B = BLOCKS.append

# ── 1. Reader's note ─────────────────────────────────────────────────────────

B(("h1", "1. How to read this document", "1. 阅读说明"))

B((
    "quote",
    "This is a technical description of an on-premises legal AI system, written so that a reader who has never seen the product can follow how work moves through it. Names of the platform's own services, of the two upstream runtimes, and of their vendors have been replaced by the role names in Table 1. Nothing else has been softened: every count, port, limit and status statement below was read from the shipped source and deployment definition.",
    "本文面向上级审查与技术评估，说明一套部署在本地工作站上的法律 AI 系统如何承接并完成法律工作。平台自有的服务名、两个上游运行时及其厂商名，一律以表 1 的角色名替代。除此之外未作任何弱化处理：下文所有数量、端口、上限与状态，均取自实际交付的源码与部署定义，而非估算。",
))

B((
    "p",
    "Each table is organised on the same three axes, so a reader can compare one layer with another without relearning the layout.",
    "所有表格按同样的三条轴线组织，读者无须重新适应版式即可横向比较各层。",
))

B((
    "bullets",
    [
        (
            "Semantics: what the layer means in legal work. What it owns, what it must never do, and which decision it is accountable for.",
            "语义：该层在法律工作中的含义，它拥有什么、不得做什么、对哪一个决定负责。",
        ),
        (
            "Syntax: the concrete contract. Routes, tool names, argument shapes, size caps and status behaviour that the neighbouring layer actually calls.",
            "语法：具体契约。相邻层实际调用的路由、工具名、参数结构、体积上限与状态行为。",
        ),
        (
            "Capabilities: what a lawyer can then do that they could not do before, and where the system enforces the limit of that capability.",
            "能力：律师因此可以做到哪些此前做不到的事，以及系统在何处强制该能力的边界。",
        ),
    ],
))

B((
    "p",
    "The system is local-first in a precise sense, not a marketing one: documents, matter records, generated files and the vector index stay on the workstation; the only outbound traffic is what the firm explicitly enables. Section 9 states the one exception and the decision behind it.",
    "本系统所谓本地优先是精确意义上的：文档、事项记录、生成的文件与向量索引均留在工作站上，唯一的外联流量由律所自行开启。第 9 节说明唯一的例外及其决策依据。",
))

B(("table", {
    "widths": [0.20, 0.30, 0.24, 0.26],
    "headers": [
        ("Role name used here", "本文使用的角色名"),
        ("What it is in the running system", "在运行系统中的实际对应"),
        ("Owns", "拥有"),
        ("Never does", "绝不承担"),
    ],
    "rows": [
        [
            ("Ingress gateway", "接入网关"),
            ("The single published entry point. Terminates browser traffic on one port and routes by path.", "唯一对外发布的入口，在一个端口上接收浏览器流量并按路径转发。"),
            ("Routing, request size cap, request timeout", "路由、请求体积上限、请求超时"),
            ("No business logic, no storage", "不含业务逻辑，不做存储"),
        ],
        [
            ("Workspace frontend", "工作台前端"),
            ("Browser application for the research runtime, which also proxies that runtime's own API calls.", "研究运行时的浏览器应用，同时代理该运行时自身的接口调用。"),
            ("Rendering, session, same-origin admission", "页面渲染、会话、同源准入"),
            ("Holds no matter records", "不持有事项记录"),
        ],
        [
            ("Matter core service", "事项核心服务"),
            ("Headless HTTP service: matters, documents and versions, workflows, accounts, search, de-identification jobs.", "无界面的 HTTP 服务：事项、文档与版本、工作流、账号、检索、去标识任务。"),
            ("The record of what the firm has", "律所工作成果的权威记录"),
            ("No user interface", "不提供用户界面"),
        ],
        [
            ("Document engine", "文档引擎"),
            ("OOXML reader and writer inside the core service.", "核心服务内部的 OOXML 读写引擎。"),
            ("Versioned Word output, tracked edits", "带版本的 Word 输出、修订留痕"),
            ("Does not decide content", "不决定内容"),
        ],
        [
            ("Tool bridge", "工具桥接层"),
            ("MCP server that re-exposes core endpoints as agent-callable tools.", "以 MCP 服务器形式，把核心接口重新暴露为智能体可调用的工具。"),
            ("Tool schema, authentication to core", "工具模式、对核心服务的鉴权"),
            ("Holds no independent state", "不持有独立状态"),
        ],
        [
            ("Research runtime", "研究运行时"),
            ("Multi-stage pipeline: plan, retrieve, analyse, report.", "多阶段流水线：规划、检索、分析、成文。"),
            ("Long-running research runs", "长时运行的研究任务"),
            ("Does not own matter records", "不拥有事项记录"),
        ],
        [
            ("Collaboration runtime", "协作运行时"),
            ("Scope-isolated workspace for team co-working, with an ethical-wall model.", "按作用域隔离的团队协作工作台，具备利益冲突隔离模型。"),
            ("Channels, membership, per-scope egress policy", "频道、成员、按作用域的外联策略"),
            ("Brought up separately from the core stack", "独立于核心栈单独启动"),
        ],
        [
            ("Memory lane", "记忆通道"),
            ("Conversation-context database reached over MCP.", "经 MCP 访问的会话上下文数据库。"),
            ("Session summaries, decisions, preferences", "会话摘要、决定、偏好"),
            ("Is not a document store", "不是文档存储"),
        ],
        [
            ("Extraction service", "抽取服务"),
            ("Raster and layout text extraction for scans and image PDFs.", "针对扫描件与图像型 PDF 的版面文字抽取。"),
            ("OCR, table structure", "光学识别、表格结构"),
            ("Makes no classification decisions", "不做分级判断"),
        ],
        [
            ("Model host", "模型主机"),
            ("Local inference runtime using the workstation GPU or NPU.", "使用工作站 GPU 或 NPU 的本地推理运行时。"),
            ("Token generation, embeddings", "文本生成、向量化"),
            ("Persists no matter text", "不持久化事项文本"),
        ],
        [
            ("Case database", "案件数据库"),
            ("Relational store with vector and full-text indexes.", "具备向量索引与全文索引的关系型数据库。"),
            ("Matters, chunks, jobs, audit rows", "事项、文本块、任务、审计行"),
            ("Not reachable from a browser", "浏览器不可直达"),
        ],
        [
            ("Matter volume", "事项存储卷"),
            ("Per-tenant folder tree on local disk.", "本地磁盘上按租户划分的目录树。"),
            ("Uploads, generated documents, run outputs", "上传件、生成文档、运行产物"),
            ("Not inside any container image", "不包含在任何容器镜像内"),
        ],
    ],
    "note": (
        "Table 1. Role vocabulary. A reader can translate any later table back to a real deployment without learning product names.",
        "表 1 角色词表。读者可将后续任一表格还原到真实部署，而无需记住产品名称。",
    ),
}))

# ── 2. The chain in one view ─────────────────────────────────────────────────

B(("h1", "2. The chain in one view", "2. 链路全景"))

B((
    "p",
    "Work enters through one published port and leaves as a reviewed artefact. Between those two points there are five planes, and every plane has one job it cannot delegate: the access plane admits, the runtime plane reasons, the core plane records, the data plane persists, and the model plane generates. Figure 1 places them, and Table 2 explains what each plane can and cannot do.",
    "工作经由唯一发布端口进入，以经审阅的成果文件离开。中间有五个平面，每个平面都有一项不可委托的职责：接入面负责放行，运行时面负责推理，核心面负责记录，数据面负责留存，模型面负责生成。图 1 给出拓扑，表 2 说明各平面的能与不能。",
))

B(("figure", "stack-01-planes.png",
   "Figure 1. Plane map. Solid arrows are runtime calls; the core service is the only writer of matter records.",
   "图 1 平面拓扑。实线箭头为运行时调用；事项核心服务是事项记录的唯一写入方。"))

B(("table", {
    "widths": [0.14, 0.22, 0.34, 0.30],
    "headers": [
        ("Plane", "平面"),
        ("Semantics", "语义"),
        ("Syntax in practice", "实际语法"),
        ("Capability unlocked", "所解锁的能力"),
    ],
    "rows": [
        [
            ("Access", "接入面"),
            ("One door, one policy. Anything not published here is not reachable, including the database and the model host.", "单门禁、单策略。凡未在此发布的内容均不可达，包括数据库与模型主机。"),
            ("Published port 8089; path routing; 100 MB body limit; 3600 s read timeout; WebSocket and SSE upgrade", "对外端口 8089；按路径转发；请求体上限 100 MB；读超时 3600 秒；支持 WebSocket 与 SSE 升级"),
            ("A firm can hand a lawyer one address and no other configuration", "律所只需交付一个地址，律师无需其他配置"),
        ],
        [
            ("Runtime", "运行时面"),
            ("The reasoning surface. Two different work styles share one spine: open research, and bounded co-working.", "推理界面。两种不同的工作方式共享同一根脊梁：开放式研究，与有边界的协作。"),
            ("Research on 8001 behind a frontend on 3000; collaboration on its own port; both authenticated against core", "研究运行时位于 8001，前端位于 3000；协作运行时单独端口；两者均向核心服务鉴权"),
            ("Long multi-step runs, and scoped team sessions, without duplicating matter data", "长时多步任务与受控团队会话，均无需复制事项数据"),
        ],
        [
            (
                "Core",
                "核心面",
            ),
            (
                "The record. Every document, version, workflow run and de-identification job is written here and nowhere else.",
                "权威记录。每份文档、版本、工作流运行与去标识任务都只写在这里，不写在别处。",
            ),
            (
                "40 route declarations over 35 unique paths; bearer token plus per-matter scope; SSE streaming for chat",
                "35 条唯一路径、40 个路由声明；持有令牌加事项级作用域；对话支持 SSE 流式返回",
            ),
            (
                "One authoritative answer to what the firm has, which is what makes audit and handover possible",
                "对律所既有成果给出唯一权威答案，这是审计与交接得以成立的前提",
            ),
        ],
        [
            ("Data", "数据面"),
            ("Persistence split by kind, not by convenience: relational facts, vectors, files, conversation context.", "按性质而非按便利拆分持久化：关系事实、向量、文件、会话上下文。"),
            ("Database on 5432 with vector and full-text indexes; per-tenant folder tree on a mounted volume; memory lane on 1933 over MCP", "数据库位于 5432，具备向量与全文索引；按租户的目录树挂载在数据卷上；记忆通道位于 1933，经 MCP 访问"),
            ("Matter isolation that survives an upgrade, because data lives in volumes and never in images", "事项隔离可跨越升级而保持，因为数据存放于数据卷而非镜像"),
        ],
        [
            ("Model", "模型面"),
            ("Generation only. The model is a replaceable component behind a three-tier router, not a system the firm is locked into.", "仅负责生成。模型位于三层路由之后，是可替换组件，而非律所被绑定的系统。"),
            ("Local endpoint on 11434; Main, Mid and Low tiers; embeddings from a fixed local embedding model", "本地端点为 11434；分主、中、轻三档；向量化使用固定的本地嵌入模型"),
            ("Model choice becomes an operational decision the firm can revisit, not an architecture change", "模型选择成为律所可随时重议的运营决策，而非架构变更"),
        ],
    ],
    "note": (
        "Table 2. Plane reference. The access plane is the only plane a browser can reach.",
        "表 2 平面参考。接入面是浏览器唯一可达的平面。",
    ),
}))

# ── 3. Request lifecycle ─────────────────────────────────────────────────────

B(("h1", "3. What happens to one question", "3. 一个问题的完整路径"))

B((
    "p",
    "A single question touches every plane in a fixed order. The order is the design: recall happens before retrieval, retrieval happens before generation, and the write to the record happens last, after a human has had the chance to reject the output.",
    "一个问题的处理按固定顺序贯穿所有平面。顺序本身就是设计：先回忆再检索，先检索再生成，写入权威记录放在最后，且人类已有机会否决该输出。",
))

B(("figure", "stack-02-request-path.png",
   "Figure 2. One question. Numbered steps are the observed call order; dotted returns are what the next step receives.",
   "图 2 单个问题的处理路径。编号步骤为实测调用顺序；虚线返回为下一步实际收到的内容。"))

B(("table", {
    "widths": [0.08, 0.24, 0.34, 0.34],
    "headers": [
        ("Step", "步骤"),
        ("Who acts", "执行方"),
        ("State change", "状态变化"),
        ("Evidence left behind", "留下的证据"),
    ],
    "rows": [
        [
            ("1", "1"),
            ("Attorney names a matter and asks", "律师指定事项并提问"),
            ("Request bound to one matter identity; no cross-matter read is possible", "请求绑定到单一事项标识；跨事项读取不可能发生"),
            ("Session record with matter identifier", "带事项标识的会话记录"),
        ],
        [
            ("2", "2"),
            ("Ingress gateway", "接入网关"),
            ("Path decides the destination; size and timeout policy applied before any backend sees the request", "按路径决定去向；体积与超时策略在任何后端看到请求之前生效"),
            ("Gateway access log", "网关访问日志"),
        ],
        [
            ("3", "3"),
            ("Memory lane recall", "记忆通道回忆"),
            ("Prior summaries and decisions for this scope are loaded as context", "载入该作用域既往的摘要与决定作为上下文"),
            ("Recall call in the run trace", "运行轨迹中的回忆调用"),
        ],
        [
            ("4", "4"),
            ("Tool bridge", "工具桥接层"),
            ("Documents are listed and read through authenticated core calls; each tool call is bounded by the matter scope", "经鉴权的核心调用列举并读取文档；每次工具调用均受事项作用域约束"),
            ("Tool call and result pair", "工具调用与结果配对记录"),
        ],
        [
            ("5", "5"),
            ("Model host", "模型主机"),
            ("Grounded prompt assembled from retrieved passages; generation streams back token by token", "由检索到的段落组成有据可依的提示；生成结果逐词流式返回"),
            ("Tier used, token counts", "所用档位、令牌计数"),
        ],
        [
            ("6", "6"),
            ("Core service", "核心服务"),
            ("Citations are extracted from the answer and attached to the response object rather than left in prose", "引用从答案中抽取并附加到响应对象，而非仅停留在正文里"),
            ("Citation list on the response", "响应中的引用列表"),
        ],
        [
            ("7", "7"),
            ("Document engine", "文档引擎"),
            ("Any deliverable is written as a new version, never as an overwrite", "任何成果文件都写为新版本，绝不覆盖旧版"),
            ("Version row plus file on the matter volume", "版本记录，以及事项存储卷上的文件"),
        ],
        [
            ("8", "8"),
            ("Memory lane write", "记忆通道写入"),
            ("The outcome is summarised into the same scope, subject to the record size cap", "结果摘要写回同一作用域，受记录体积上限约束"),
            ("Memory record with scope key", "带作用域键的记忆记录"),
        ],
        [
            ("9", "9"),
            ("Human reviewer", "人工审阅"),
            ("Anything flagged by classification or verification waits here; nothing bypasses it for a flagged item", "凡被分级或校验标记的内容在此等待；被标记项无法绕行"),
            ("Approval or rejection in the review record", "审阅记录中的批准或退回"),
        ],
    ],
    "note": (
        "Table 3. Request lifecycle. Steps 3 to 8 are the harness contract; steps 1, 2 and 9 are what makes the contract safe.",
        "表 3 请求生命周期。第 3 至 8 步为执行框架契约；第 1、2、9 步是该契约得以安全的前提。",
    ),
}))

# ── 4. Capability surface ────────────────────────────────────────────────────

B(("h1", "4. Capability surface", "4. 能力面"))

B((
    "p",
    "The platform exposes capability through a fixed tool surface rather than through free-form prompting. That is what allows a capability to be described, bounded and tested. Table 4 lists the eleven tools the in-process agent loop dispatches, and Table 5 lists the twenty tools the bridge publishes to external runtimes.",
    "平台通过固定的工具面而非自由提示来暴露能力。正因如此，一项能力才可被描述、设界与测试。表 4 列出进程内智能体循环调度的十一项工具，表 5 列出桥接层对外部运行时发布的二十项工具。",
))

B(("table", {
    "widths": [0.20, 0.30, 0.22, 0.28],
    "headers": [
        ("Tool", "工具"),
        ("What it does", "作用"),
        ("Input shape", "入参结构"),
        ("Bound", "边界"),
    ],
    "rows": [
        [("read_document", "读取文档"), ("Reads one document, optionally a specific version; defaults to latest.", "读取单份文档，可指定版本；默认取最新版。"), ("document id, optional version", "文档标识、可选版本"), ("One matter scope", "单一事项作用域")],
        [("find_in_document", "文档内检索"), ("Finds passages inside one document with surrounding context.", "在单份文档内检索段落并返回上下文。"), ("document id, query", "文档标识、查询串"), ("One document", "单份文档")],
        [("fetch_documents", "批量取回"), ("Fetches several documents in one call to save round trips.", "一次调用取回多份文档以减少往返。"), ("list of document ids", "文档标识列表"), ("Capped by the caller", "由调用方限制数量")],
        [("list_documents", "列举文档"), ("Lists the documents attached to a matter.", "列举某事项下的文档。"), ("matter id", "事项标识"), ("One matter", "单一事项")],
        [("generate_docx", "生成文档"), ("Writes a structured Word document from a declared structure.", "依据声明的结构生成 Word 文档。"), ("matter id, filename, structure", "事项标识、文件名、结构"), ("Always a new version", "始终为新版本")],
        [("edit_document", "修订文档"), ("Replaces text with anchoring context required on both sides.", "替换文本，并要求前后文锚点同时匹配。"), ("document id, find, replace, before, after", "文档标识、查找串、替换串、前文、后文"), ("Refuses an ambiguous anchor", "锚点有歧义即拒绝")],
        [("replicate_document", "复制文档"), ("Produces copies of an existing document for batch issuance.", "为批量出具而复制既有文档。"), ("document id, count 1 to 20", "文档标识、数量 1 至 20"), ("Hard ceiling of 20", "上限 20")],
        [("read_workflow", "读取工作流"), ("Returns a template's steps and the tool each step uses.", "返回模板的步骤及每步所用工具。"), ("workflow id", "工作流标识"), ("Read-only", "只读")],
        [("read_table_cells", "读取表格单元"), ("Extracts named columns from several documents for comparison.", "从多份文档中抽取指定列以便对照。"), ("matter id, document ids, columns", "事项标识、文档标识、列名"), ("One matter", "单一事项")],
        [("kb_search", "知识库检索"), ("Searches the internal corpus with class, jurisdiction and matter filters.", "按密级、法域与事项过滤内部语料检索。"), ("matter id, query, top k", "事项标识、查询串、返回条数"), ("Ceiling applies", "受密级上限约束")],
        [("legal_search", "外部法律检索"), ("Queries external legal databases through the connector router.", "经连接器路由查询外部法律数据库。"), ("query, jurisdiction, doc type, limit, connector", "查询串、法域、文档类型、数量、连接器"), ("Per-connector credentials", "需逐连接器凭据")],
    ],
    "note": (
        "Table 4. In-process tool surface. Eleven tools, each with a declared argument schema rather than a free-form command.",
        "表 4 进程内工具面。共十一项工具，各有声明式参数模式，而非自由命令。",
    ),
}))

B(("table", {
    "widths": [0.30, 0.40, 0.30],
    "headers": [
        ("Bridge tool group", "桥接工具组"),
        ("Tools", "工具"),
        ("Why it exists", "存在理由"),
    ],
    "rows": [
        [("Knowledge and search", "知识与检索"), ("knowledge-base search; connector search; list connectors", "知识库检索；连接器检索；列举连接器"), ("Keeps retrieval policy inside the core service instead of in each runtime", "把检索策略留在核心服务内，而非分散到各运行时")],
        [("Matters", "事项"), ("list matters; read memory; write memory; get workspace", "列举事项；读取记忆；写入记忆；获取工作区"), ("Gives a runtime a matter view without direct database access", "让运行时获得事项视图而无需直连数据库")],
        [("Documents", "文档"), ("list documents; read document; upload document; convert document", "列举文档；读取文档；上传文档；格式转换"), ("Makes the core service the only writer of documents", "使核心服务成为文档的唯一写入方")],
        [("Extraction", "抽取"), ("OCR document; OCR batch", "单件识别；批量识别"), ("Routes scans to the extraction service behind one call", "以单一调用把扫描件导向抽取服务")],
        [("De-identification", "去标识"), ("sanitize document; verify sanitized; sanitize text", "文档去标识；校验去标识结果；文本去标识"), ("Makes the review gate reachable from an agent run, not only from a UI", "使审阅闸门可由智能体运行触发，而非仅限于界面操作")],
        [("Workflows", "工作流"), ("list workflows; get workflow; execute workflow", "列举工作流；获取工作流；执行工作流"), ("Lets a runtime run a curated legal procedure instead of improvising", "让运行时执行既有法律程序，而非临场发挥")],
        [("Accounts and health", "账号与健康"), ("Authenticated calls carry a bearer token minted by the core service", "经鉴权调用均携带由核心服务签发的持有令牌"), ("Removes shared long-lived secrets from runtime configuration", "避免在运行时配置中存放共享的长效密钥")],
    ],
    "note": (
        "Table 5. Bridge surface. Twenty published tools grouped by the question they answer.",
        "表 5 桥接面。共发布二十项工具，按其回答的问题分组。",
    ),
}))

B(("table", {
    "widths": [0.22, 0.14, 0.34, 0.30],
    "headers": [
        ("Route group", "路由分组"),
        ("Declarations", "声明数"),
        ("What a caller can do", "调用方可完成的操作"),
        ("Authentication", "鉴权"),
    ],
    "rows": [
        [("documents", "文档"), ("11", "11"), ("Upload, read, download, version, edit, extract, de-identify, restore, accept", "上传、读取、下载、版本、编辑、抽取、去标识、还原、接受"), ("Bearer, matter scope", "持有令牌，事项作用域")],
        [("matters", "事项"), ("9", "9"), ("Create, list, read, patch identity, delete, memory, document list, workspace", "创建、列举、读取、修订标识、删除、记忆、文档列表、工作区"), ("Bearer, matter scope", "持有令牌，事项作用域")],
        [("workflows", "工作流"), ("4", "4"), ("List, list categories, read one, execute", "列举、列举分类、读取单个、执行"), ("Bearer", "持有令牌")],
        [("auth", "账号"), ("4", "4"), ("Log in, register under a closed gate, create a user as admin, read self", "登录、在关闭的注册闸门下注册、管理员建号、读取自身"), ("Mostly bearer", "多数需持有令牌")],
        [("search", "检索"), ("4", "4"), ("Keyword search, connector list, health, registry", "关键词检索、连接器列表、健康检查、注册表"), ("Bearer", "持有令牌")],
        [("chat", "对话"), ("2", "2"), ("Answer once, or stream with server-sent events", "一次返回，或以服务端事件流式返回"), ("Bearer, soul overlay", "持有令牌，叠加角色")],
        [("tabular", "表格审阅"), ("2", "2"), ("Declared, but the engine is not yet wired and answers with an explicit internal error", "路由已声明，但引擎尚未接入，返回明确的内部错误"), ("Bearer", "持有令牌")],
        [("knowledge base and due diligence profiles", "知识库与尽调画像"), ("2", "2"), ("Internal corpus search; list the nine due-diligence agent profiles", "内部语料检索；列举九个尽调智能体画像"), ("Bearer", "持有令牌")],
        [("health and build info", "健康与构建信息"), ("2", "2"), ("Liveness, and the release actually running", "存活探针，以及实际运行的版本"), ("Public by design", "有意公开")],
    ],
    "note": (
        "Table 6. Route groups. Declarations total 40 over 35 unique paths; a path carrying two verbs counts twice.",
        "表 6 路由分组。35 条唯一路径上共 40 个路由声明；同一路径支持两种方法时计作两次。",
    ),
}))

# ── 5. Harness semantics ────────────────────────────────────────────────────

B(("h1", "5. The harness: how a run is constrained", "5. 执行框架：一次运行如何被约束"))

B((
    "p",
    "A harness is the part of an agent system that decides what the agent is allowed to attempt. Here it has three layers, and each layer answers a different question. The role overlay answers who is speaking. The workflow template answers what procedure is being followed. The tool boundary answers what may be touched. None of the three is a prompt suggestion; all three are enforced in code that the model cannot argue with.",
    "执行框架指智能体系统中决定其可尝试范围的部分。此处分三层，各回答不同问题：角色叠加回答“谁在说话”，工作流模板回答“遵循何种程序”，工具边界回答“可触及何物”。三者皆非提示层面的建议，而是模型无法争辩的代码约束。",
))

B(("table", {
    "widths": [0.12, 0.24, 0.34, 0.30],
    "headers": [
        ("Layer", "层次"),
        ("Question it answers", "所回答的问题"),
        ("Mechanism", "机制"),
        ("Why it is code, not prompt", "为何落在代码而非提示"),
    ],
    "rows": [
        [
            ("Role overlay", "角色叠加"),
            ("Whose judgement is being represented, and with what standing authority", "代表谁的判断，以及其固有权限"),
            ("10 identity overlays bound to a user record. Each carries 2 to 3 identity modes switched by document type, and explicit boundary rules each tied to an enforcement point: API middleware, workflow gate, or prompt", "10 个身份叠加，绑定到用户记录。每个含 2 至 3 种按文档类型切换的身份模式，以及逐条绑定强制点的边界规则：接口中间件、工作流闸门或提示层"),
            ("A rule enforced only by prompting is a rule the model can be talked out of. Boundary rules are therefore split by enforcement point, and the platform reports per rule whether a check actually ran: a gate with no implementation is reported as not implemented rather than assumed to hold", "仅靠提示执行的规则，模型可以被说服放弃。因此边界规则按强制点分流，平台逐条报告检查是否真的执行：尚未实现的闸门会如实报告为未实现，而非假定其成立"),
        ],
        [
            ("Workflow template", "工作流模板"),
            ("What procedure this task follows, in what order, with which evidence at each step", "本任务遵循何种程序、何种顺序、每步需要何种依据"),
            ("220 templates across 15 files and 46 categories. Each template is an ordered list of steps; each step names one tool from Table 4 and its parameters", "15 个文件、46 个分类、共 220 个模板。每个模板是有序的步骤列表；每步指定表 4 中的一项工具及其参数"),
            ("A template is a data structure the executor walks. It cannot skip a step because the model felt confident, and step order is reproducible across runs", "模板是执行器逐步遍历的数据结构。它不会因模型自信而跳步，且步骤顺序在不同运行间可复现"),
        ],
        [
            ("Tool boundary", "工具边界"),
            ("What this run may actually touch, and how much of it", "本次运行实际可触及何物，以及数量上限"),
            ("Eleven dispatchable tools with declared schemas. Hard caps where volume matters: 20 copies per replication call, 64 KiB per memory record, 50 MB per upload", "十一项可调度工具，均带声明式模式。涉量处设硬上限：单次复制 20 份、单条记忆 64 KiB、单次上传 50 MB"),
            ("Schema plus scope means the blast radius of a bad run is bounded before it starts, not observed afterwards", "模式加作用域，使一次异常运行的影响半径在开始前即被限定，而非事后才发现"),
        ],
    ],
    "note": (
        "Table 7. Three harness layers. The layer that answers 'who' is the one regulated firms usually lack.",
        "表 7 执行框架三层。回答“谁在说话”的这一层，恰恰是受监管机构通常缺失的",
    ),
}))

B((
    "p",
    "The template library is worth reading as a statement about scope rather than as a feature count. It is a curated set of procedures a firm already performs, written down as ordered tool calls. The largest categories are litigation, then matter archive and collection, then corporate governance, capital markets, data, AI and trade compliance, fund compliance, and family matters. That distribution is the honest footprint of what has been modelled; it is not a claim that every legal task is covered.",
    "模板库更应被理解为范围声明，而非功能计数：它是律所本已执行的程序的可执行化写法。占比最大的类别依次为诉讼、案件归档与收集、公司治理、资本市场、数据、人工智能与贸易合规、基金合规、家事。这一分布如实反映已建模的边界，并不意味所有法律任务均已覆盖。",
))

B(("table", {
    "widths": [0.34, 0.16, 0.50],
    "headers": [
        ("Model tier", "模型档位"),
        ("Role", "定位"),
        ("What it is used for, and what happens when a tier is mis-sized", "用途，以及档位与硬件不匹配时的后果"),
    ],
    "rows": [
        [("Main", "主档"), ("Deep analysis", "深度分析"), ("Contract review and complex reasoning. The default tier for workflow execution", "合同审阅与复杂推理。工作流执行的默认档位")],
        [("Mid", "中档"), ("Structured output", "结构化输出"), ("Tabular review and batch extraction. Deliberately points at a smaller model than the hardware ceiling", "表格审阅与批量抽取。有意选择小于硬件上限的模型")],
        [("Low", "轻档"), ("Cheap labelling", "低成本标注"), ("Title generation and short summaries, where latency matters more than depth", "标题生成与短摘要，延迟比深度更重要")],
        [("Embedding", "向量化"), ("Retrieval", "检索"), ("A single fixed local embedding model with no alternative: changing it would invalidate the vector index, so the constraint is architectural", "固定使用本地嵌入模型且无替代：更换会使既有向量索引失效，故该约束属架构层面")],
    ],
    "note": (
        "Table 8. Tier semantics. An oversized model does not fail loudly on this class of hardware; it spills and appears to hang, which is why the Mid tier is capped below the card's nominal capacity.",
        "表 8 档位语义。在此类硬件上，过大的模型不会明确报错，而是溢出并表现为卡死；这正是中档被限制在显卡标称容量以下的原因。",
    ),
}))

B((
    "quote",
    "Practical consequence: model choice is an operational setting the firm can revisit, not an architecture decision that requires an upgrade project. That is the practical meaning of 'replaceable behind the router'.",
    "实务结论：模型选择是律所可随时重议的运营设置，而非需要立项升级的架构决策。这就是“路由之后可替换”的实际含义。",
))

# ── 6. Document gate ────────────────────────────────────────────────────────

B(("pagebreak", None, None))
B(("h1", "6. The document gate", "6. 文档闸门"))

B((
    "p",
    "Legal work is not only question answering. The distinguishing requirement is that a document leaves the building in a state the firm can defend. That produces one specific obligation no general chatbot carries: before client text reaches a model, it must be de-identified, and the de-identification must be verifiable rather than asserted.",
    "法律工作不止于问答。其特有条件在于：文档必须以律所可自证的状态离开机构。由此产生通用聊天机器人不承担的一项义务：客户文本在进入模型之前必须去标识，且该去标识须可验证，而非自我声明。",
))

B(("figure", "stack-03-document-gate.png",
   "Figure 3. Document gate. Four phases; the human gate in phase 3 is the only path to release for flagged items.",
   "图 3 文档闸门。共四个阶段；第三阶段的人工闸门是标记项获准放行的唯一路径。"))

B(("table", {
    "widths": [0.16, 0.30, 0.30, 0.24],
    "headers": [
        ("Phase", "阶段"),
        ("What is decided", "所做决定"),
        ("How it is decided", "决定方式"),
        ("Failure behaviour", "失败时的行为"),
    ],
    "rows": [
        [("Ingest", "摄取"), ("Whether the text is machine-readable, and whether a scan needs recognition", "文本是否机读，扫描件是否需要识别"), ("Native extraction first; raster recognition only as fallback, so a text PDF is never degraded by OCR", "优先原生抽取；仅在必要时回退到图像识别，故文本型 PDF 不会因识别而劣化"), ("An empty extraction fails loudly rather than yielding an empty document", "抽取为空时明确失败，而非产出空文档")],
        [("Detect", "识别"), ("Which spans are identifiers, and at which sensitivity tier", "哪些片段属于标识信息，以及处于哪个敏感层级"), ("19 entity types in four reporting tiers. Tier 1 is checksum-backed, so a miss there is a defect rather than a tuning choice", "四个上报层级、19 类实体。第一层由校验位支撑，故漏检属缺陷而非调优取舍"), ("Every tier is reported separately; recall is never blended into one number", "各层分别上报，召回率从不合并为单一数字")],
        [("Decide", "判定"), ("Whether this data class may pass automatically", "该数据分级是否可自动放行"), ("T1 and T2 may auto-pass on a clean verification. T3 and T4 never auto-pass, whatever the verification says", "T1、T2 在校验干净时可自动放行；T3、T4 无论校验结果如何都不自动放行"), ("A refusal is recorded as a verdict plus a review requirement, not as an error, so the evidence trail survives", "拒绝以“裁定加复核要求”的形式记录，而非报错，从而保留证据链")],
        [("Replace", "替换"), ("What placeholder stands for the original, and whether it stays stable", "以何占位符替代原文，以及其是否保持稳定"), ("Job-scoped placeholder names with a per-job token, one allocator held across the whole job, and keying on the exact original string", "占位符名带任务级令牌，整个任务共用同一分配器，并以原文精确字符串为键"), ("Two near-identical names stay distinct, so a redaction can never merge two real parties into one", "近似但不相同的名称保持区分，去标识绝不会把两个真实主体并为一个")],
        [("Verify", "校验"), ("Whether residue remains after replacement", "替换后是否残留"), ("The same detector set is replayed over the output. Verification is a replay, not a second opinion from a model", "以同一组识别器复跑输出。校验是复跑，而非向模型征求第二个意见"), ("Residue blocks release and routes the item to review", "残留即阻断放行并转入人工复核")],
    ],
    "note": (
        "Table 9. Gate phases. The order is contractual: detect precedes replace, and no model is consulted at any phase.",
        "表 9 闸门阶段。顺序具有契约性质：识别先于替换，且任一阶段均不咨询模型。",
    ),
}))

B((
    "p",
    "Two properties of this design are easy to miss and matter commercially. First, the mapping from placeholder to original is sealed with the job and stored as a ledger, which is what allows a document to be restored after review; without it, de-identification would be destructive. Second, the reviewer sees the verification result, not only the text, so approval is an informed act on record rather than a click.",
    "该设计有两点易被忽略但具商业意义。其一，占位符到原文的映射随任务封存为台账，这使文档在审阅后可还原；若无此机制，去标识将是破坏性的。其二，审阅者看到的不只是文本，还有校验结果，故批准成为有据可查的知情行为，而非一次点击。",
))

# ── 7. Data ceiling ─────────────────────────────────────────────────────────

B(("h1", "7. Data class as the retrieval ceiling", "7. 数据分级即检索上限"))

B((
    "p",
    "Classification is not a label attached for reporting. It is the ceiling on what a query may retrieve. A query declares a maximum class, and the retriever returns only chunks at or below that class. This is the mechanism that prevents a template-level search from surfacing a client's live matter file.",
    "分级不是为报表附上的标签，而是检索的上限。查询声明最高密级，检索器仅返回该密级及以下的文本块。这一机制正是防止模板级检索捞到客户在办案件文件的关键。",
))

B(("figure", "stack-04-data-ceiling.png",
   "Figure 4. Class ceiling. A query at a lower ceiling accumulates every higher class; a query at T4 is the only one that reaches T4.",
   "图 4 密级上限。上限较低的查询会累积更高密级的内容；只有 T4 查询才触及 T4。"))

B(("table", {
    "widths": [0.12, 0.26, 0.24, 0.38],
    "headers": [
        ("Class", "密级"),
        ("Meaning", "含义"),
        ("Visible to a query at", "对何种查询可见"),
        ("Release rule", "放行规则"),
    ],
    "rows": [
        [("T1", "T1"), ("Shared templates and standard texts with no client identity", "不含客户身份信息的共享模板与标准文本"), ("T1 and above", "T1 及以上"), ("May auto-pass when verification is clean", "校验干净时可自动放行")],
        [("T2", "T2"), ("Completed deliverables that still carry client context", "仍含客户上下文的已完成交付成果"), ("T2 and above", "T2 及以上"), ("May auto-pass when verification is clean", "校验干净时可自动放行")],
        [("T3", "T3"), ("Active matter files, scoped to one matter", "在办案件文件，限定于单一事项"), ("T3 and above", "T3 及以上"), ("Never auto-released; human approval required", "从不自动放行；须人工批准")],
        [("T4", "T4"), ("Special sensitive material under strict isolation", "受严格隔离的特别敏感资料"), ("T4 only", "仅 T4 查询"), ("Never auto-released, even on a clean verification", "即使校验干净也不自动放行")],
    ],
    "note": (
        "Table 10. Class ceiling. Default ingest lands at T2 when no class is declared, so the safe direction is the default rather than the caller's memory.",
        "表 10 密级上限。未声明密级时，入库默认落在 T2，故安全方向由默认值保证，而非依赖调用方记性。",
    ),
}))

B((
    "p",
    "Three further filters stack on the class ceiling, and each closes a distinct way a wrong document could appear in a correct answer. Jurisdiction filtering keeps a question asked under one legal order from being answered with another's authority. Matter filtering keeps two clients' files apart even when their class is identical. Source-level filtering distinguishes primary law from commentary, so a citation can be weighted by what kind of thing it is.",
    "在密级上限之上还叠加三重过滤，各自封堵一种“错误文档出现在正确回答中”的路径。法域过滤防止在一法域下提出的问题被另一法域的权威所回答；事项过滤使密级相同但客户不同的文件彼此隔绝；来源层级过滤区分一手法律与评述，使引用可按文献性质加权。",
))

# ── 8. Boundaries and ownership ─────────────────────────────────────────────

B(("h1", "8. Where the boundary sits", "8. 边界所在"))

B((
    "p",
    "The ownership split is the commercial core of the arrangement, so it is stated as a table rather than as prose. A firm buying this needs to know, in the same sentence, what they own and what they depend on.",
    "权属划分是本安排的核心商业条款，故以表格而非段落陈述。采购方需要在同一句话中同时知道：自己拥有什么，依赖什么。",
))

B(("table", {
    "widths": [0.18, 0.28, 0.28, 0.26],
    "headers": [
        ("Asset", "资产"),
        ("Who owns it", "权属方"),
        ("Where it lives", "存放位置"),
        ("What happens on upgrade", "升级时的处理"),
    ],
    "rows": [
        [("Matter records and uploads", "事项记录与上传件"), ("The firm, without qualification", "无条件归属律所"), ("Per-tenant folder tree on a local volume", "本地数据卷上按租户划分的目录树"), ("Preserved; never inside an image", "保留；从不在镜像内")],
        [("Generated documents", "生成的文档"), ("The firm", "律所"), ("Same volume, as versioned files with version rows in the database", "同一数据卷，以带版本号的文件存储，数据库内有对应版本行"), ("Preserved; a new version is appended, never an overwrite", "保留；以新版本追加，绝不覆盖")],
        [("Case database", "案件数据库"), ("The firm", "律所"), ("Named database volume", "具名数据库卷"), ("Preserved across container recreation", "容器重建后保留")],
        [("Vector index", "向量索引"), ("The firm", "律所"), ("Inside the database, tied to one embedding model", "位于数据库内，绑定单一嵌入模型"), ("Preserved, but pinned to that embedding model", "保留，但绑定于该嵌入模型")],
        [("Conversation memory", "会话记忆"), ("The firm", "律所"), ("Separate local volume", "独立的本地数据卷"), ("Preserved", "保留")],
        [("Platform code and images", "平台代码与镜像"), ("The vendor", "供应方"), ("Container images pulled from a registry at install and update", "安装与更新时自镜像仓库拉取"), ("New versions replace old ones; firm data is untouched", "新版本替换旧版本；律所数据不受影响")],
        [("Upstream runtime code", "上游运行时代码"), ("Third-party projects under their own licences", "第三方项目，按其各自许可"), ("Unmodified base, never forked", "以未修改的基础镜像使用，从不分支"), ("A base bump is a one-line change, not a merge", "升级基础镜像为一行改动，而非一次合并")],
        [("Firm-specific configuration", "律所专属配置"), ("The firm", "律所"), ("Local configuration and credential files", "本地配置文件与凭据文件"), ("Read by the new version; kept", "由新版本读取；予以保留")],
    ],
    "note": (
        "Table 11. Ownership. The row that matters most in a first meeting is the one where the answer is 'yours, and it was never in our image'.",
        "表 11 权属。首次会谈中最关键的一行，是那条答案为“属于您，且从未进入我们的镜像”的行。",
    ),
}))

B((
    "p",
    "Two boundary statements follow from the table and are worth stating explicitly, because both are frequently misread. The platform does not hold the firm's data in escrow and cannot read it remotely: there is no vendor-side endpoint in the data path. Conversely, the vendor cannot repair a corrupted matter record by reaching into the firm's volume; recovery is a local operation the firm runs, which is why the update path preserves volumes rather than recreating them.",
    "由上表可引出两条边界声明，二者常被误读，故明确表述。其一，平台不以托管方式代持律所数据，亦无法远程读取：数据通路上不存在供应方端点。其二，供应方也无法通过访问律所数据卷来修复损坏的事项记录；恢复是律所在本地执行的操作，这正是更新路径保留而非重建数据卷的原因。",
))

# ── 9. The one exception ────────────────────────────────────────────────────

B(("h1", "9. The one exception, stated plainly", "9. 唯一例外的明确说明"))

B((
    "p",
    "A document that claims absolute locality is not believable to a reviewer who can see network traffic, and an unbelievable claim damages every other claim in the same document. So the exception is stated here rather than omitted.",
    "一份声称绝对本地化的文档，对能查看网络流量的审查者而言并不可信；而一处不可信的声明会连带削弱同一文档中的全部其他声明。故此处明确陈述例外，而非省略。",
))

B(("table", {
    "widths": [0.24, 0.30, 0.46],
    "headers": [
        ("What leaves the workstation", "离开工作站的内容"),
        ("When", "何时"),
        ("Status of the decision", "决策状态"),
    ],
    "rows": [
        [("Conversation text sent to a hosted model service", "发往托管模型服务的对话文本"), ("Only when the firm selects a cloud model in the picker. The shipped default is a local model, and automatic escalation stays local", "仅当律所在选择器中选用云端模型时。出厂默认为本地模型，且自动升级亦保持本地"), ("Accepted deliberately in exchange for faster research turnaround. Not a defect, and not to be re-opened as one", "经审慎接受，以换取更短的研究周期。此非缺陷，亦不应被重新当作缺陷处理")],
        [("Model weights and inference metadata", "模型权重与推理元数据"), ("Only for cloud-tagged models, which have no weight layers on disk and route inference to the provider", "仅限标注为云端的模型：此类模型在磁盘上无权重层，推理被路由至服务商"), ("Operational consequence: those tags never appear as loaded local models, and they require a signed-in session before install", "运营后果：此类标签从不会显示为已加载的本地模型，且安装前需要完成登录")],
        [("Documents, matter records, generated files, vectors, memory", "文档、事项记录、生成文件、向量、记忆"), ("Never", "从不"), ("The data path has no vendor endpoint. This is the claim the whole ownership table rests on", "数据通路上不存在供应方端点。整张权属表正建立于此项声明之上")],
        [("Retrieval and extraction", "检索与抽取"), ("On the workstation, using a fixed local embedding model", "在工作站上，使用固定的本地嵌入模型"), ("Also the reason the embedding model is not swappable without a re-index", "这也是嵌入模型不可在不重建索引的前提下更换的原因")],
    ],
    "note": (
        "Table 12. Egress boundary. The honest form of the claim is 'documents stay local, and here is the one thing that does not'.",
        "表 12 外联边界。诚实的表述是“文档留在本地，以下是唯一不留在本地的内容”。",
    ),
}))

B((
    "quote",
    "The distinction that matters to a reviewer is between inference that happens on the desk and inference that leaves it. A model tag saying 'cloud' is not a deployment detail; it is the difference between the two, and it should be read as such in any procurement review.",
    "对审查者而言，关键区别在于推理发生在案头，还是离开了案头。标注为“云端”的模型标签并非部署细节，而是上述两者的分野；在采购评审中应据此理解。",
))

# ── 10. Honest state ────────────────────────────────────────────────────────

B(("h1", "10. Current state, without rounding up", "10. 当前状态（不作美化）"))

B((
    "p",
    "A reference document that lists only finished work is not usable for planning. Table 13 separates what is running and verified from what is scaffolded, using the same language a reviewer would use.",
    "只列已完成工作的参考文档无法用于规划。表 13 沿用审查者的表述方式，把已运行且经核实的内容与仅有骨架的内容分开列示。",
))

B(("table", {
    "widths": [0.24, 0.12, 0.34, 0.30],
    "headers": [
        ("Component", "组件"),
        ("State", "状态"),
        ("Evidence", "依据"),
        ("Effect on a deployment", "对部署的影响"),
    ],
    "rows": [
        [("Matter core service, auth, documents, workflows", "事项核心服务、鉴权、文档、工作流"), ("Running", "已运行"), ("Route table implemented end to end; health and build info answer without authentication", "路由表已端到端实现；健康与构建信息无需鉴权即可应答"), ("The spine a firm actually uses", "律所实际使用的主脊")],
        [("Document engine with tracked edits", "具备修订留痕的文档引擎"), ("Running", "已运行"), ("Versioned writes and anchored replacement in the core service", "核心服务内的带版本写入与锚点替换"), ("Deliverables are produced, not promised", "成果文件是产出的，而非承诺的")],
        [("De-identification pipeline", "去标识流水线"), ("Running", "已运行"), ("Five ordered stages, 19 entity types, ledger and restore path", "五个有序阶段、19 类实体、台账与还原路径"), ("The gate is real; T3 and T4 require review", "闸门确实生效；T3、T4 必须人工复核")],
        [("Retrieval with class ceiling", "带密级上限的检索"), ("Running", "已运行"), ("Class, jurisdiction, matter and source filters all applied in one query path; an unparseable class ceiling is refused rather than replaced by the default", "密级、法域、事项与来源四重过滤在同一查询路径上生效；无法解析的密级上限将被拒绝，而非以默认值替代"), ("Retrieval cannot silently widen", "检索不会悄然放宽范围")],
        [("Document body reads", "文档正文读取"), ("Running", "已运行"), ("One admission decision covers extraction and download; a document in 'pending' or 'blocked' yields its body to neither; every read and every refusal writes an audit row", "抽取与下载共用同一准入判断；处于“待处理”或“已拦截”的文档，两条路径均不返回正文；每次读取与每次拒绝均写入审计行"), ("Reading a document is a recorded event, and a blocked one is not readable through a second route", "读取文档属留痕事件，且被拦截的文档不能经由第二条路径读取")],
        [("Legal connectors", "法律数据连接器"), ("Partial", "部分可用"), ("27 catalogued, 11 implemented; two Chinese primary sources are the working ones, one needs a renewed token", "目录 27 项、已实现 11 项；两个中国一手数据源可用，其中一个需续期令牌"), ("Verify credentials at install, not at first use", "在安装时而非首次使用时校验凭据")],
        [("Tabular review", "表格审阅"), ("Declared, not wired", "已声明，未接入"), ("Both routes answer with an explicit internal error rather than a fabricated result", "两条路由返回明确的内部错误，而非虚构结果"), ("Do not sell it as available", "不应将其作为可用能力对外承诺")],
        [("Rule and validation engines", "规则与校验引擎"), ("Scaffolded", "骨架"), ("Fixed signatures returning constant values", "固定签名，返回常量值"), ("Blueprint work, outside the pilot scope", "属蓝图阶段工作，不在试点范围内")],
        [("Collaboration runtime", "协作运行时"), ("Bring-up separate", "独立启动"), ("Started by its own bootstrap rather than by the core compose stack", "由其自身引导脚本启动，不由核心编排栈启动"), ("Two start procedures to document, not one", "需记录两套启动程序，而非一套")],
    ],
    "note": (
        "Table 13. State of the build. 'Declared, not wired' and 'running' are deliberately different words, because a reader planning a pilot needs the difference.",
        "表 13 建设状态。“已声明未接入”与“已运行”刻意使用不同表述，因为规划试点的读者需要这一区别。",
    ),
}))

B((
    "p",
    "The pattern worth noticing is that unfinished components fail visibly. A tabular request returns an error; an empty extraction fails rather than producing an empty document; a missing connector reports a credential problem. That is a deliberate property, because silent partial success is the failure mode that costs a firm trust in the whole system.",
    "值得注意的规律是：未完成的组件以可见方式失败。表格请求返回错误；抽取为空时失败而非产出空文档；缺少连接器时报告凭据问题。这属有意为之，因为静默的部分成功，正是让律所对整个系统失去信任的失败模式。",
))

# ── 11. Reading it back ─────────────────────────────────────────────────────

B(("h1", "11. Reading the system back as a whole", "11. 回看整体"))

B((
    "p",
    "Taken together, the design answers four questions that a general-purpose assistant leaves open, and it is worth checking that the answer to each is visible in the tables above rather than only asserted here.",
    "综合而言，该设计回答了通用助手通常不予回答的四个问题。下列每一条的答案都应能在前述表格中查到，而非仅在本文中被主张。",
))

B(("table", {
    "widths": [0.26, 0.36, 0.38],
    "headers": [
        ("Question", "问题"),
        ("Where the answer lives", "答案所在"),
        ("What a reader should check", "读者应核查之处"),
    ],
    "rows": [
        [("Who is the agent speaking as, and with what authority?", "智能体以何种身份、何种权限发言？"), ("Role overlay with enforcement points, Table 7", "带强制点的角色叠加，表 7"), ("That boundary rules are split by enforcement point, and that an unimplemented gate is reported as unimplemented rather than assumed to hold", "边界规则按强制点分流，且未实现的闸门如实报告为未实现，而非假定其成立")],
        [("What may it touch, and how much?", "可触及何物，数量几何？"), ("Tool schemas and hard caps, Tables 4 and 7", "工具模式与硬上限，表 4、表 7"), ("That the caps are constants in code, not configuration a run can raise", "上限为代码常量，而非运行可自行提高的配置")],
        [("What evidence survives the run?", "一次运行后留下何种证据？"), ("Lifecycle evidence column, Table 3; ledger and restore, Table 9", "生命周期中的证据列，表 3；台账与还原，表 9"), ("That every step leaves a named artefact rather than a log line", "每步留下的是具名产物，而非仅一行日志")],
        [("What is honestly not finished?", "哪些确实尚未完成？"), ("State table with distinct words for distinct states, Table 13", "以不同措辞区分不同状态的状态表，表 13"), ("That failures are visible rather than silent", "失败是可见的，而非静默的")],
    ],
    "note": (
        "Table 14. The four questions. If a claim in this document cannot be located in a table, it should be treated as an assertion and discounted.",
        "表 14 四个问题。若本文件中的某项主张无法在表格中定位，应视其为断言并相应降低其可信权重。",
    ),
}))

B((
    "p",
    "The remaining work is operational rather than architectural: renewing connector credentials, wiring the tabular engine, and completing the blueprint components. None of those changes the shape described above, which is why this document can be used to plan a pilot and to brief a reviewer before they open the system themselves.",
    "剩余工作属运营而非架构层面：续期连接器凭据、接入表格引擎、完成蓝图组件。这些均不改变上述形态，故本文件可用于规划试点，亦可在审查者亲自打开系统之前作为简报依据。",
))

B((
    "quote",
    "One sentence to carry away: the platform's claim is not that a model is clever, but that a chain of custody survives from question to signed document.",
    "一句话概括：本平台的主张不在模型有多聪明，而在于从提问到签署文档的全链条可追溯、可证明。",
))




