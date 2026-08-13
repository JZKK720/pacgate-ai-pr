# Pacgate AI Phase 1 临时澄清工作板方案

- 定位：临时内部 / 对客澄清协作层
- 技术形态：单文件 HTML + 内嵌 JavaScript + 可导入 / 导出的本地 JSON
- 状态：不接入 `docs/index.html`，不并入 onboarding surface
- 目标：把“客户问题 - 事实校正 - 范围判断 - 回复草稿 - 可发送版本”变成可持续推进的工作流

## 1. 为什么要单独做临时工作板

1. 问卷内容仍在变化，会继续追加问题、修正假设、插入研究依据，不适合直接混入公开 proposal 页面。
2. 当前最需要的是内部分拣、优先级排序和响应协作，而不是面向外部展示的正式网站页面。
3. 该层需要支持打印、导出 PDF、在会议中共享屏幕快速移动卡片，这和正式宣传 / onboarding 页面目标不同。

## 2. 建议的工作板产物

1. `PACGATE-AI-PHASE1-CLARIFICATION-QUESTIONS.md`
2. `PACGATE-AI-PHASE1-CLARIFICATION-ANALYSIS.md`
3. `pacgate-phase1-workboard.seed.json`
4. `pacgate-phase1-workboard.html`
5. 浏览器打印导出的 PDF 版本

## 3. 板面结构

建议采用以下 6 个 lane：

1. `Inbox`：尚未归并或尚未理解的问题
2. `Triaged`：已判断分类、优先级和归类，但还未补足依据
3. `Needs Research`：需要查 proposal、上游 README、许可证、硬件方案或报价假设
4. `Draft Response`：已有回复方向，正在压缩成客户可读语言
5. `Ready To Send`：已形成建议答复，可放入正式回函附件
6. `Deferred / Out Of Scope`：明确留给顾问小时、增项或 Phase 2 discovery

## 4. 卡片字段建议

每张卡至少包含：

1. `id`
2. `section`
3. `questionRefs`
4. `title`
5. `category`
6. `priority`
7. `delivery`
8. `owner`
9. `whyItMatters`
10. `recommendedResponse`
11. `evidence`
12. `nextAction`

## 5. 使用规则

1. 不为每一个问题强行创建独立卡片。优先按“一个决定点”聚合多个问题编号。
2. 每张卡必须包含 question refs，确保能追溯回原问卷。
3. 进入 `Ready To Send` 前，至少要完成一次“事实依据检查”，避免把 Phase 2 内容误答成 Phase 1 承诺。
4. 与硬件、许可证、商业报价相关的卡片，默认不能只靠口头结论，必须配 annex 或表格。
5. 客户误解类问题不要只写否定答案，要补一条“更合理的替代路径”。

## 6. 建议的首次工作板节奏

1. 会话一：只处理范围边界、系统 1 / 系统 2 定位、Package 2 / 3 改写建议。
2. 会话二：只处理硬件、部署、安全和数据流。
3. 会话三：只处理外部法律数据库、RAG、context graph、入口自动化和验收付款。
4. 会话四：把 Deferred / Out Of Scope 项目单独汇总成 Phase 2 options note。

## 7. PDF 输出建议

1. 每次对外发送前，从 HTML 工作板打印为 PDF，作为会议版摘要。
2. 对正式客户回函，优先导出分析结果和 annex，不直接把原始 Kanban 发给客户。
3. HTML 页面应包含 print 样式，保证 A4 导出时 lane 与卡片仍可阅读。

## 8. 完成标准

工作板第一版算完成，需要满足：

1. 至少 10 张优先卡片已经入板
2. 每张高优先卡片都带有 question refs 和建议回复方向
3. 至少一张卡明确标注 Claude for Legal 的边界
4. 至少一张卡明确标注 Lavern 的边界
5. 至少一张卡明确标注硬件 annex 需求
6. 至少一张卡明确标注 Phase 2 discovery / quote carve-out