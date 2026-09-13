# Pacgate-ai 客户交付包（Client Delivery Package）

> 面向律师事务所客户的技术交付文档集
> 版本 0.1.4 — 2026-09-05

本交付包包含 Pacgate-ai 系统的**客户可见文档**（PDF）与**运行时部署包**。请按读者分发。

---

## 一、文档包（`docs/`）— 按读者分发

按读者使用，每位读者只需阅读自己那一列。

### 1. 律所员工（律师、助理、合伙人）— 无需技术背景

| 文档 | 语言 | 用途 |
|---|---|---|
| **PACGATE-LAW-STAFF-HANDBOOK.pdf** | 英文 | 端用户使用手册（通俗语言，8 节：是什么、首次使用、案件、检索工作区、团队协作、隐私、故障、礼仪） |
| **PACGATE-LAW-STAFF-HANDBOOK-ZH.pdf** | 中文 | 端用户使用手册（中文版） |

> **建议**：员工只需读 **Staff Handbook**。它是给普通律师/助理的入门手册，用白话讲清「两个入口、案件隔离、引用可追溯、哪些数据留在楼内」。

### 2. 律所管理员 / IT 支持（技术管理）— 需要了解整体

| 文档 | 语言 | 用途 |
|---|---|---|
| **USER-MANUAL.pdf** | 英文 | 完整版使用手册（12 节，含模型分层、人设、快捷键、术语表） |
| **USER-MANUAL-ZH.pdf** | 中文 | 完整版使用手册（中文版） |

> **说明**：`USER-MANUAL` 是 `Staff Handbook` 的**详细参考版**，覆盖更多功能与配置说明。管理员用它回答员工问题、做培训。

### 3. 客户 IT / 部署工程师 — 部署与运维

| 文档 | 语言 | 用途 |
|---|---|---|
| **AIPC-DEPLOYMENT-HANDBOOK.pdf** | 英文 | 双 AIPC 部署手册（克隆、安装、种子租户、验证） |
| **AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf** | 中文 | 双 AIPC 部署手册（中文版） |

> **关键**：这是**现场部署**的唯一权威步骤来源。包含 2026-09-02 试点后已修复的 3 个关键点（deer-flow 无法查库、OpenViking 密钥错误、`--force-recreate` 清空本地库）。

### 4. 客户技术团队 — 集成原理（可选，深度）

| 文档 | 语言 | 用途 |
|---|---|---|
| **deer-flow-openviking-pacgate-handbook.zh.pdf** | 中文 | deer-flow + OpenViking + pacgate 网关集成原理（端口、MCP、记忆后端、排障） |
| **qm-openviking-pacgate-handbook.zh.pdf** | 中文 | qm + OpenViking + pacgate 网关/RAG 集成原理（沙箱、工具、排障） |

> **说明**：这两份仅中文版，面向需要理解**各组件如何连接**的技术团队；普通员工与现场部署工程师通常不需要。

---

## 二、运行时部署包（`client-bundle/`）— 机器要跑起来需要什么

`client-bundle/` 是**运行时包**（配置、脚本、镜像引用），与文档分开但一起交付：

```
client-bundle/
├── compose.prod.yaml          ← pacgate-api + deer-flow + nginx + Postgres 的 Docker Compose
├── install.ps1                ← 一键 Windows 安装脚本
├── setup-qm.ps1               ← qm 启动脚本
├── .env.example               ← 客户填写数据库密码 + JWT 密钥 + OpenViking 密钥
├── deer-flow-config.yaml      ← deer-flow 多模型配置
├── deer-flow-extensions-config.json ← MCP 服务器注册（法律数据库 + OpenViking）
├── ollama-models.txt          ← 需要预先拉取的模型
├── nginx/default.conf         ← 运行时 nginx 路由
├── openviking/                ← OpenViking 配置
├── workflows/                 ← 15 个 YAML 文件，220 个工作流模板
└── personas/                  ← 20 个执业领域 + 10 个 SOUL 角色参考
```

> **⚠️ 注意**：`client-bundle/` 内的 `.env`、`deer-flow-extensions-config.json`（含 API 密钥）、
> `data/`（运行时租户数据）**不**随交付包分发，也不提交到仓库。客户需自行填写 `.env.example`。

---

## 三、交付结构

```
client-delivery/
├── README.md                  ← 本索引
├── docs/                      ← 客户文档（PDF）
│   ├── PACGATE-LAW-STAFF-HANDBOOK.pdf          (员工/英文)
│   ├── PACGATE-LAW-STAFF-HANDBOOK-ZH.pdf       (员工/中文)
│   ├── USER-MANUAL.pdf                          (管理员/英文)
│   ├── USER-MANUAL-ZH.pdf                       (管理员/中文)
│   ├── AIPC-DEPLOYMENT-HANDBOOK.pdf             (IT 部署/英文)
│   ├── AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf          (IT 部署/中文)
│   ├── deer-flow-openviking-pacgate-handbook.zh.pdf  (技术团队)
│   └── qm-openviking-pacgate-handbook.zh.pdf        (技术团队)
└── client-bundle/             ← 运行时部署包（见上）
```

---

## 四、快速开始（客户 IT）

1. 安装 Docker Desktop 与 Ollama（`ollama signin`）
2. 克隆仓库：`git clone https://github.com/JZKK720/pacgate-ai-pr.git`
3. 进入 `deploy/client-bundle/`，复制 `.env.example` 为 `.env` 并填写
4. 运行 `.\install.ps1`
5. 打开浏览器：`http://localhost:8089`（检索）/ `http://localhost:8182`（协作）

完整分步安装见 `docs/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf`。

---

## 五、分发建议

| 角色 | 分发文档 |
|---|---|
| 普通律师 / 助理 | `PACGATE-LAW-STAFF-HANDBOOK-ZH.pdf`（或英文版） |
| 律所管理员 | `USER-MANUAL-ZH.pdf` + `PACGATE-LAW-STAFF-HANDBOOK-ZH.pdf` |
| 客户 IT / 部署工程师 | `AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf` + `client-bundle/` |
| 客户技术团队（可选） | 两份集成手册（`deer-flow-*` / `qm-*`） |

---

> 本交付包由 pacgate-ai 部署文档与运行环境自动整理生成。版本 0.1.4 — 2026-09-05。
