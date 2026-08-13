# Pacgate Phase 1 合同写作 Agent 方案

> 目标：把现在 `scope-assets/contracts/preapproval-contract-draft/` 下的两份合同草稿 + 选购表，按 `pacgate-contract-review-checklist.md` 的修改清单，**自动填充所有占位符、补齐法务子条款、生成可直接给 Pacgate 法务预审的 docx / xlsx 终稿**，并附"逐条 diff + 依据"以便人工复核。
> 形态：单文件 Python 脚本（与 `__extract.py` 同级），**离线、纯本地**，复用 `python-docx` + `openpyxl`。**不调用任何云端 LLM / API**。
> 适用：Cubecloud 内部起草 → 法务复核 → Pacgate 预审的多轮工作流。

---

## 1. 设计原则（为什么这么做）

1. **可审计性优先于"全自动"**。合同不是写小说，每一句都要能追溯到一份依据（清单编号 / 工作表单元格 / 上游 README）。agent 必须输出 `contract-diff.md`，把每一处改动写成"原句 → 新句 → 依据"。
2. **占位符显式优于隐式推断**。所有数字、日期、付款比例一律来自 `PACGATE-AI-QUOTE-WORKSHEET-ZH.md` 与 `PACGATE-AI-QUOTE-WORKSHEET-ZH.md` 的 F 节，**agent 不允许自己算汇率、不允许自己拍违约金比例**——只能引用工作表 / 清单。
3. **法务条款只补"模板子句"**。终止、保密期限、不可抗力、SLA、知识产权授权这些条款的措辞虽然多，但都是"成熟模板子句"，可以从 pacgate-style 子句库里选择；agent 的工作是**挑子句 + 拼装 + 标注候选**，最终由 Cubecloud 法务拍板。
4. **不破坏 Word 排版**。直接用 `python-docx` 改 paragraph 文本、插入新 paragraph，不动 styles、tables 的结构与字体；保留原稿"盖章 / 签字 / 日期"三行结构。
5. **不强求一次性终稿**。agent 输出 `_filled_v1.docx` / `_filled_v2.docx`，每一版生成 `contract-diff.md` 与 `open-questions.md`，由人按 open-questions 决定下一轮。

---

## 2. 工作流（5 步）

```
[1. 准备阶段] 读入清单 + 三份原文 + 工作表
        ↓
[2. 占位符扫描] 找出 ____ / 空格 / 中文数字缺失
        ↓
[3. 数字填充] 从工作表 F 节读金额、付款比例、税务口径
        ↓
[4. 子句注入] 终止、保密期限、数据返还、不可抗力、IP 授权、反向工程、违约责任补全
        ↓
[5. 输出]  _filled_v1.docx / _filled_v1.xlsx + contract-diff.md + open-questions.md
```

每一步都是**幂等**的（可重跑而不破坏上一步）。

---

## 3. 模块设计

### 3.1 输入层（inputs）

```python
@dataclass
class AgentInputs:
    checklist_md: Path          # pacgate-contract-review-checklist.md
    hardware_docx: Path         # (6.5)智方云本地 AI 硬件设备及标准系统交付合同.docx
    service_docx: Path          # （6.5）智方云法律 Agent 应用定制服务合同.docx
    sku_xlsx: Path              # 智方云产品及服务统一选购表.xlsx
    worksheet_md: Path          # PACGATE-AI-QUOTE-WORKSHEET-ZH.md  (F 段)
    build_plan_md: Path         # PACGATE-AI-BUILD-PLAN-PHASE1-ZH.md (项目定位 / 排除项)
    clarification_md: Path      # PACGATE-AI-PHASE1-CLARIFICATION-ANALYSIS.md (误解纠正口径)
    vendor_card: VendorCard     # 乙方公司全称 / 地址 / 银行 / 税号 (来自 .env 或单独 YAML)
```

`VendorCard` 由用户提供（`vendor.yaml`），是**唯一需要用户填表的地方**。这样 agent 不需要从其他文件里"猜"乙方信息。

### 3.2 占位符扫描器（placeholder_scanner.py）

识别下列形态的占位符：

- 下划线块：`____` （2+ 个连续下划线）
- 长空白块：`   元` / `   日` / `   个工作日` / `   份` / `   %`
- 中文小写金额缺失：`大写：人民币      元整`
- 合同编号 `P0X` → `P01`
- 选购表 "选购" 列空白

输出 `placeholders.json`：

```json
{
  "hardware": [
    {"para_idx": 35, "field": "合同总金额数字", "raw": "人民币¥       元", "expected": "人民币¥ 79,600 元"},
    {"para_idx": 35, "field": "合同总金额大写", "raw": "大写：人民币      元整", "expected": "大写：人民币柒万玖仟陆佰元整"},
    ...
  ],
  "service": [...],
  "sku": [...]
}
```

