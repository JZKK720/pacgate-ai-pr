# Patent Disclosure Report — Prompt Template
# 专利交底书生成 — 提示词模板

> **Purpose / 用途** — Reusable agent prompt that produces a patent disclosure (交底书) within the PacGate boundary. It uses only PacGate-compatible tools (`read_document`, `kb_search`, `write_file`, `upload_document`, `generate_docx`) and avoids calling Bash, browsers, or arbitrary code execution.
>
> **如何用** — 把下方 `<PROMPT>` 块粘贴到 deer-flow 聊天页（主页面）即可。请先替换方括号 `[...]` 中的占位内容。

---

## Usage Notes / 使用说明

- **Name the subject (inventor / company / application) up front.** If you omit it, the model will call `ask_clarification` instead of writing the report. This is the single most common cause of "the model ignored write_file."
- **Keep the output path explicit** so `write_file` fills all required args (`description`, `path`, `content`).
- The prompt deliberately stays inside PacGate's tool boundary. It does **not** assume Bash, Playwright, Obsidian, or local Python scripts.

---

## The Prompt / 提示词

```text
你是一名专利代理师，负责协助撰写一份《专利交底书》。请严格遵循下面的步骤，只使用 PacGate 提供的工具（read_document、kb_search、write_file、upload_document、generate_docx）。不要尝试调用 Bash、浏览器或本地脚本。

【核查对象 / Subject】
申请主体：____________________（公司全称 / 统一社会信用代码）
发明人 / 团队：____________________
技术名称：____________________
所属领域：____________________

【第一步：检索既有知识 / Step 1 — Retrieve existing knowledge】
使用 kb_search 检索本所知识库中与“____________________”相关的既有技术方案、同类专利、审查意见或撰写规范，检索关键词不少于 3 个。把检索到的相关段落作为背景依据。

【第二步：读取已上传材料 / Step 2 — Read uploaded materials】
如果有已上传的关联文档（技术方案、实验数据、设计图说明等），使用 read_document 读取，并在交底书中引用关键事实与数据。

【第三步：撰写交底书 / Step 3 — Draft the disclosure】
基于上述检索与材料，撰写一份结构完整的《专利交底书》，包含以下章节：
1. 发明名称
2. 技术领域
3. 背景技术（含现有技术缺陷）
4. 发明内容（要解决的技术问题、技术方案、有益效果）
5. 附图说明（若无附图，写明“无”或“待补充”）
6. 具体实施方式
7. 关键创新点（至少 3 条）
8. 可替代方案或风险提示

语言：中文正文；若客户要求，可在英文标题旁标注英文。

【第四步：写入文件 / Step 4 — Write to file】
使用 write_file 将完整交底书写入：
- description：专利交底书 — <技术名称>
- path：/mnt/user-data/outputs/专利交底书_<技术名称>.md
- content：完整交底书正文

写入完成后，用 present_files 呈现该文件路径，并做一次 3-5 句的交付摘要，说明报告结构、关键创新点与仍需人工确认的字段。

【约束 / Constraints】
- 只使用 PacGate 边界内的工具；不要调用 Bash、浏览器或本地脚本。
- 若关键信息缺失（如申请主体、技术名称），先列出缺失项并给出建议，不要擅自编造。
- 全文使用规范中文，避免口语化表达。
```

---

## Why This Works / 为什么这样写

- **Naming the subject up front** stops the `ask_clarification` loop we reproduced live. With a named company (e.g. 华为技术有限公司), the model researched then called `write_file` 20 times and produced a valid file.
- **Explicit `write_file` args** (`description`, `path`, `content`) match the required tool signature, so the model never drops a required field.
- **Restricted to PacGate tools** keeps the prompt compatible with the platform boundary even though the original skill needed Python/Playwright/Obsidian.

## Related / 相关

- Porting rationale: `../PacGate-ai Skill Installation Analysis.md` (the compatibility assessment for `patent-disclosure-skill`).
- The conclusion was: the skill cannot run wholesale inside PacGate, but **Mode A (交底书编写)** can be ported as this boundary-safe workflow.
