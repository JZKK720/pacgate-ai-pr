# 开源项目 Git 仓库索引

> **创建日期**：2026-08-05
> **用途**：技术团队快速访问所有评估涉及的开源项目仓库
> **关联文档**：`open-source-legal-ai-evaluation.md`（法律 AI 尽调报告）、`compliance-open-source-evaluation.md`（合规项目评估报告）

---

## 一、法律 AI 项目（系统底座选型）

来源：`open-source-legal-ai-evaluation.md`

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **Suzie Law** | 🏗️ **代码底座**（推荐） | MIT | TypeScript | https://github.com/firelex/suzielaw |
| Team Suzie（底层框架） | Suzie Law 的基础框架 | MIT | TypeScript | https://github.com/firelex/open_teamsuzie |
| **Lavern** | 🧠 Agent 架构参考 | MIT | TypeScript | https://github.com/AnttiHero/lavern |
| **Mike OSS** | 🎨 交互设计参考（⚠️ AGPL，不可用代码） | AGPL-3.0 | TypeScript | https://github.com/Open-Legal-Products/mike |
| Mike Workflows | 工作流参考 | AGPL-3.0 | — | https://github.com/Open-Legal-Products/mike-workflows |
| **dd-agents** | 🔍 M&A 尽调 + 质量门控参考 | Apache-2.0 | Python | https://github.com/zoharbabin/due-diligence-agents |
| dd-agents (PyPI) | pip install 直装 | — | Python | https://pypi.org/project/dd-agents/ |

---

## 二、制裁与进出口合规模块

来源：`open-source-legal-ai-evaluation.md`

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **OpenSanctions/yente** | 制裁名单匹配 API（P0 基础组件） | MIT | Python | https://github.com/opensanctions/yente |
| yente-client | Python SDK + MCP Server（AI Agent 调用） | MIT | Python | https://github.com/opensanctions/yente-client |
| OpenSanctions 数据集 | OFAC/EU/UN 制裁数据源 | 非商用免费/商用付费 | Data | https://github.com/opensanctions |
| **EximAgent CLI** | HS 编码分类 + 贸易情报 CLI（参考思路） | — | Shell | https://github.com/EximAgent/cli |

---

## 三、合规通用基础设施

来源：`compliance-open-source-evaluation.md`

### 3.1 AI 治理与 Agent 护栏

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **NVIDIA NeMo Guardrails** | Agent 行为护栏（合规通用） | Apache-2.0 | Python | https://github.com/NVIDIA-NeMo/Guardrails |
| **VerifyWise** | AI 治理看板（架构参考，TypeScript 一致） | MIT | TypeScript | https://github.com/verifywise-ai/verifywise |

### 3.2 策略引擎与合规即代码

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **OPA (Open Policy Agent)** | 合规策略引擎（策略即代码） | Apache-2.0 | Go | https://github.com/open-policy-agent/opa |

### 3.3 AI 公平性与偏见检测

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **IBM AIF360** | AI 决策偏见检测与缓解 | Apache-2.0 | Python | https://github.com/Trusted-AI/AIF360 |
| **Deepchecks** | ML 模型持续验证与监控 | AGPL-3.0 | Python | https://github.com/deepchecks/deepchecks |

---

## 四、数据合规与隐私

来源：`compliance-open-source-evaluation.md`

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **Fides (Ethyca)** | Privacy as Code（数据合规/数据跨境） | MIT | Python | https://github.com/ethyca/fides |
| **Privado** | 数据流扫描 + 隐私合规审计 | MIT | Scala | https://github.com/Privado-Inc/privado |
| **Privacy Data Protection Skills** | 合规技能模板（SKILL.md 格式参考） | Apache-2.0 | Markdown | https://github.com/mukul975/privacy-data-protection-skills |

---

## 五、安全合规与配置审计

来源：`compliance-open-source-evaluation.md`

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **CISO Assistant** | 合规框架管理（多框架映射） | GPL-3.0 | Python | https://github.com/intuitem/ciso-assistant-community |
| **OpenLane** | 合规自动化后端框架（Go API） | MIT | Go | https://github.com/theopenlane/core |
| **GovReady-Q** | 合规自动化 + System Security Plan | GPL-3.0 | Python | https://github.com/GovReady/govready-q |
| **Prowler** | 云安全合规扫描（AWS/Azure/GCP） | Apache-2.0 | Python | https://github.com/prowler-cloud/prowler |
| **ComplianceAsCode** | SCAP 安全基线配置（RHEL/Ubuntu） | BSD-3-Clause | Python/Ansible | https://github.com/ComplianceAsCode/content |
| **InSpec** | 基础设施合规检测 | Apache-2.0 | Ruby | https://github.com/inspec/inspec |