### 3.3 数字填充器（filler.py）

从 `worksheet_md` 的 F 节抽取：

```python
MILESTONES = [
    ("deposit", 0.60, "硬件确认 + 第一阶段 kickoff / 采购启动"),
    ("m1",      0.30, "两套本地系统安装并可运行"),
    ("final",   0.10, "起步版知识 / RAG 交接完成"),
]
```

从 SKU 表抽取 9 行 + 两个小计 + 总计。**所有数字走 worksheet → SKU 表的方向**（worksheet 是 source of truth，SKU 表只是当前显示层）。

如果 worksheet 与 SKU 表数字不一致 → **agent 立即停机** 并把不一致写入 `open-questions.md`，由人拍板。

### 3.4 子句库（clauses.py）

把"成熟模板子句"写成可组合的 dataclass，每条带 `id / title / body / source_clause_refs`：

```python
@dataclass
class Clause:
    id: str               # "TER-01"
    title: str            # "甲方原因终止"
    body: str             # 多段中文合同条款
    source_refs: list[str]  # 清单编号, e.g. ["§4.1"]
    applicable_to: list[str]  # ["hardware", "service"]
```

子句库至少包含：

- 终止四件套：甲方原因、乙方原因、自然到期、终止后义务
- 保密：期限 5 年 + 法定例外
- 数据返还：30 日内返还 + 7 日内删除
- 不可抗力：通知 5 工作日 + 持续 30 日可解除
- IP 授权：标的 / 范围 / 期限 / 非独家 / 不分许可
- 反向工程与竞业
- 违约责任总包限制的例外清单（保密 / 数据 / 第三方索赔）
- 法律适用：中华人民共和国法律
- 电子签章与送达
- 附件优先级

子句库本体是**纯数据 + Jinja 模板**，agent 不需要"理解中文合同"也能正确拼装。

### 3.5 diff 生成器（diff_writer.py）

逐段对比 `_filled_v1.docx` 与原文，输出 `contract-diff.md`：

```markdown
## HWOS 合同第 3 条
- 原句：`合同总金额：人民币¥       元，大写：人民币      元整。`
- 新句：`合同总金额：人民币¥ 79,600 元（不含增值税，开票时另加 3.5%），大写：人民币柒万玖仟陆佰元整。`
- 依据：
  - `pacgate-contract-review-checklist.md` §2 / §3.5
  - `PACGATE-AI-QUOTE-WORKSHEET-ZH.md` A 节税率口径
  - `智方云产品及服务统一选购表.xlsx` 合同一小计 79,600
```

### 3.6 open-questions 生成器（questions_writer.py）

agent 不自行拍板的剩余事项：

- 税务口径（不含 / 含 13% / 免税）
- 违约金日比例（0.03% / 0.05% / 0.1%）
- 基础远程支持天数（30 / 60 / 90 / 180）
- 现场支持是否纳入本合同（建议否）
- 是否引入 Patch 计划 / 漏洞响应 SLA
- Phase 2 carve-out 表述是否需要附加数据迁移承诺
- 是否需要为 Pacgate 增加 GDPR / 个人信息保护法的特别承诺
- 乙方公司法定中文名

每条都列"agent 推荐答案 / 依据 / 影响条款"。

---

## 4. 目录与文件布局

```
scope-assets/contracts/preapproval-contract-draft/
├── __extract.py                              # 已有：docx / xlsx → txt
├── pacgate-contract-review-checklist.md      # 已有：本轮 review 清单
├── contract-writer-agent-plan.md             # 已有：本文件
├── __vendor.yaml.example                     # 乙方公司信息（待填）
├── hardware_contract.txt                     # 已有
├── service_contract.txt                      # 已有
├── sku_worksheet.txt                         # 已有
│
├── (6.5)智方云本地 AI 硬件设备及标准系统交付合同.docx   # 原文，不动
├── （6.5）智方云法律 Agent 应用定制服务合同.docx        # 原文，不动
├── 智方云产品及服务统一选购表.xlsx                     # 原文，不动
│
└── out/
    ├── placeholders.json                     # agent 第 2 步输出
    ├── hardware_contract_filled_v1.docx      # 终稿 v1
    ├── service_contract_filled_v1.docx       # 终稿 v1
    ├── sku_worksheet_filled_v1.xlsx          # 终稿 v1
    ├── contract-diff.md                      # 逐条 diff + 依据
    └── open-questions.md                     # 待人工决策
```

`__vendor.yaml.example` 模板：

```yaml
legal_name_zh: "智方云科技（深圳）有限公司"
legal_name_en: "Cubecloud Limited"
short_name_zh: "智方云"
registered_address: "深圳市南山区..."
bank:
  account_name: "智方云科技（深圳）有限公司"
  bank_name: "招商银行深圳分行"
  account_no: "xxxx"
  swift: "xxxx"
  branch: "xxx"
tax_id: "91440300MAxxxxxx"
authorized_signer:
  name: "xxx"
  title: "总经理"
```

---

## 5. 实施步骤（agent 跑通后交给人的）

```bash
# 1. 准备（一次）
cp __vendor.yaml.example __vendor.yaml
# 编辑 __vendor.yaml 填入乙方公司信息

# 2. 抽取原文（一次）
python __extract.py

# 3. 跑 agent
python contract_writer.py --vendor __vendor.yaml \
    --out out/hardware_contract_filled_v1.docx \
         out/service_contract_filled_v1.docx \
         out/sku_worksheet_filled_v1.xlsx

# 4. 看 diff
code out/contract-diff.md

# 5. 拍板 open-questions
code out/open-questions.md
```

第 3 步失败 / 中途停下时，不会污染原文 docx / xlsx；失败时 `out/` 下只有 `placeholders.json` + `open-questions.md` + 错误日志。

---

## 6. 边界 / 风险

1. **Word 表格里的内容**：`python-docx` 改 `table.cell.text` 会破坏内嵌格式。建议 v1 只改 paragraph，跳过 table；附件一表的内容靠 SKU 选购表引用"以选购表为准"绕开。
2. **"鉴于甲方..."段落到附件之间**的插入点必须用 paragraph 索引定位。万一用户改了文档结构，paragraph 索引会漂移。**v1 不解决**，留 v2 用 XPath / 关键字定位。
3. **子句库的法律建议性质**：所有子句都要在 docx 与 contract-diff.md 顶部加注"本子句基于商业合同通用模板起草，需经 Cubecloud 法务正式审定"——这是合同写作 agent 不能跨过的责任红线。
4. **不替代法务**：agent 输出 100% 是"草拟稿"，不能直接给客户签字。所有 v1 / v2 终稿必须在正文首加 "DRAFT - 内部审阅版"水印。
5. **多次迭代**：v1 完成后，可能因为 Pacgate 法务反馈又跑 v2 / v3。**每一版必须保留前版的 diff + open-questions**，便于追溯。

---

## 7. 与 Phase 1 整体工作板的衔接

把"合同写作 agent"作为 Phase 1 工作板的 7 号 lane —— "Contract Drafting"。卡片字段沿用 `PACGATE-AI-PHASE1-WORKBOARD-PLAN.md` 第 4 节的 schema（id / section / questionRefs / title / category / priority / delivery / owner / whyItMatters / recommendedResponse / evidence / nextAction），但 `questionRefs` 改为 `clauseRefs`（指向本清单的章节号）。

工作板卡片示例：

| id | section | title | category | priority | clauseRefs | owner | recommendedResponse | evidence | nextAction |
|---|---|---|---|---|---|---|---|---|---|
| CARD-CC-01 | 终止条款 | HWOS / LegalAgent 增加解除子句 | 1 | High | §4.1 | Cubecloud 法务 | 套用模板子句 TER-01..04 | 商业合同通用模板 | v1 自动注入，v2 法务审定 |
| CARD-CC-02 | 知识产权 | IP 授权范围过宽 | 1 | High | §4.4 | Cubecloud 法务 | 限定为"已购单元 + 关联律所 + 内部业务" | 商业合同通用模板 | v1 自动注入 |
| CARD-CC-03 | 数字填充 | 把 119,600 填进合同 | 1 | High | §2 | 合同写作 agent | 从 worksheet F 节读取 | worksheet F 节 | 跑 agent v1 |

---

## 8. 完工标准（Definition of Done）

`合同写作 agent` v1 算完成，需要满足：

1. ✅ 把 `pacgate-contract-review-checklist.md` §2-§4 的所有"占位符"自动填入。
2. ✅ 数字与 `PACGATE-AI-QUOTE-WORKSHEET-ZH.md` 完全一致（agent 自检）。
3. ✅ 选购表 9 行"选购"列全部 ✔；SKU 小计与合同总金额一致。
4. ✅ `contract-diff.md` 列出 ≥ 30 条 diff（按两合同 + 选购表），每条都有"原句 / 新句 / 依据"三栏。
5. ✅ `open-questions.md` 至少 5 条待决策，每条带推荐答案。
6. ✅ 输出 docx / xlsx 在 Word / Excel 中打开排版不破坏。
7. ✅ 终稿首页有 "DRAFT - 内部审阅版" 水印（后续手动删除）。
8. ✅ 跑 1 份本地 unit test：模拟 worksheet F 改成 50% / 30% / 20% 时，agent 输出数字同步更新。