---

## 六、金融与监管科技

来源：`compliance-open-source-evaluation.md`

| 项目 | 用途 | 许可证 | 语言 | Git 仓库 |
|------|------|--------|------|---------|
| **FINOS Open RegTech SIG** | 监管合规开放标准 | Apache-2.0 | — | https://github.com/finos/open-regtech-sig |

---

## 七、参考资源（Awesome Lists）

| 清单 | 用途 | Git 仓库 |
|------|------|---------|
| awesome-compliance (theopenlane) | 最全面的合规工具清单 | https://github.com/theopenlane/awesome-compliance |
| awesome-compliance (getprobo) | 侧重商业工具对比 | https://github.com/getprobo/awesome-compliance |
| awesome-terraform-compliance | IaC 合规专项 | https://github.com/antonbabenko/awesome-terraform-compliance |

---

## 优先级速查

技术团队按建设批次参考：

### 首批（P0）— Phase 1-3 底座 + Phase 4 首批合规
| 优先级 | 必看仓库 |
|--------|---------|
| 🔴 **代码底座** | [Suzie Law](https://github.com/firelex/suzielaw) · [Team Suzie](https://github.com/firelex/open_teamsuzie) |
| 🔴 **Agent 架构** | [Lavern](https://github.com/AnttiHero/lavern) |
| 🔴 **质量门控 + M&A** | [dd-agents](https://github.com/zoharbabin/due-diligence-agents) |
| 🔴 **制裁筛查（P0）** | [yente](https://github.com/opensanctions/yente) · [yente-client](https://github.com/opensanctions/yente-client) |
| 🟡 **Agent 护栏** | [NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails) |
| 🟡 **策略引擎** | [OPA](https://github.com/open-policy-agent/opa) |

### 二期（P1）— Phase 4 二期合规子模块
| 优先级 | 必看仓库 |
|--------|---------|
| 🟡 **数据合规** | [Fides](https://github.com/ethyca/fides) · [Privado](https://github.com/Privado-Inc/privado) · [Privacy Skills](https://github.com/mukul975/privacy-data-protection-skills) |
| 🟡 **AI 治理** | [VerifyWise](https://github.com/verifywise-ai/verifywise) · [AIF360](https://github.com/Trusted-AI/AIF360) |
| 🟡 **进出口合规参考** | [EximAgent CLI](https://github.com/EximAgent/cli) |

### 三期（P2）— Phase 4 三期合规子模块
| 优先级 | 参考仓库 |
|--------|---------|
| 🟢 **安全合规参考** | [CISO Assistant](https://github.com/intuitem/ciso-assistant-community) · [OpenLane](https://github.com/theopenlane/core) · [GovReady-Q](https://github.com/GovReady/govready-q) |
| 🟢 **配置审计** | [Prowler](https://github.com/prowler-cloud/prowler) · [ComplianceAsCode](https://github.com/ComplianceAsCode/content) · [InSpec](https://github.com/inspec/inspec) |
| 🟢 **RegTech 标准** | [FINOS Open RegTech](https://github.com/finos/open-regtech-sig) |

---

## ⚠️ 许可证风险提示

| 项目 | 许可证 | 风险 | 建议 |
|------|--------|------|------|
| **Mike OSS** | AGPL-3.0 | 🔴 高 — 网络服务必须开源全部修改 | 仅参考交互设计，**不使用任何代码** |
| **Deepchecks** | AGPL-3.0 | 🔴 高 — 同上 | 仅评估参考，如需使用需联系商业授权 |
| **CISO Assistant** | GPL-3.0 | ⚠️ 中 — 修改后分发需开源 | 独立部署不分发，或评估商业授权 |
| **GovReady-Q** | GPL-3.0 | ⚠️ 中 — 同上 | 同上 |
| **EximAgent CLI** | 未明确 | ⚠️ 需确认 | 联系作者确认商用许可 |

> 其余项目均为 MIT 或 Apache-2.0，商用友好。

---

*由 Pacgate AI Law Firm 项目管理助手生成，2026-08-05。*
