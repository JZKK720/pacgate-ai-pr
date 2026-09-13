# Pacgate AI - 第一阶段本地试点

面向多租户律师事务所的隐私优先法律 AI 平台。无头 Rust 元数据网关，搭配 deer-flow 检索运行时、qm 协作运行时与 OpenViking 长期记忆模块。

**English:** [README.md](README.md) | [Staff Handbook](docs/PACGATE-LAW-STAFF-HANDBOOK.md)

## 版本：v0.1.3（2026年9月6日）

- Rust 元数据核心：12 个 crate + 4 个 WASM crate，冒烟/智能体/工作流/集成测试全部通过
- 15 个文件共 220 个 YAML 工作流模板
- 30 个法律角色人格（20 个业务领域 + 10 个 SOUL）
- Rust `default_router()` 中有 10 个数据源连接器（元典、北大法宝、企查查、法源开、CourtListener、SEC EDGAR、GLEIF、Vaquill、EUR-Lex、OpenCorporates）——deer-flow MCP 面暴露 17 个已启用服务器
- RAG 检索（pgvector + tsvector + Ollama 嵌入，T1-T4 数据分级过滤）— 完全本地运行
- OpenViking 记忆模块：经 qm 桥接的 ov-remember / ov-search / ov-read，deer-flow 内 MCP 召回
- 认证体系（JWT + argon2 + SOUL 解析中间件）
- pacgate-api 镜像：`ghcr.io/jzkk720/pacgate-api:0.1.3`（公开；LLM 路由遵循 `OLLAMA_BASE_URL`，支持按租户模型覆盖）
- deer-flow 封装镜像：`ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.3`（公开）
- pacgate-mcp 桥接镜像：`ghcr.io/jzkk720/pacgate-mcp:0.1.3`（公开；暴露 10 个 MCP 工具，含文档/工作流）
- deer-flow 前端封装镜像：`ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.0`（公开；构建时烘焙网关地址）
- qm 协作桥接已验证（Python CLI，HARNESS=pi，真实 Ollama）
- 客户部署包已入库：`deploy/client-bundle/` — 全新克隆安装路径已验证
- 知识图谱：935 节点、2220 条边、49 个社区
- 面向员工的用户手册（中英双语）位于 `docs/PACGATE-LAW-STAFF-HANDBOOK*.md`，附 PDF 导出

### 模型策略（2026年8月30日确定）

工作流各层级在设备本地运行。**客户运行时**（`deploy/client-bundle/deer-flow-config.yaml`）默认使用本地 `ornith-1.5:9b/35b` 与 `nemotron-3.5-lightning:30b` 用于检索；`nomic-embed-text` 用于 RAG 嵌入。**开发/CI 参考配置**（`deploy/deer-flow-pacgate/config.yaml`）使用云端路由的 `deepseek-*-cloud` 标签以提速。qm 通过 `PI_MODEL` 使用 `glm-5.3-flash:cloud`。事务所接受对话生成提示词经 ollama.com 处理；文件存储、RAG 与记忆抽取始终不离开 AIPC。`ollama signin` 为云端标签模型的安装前置条件。

## 快速部署

在每台 AIPC 上克隆仓库并按手册操作：

```powershell
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
```

完整分步安装指南见 `deploy/AIPC-DEPLOYMENT-HANDBOOK.md`。GHCR 运行时镜像为公开包，无需 `docker login`。

## 系统架构

```
nginx :8081
├── /          -> pacgate-api :8080（Rust, Axum）
├── /api/      -> pacgate-api :8080
├── /research/ -> deer-flow :8001（Python, LangGraph）
└── qm :8182   ->（独立运行，经 qm up 启动）

Postgres :5432（元数据库）
OpenViking :1933（长期记忆模块，MCP）
Ollama :11434（原生安装，GPU/NPU）
```

两台 AIPC 完整运行同一套栈，各自独立可用。

## 主要目录

| 路径 | 用途 |
|------|------|
| `pacgate-ai/crates/` | Rust 工作区（12 个 crate） |
| `pacgate-ai/wasm-crates/` | WASM 沙箱 crate（文档校验、规则引擎、引用核对、条款解析） |
| `pacgate-adapters/python/` | deer-flow 适配器（176 行） |
| `pacgate-adapters/typescript/` | qm 合约库（8 项测试） |
| `deploy/client-bundle/` | 客户部署包（compose、install.ps1、nginx、qm 引导脚本） |
| `deploy/client-delivery/` | 客户交付包（文档 PDF + README 索引） |
| `deploy/handbooks/` | 集成手册（deer-flow/qm + OpenViking + pacgate 网关）+ 渲染脚本 |
| `deploy/qm-pacgate/` | qm 部署目录（配置、沙箱、桥接工具） |
| `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` | 双 AIPC 分步安装指南 |
| `deploy/SETUP-AND-OPERATIONS-ZH.md` | 完整三天驻场安装指南（中文版） |
| `deploy/DEPLOYMENT-GUIDE.md` | 工程师级部署细节 |
| `docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md` | 员工使用手册（非技术向） |
| `docs/` | 方案页、建设计划、进度报告卡 |
| `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md` | 第一阶段商务与技术计划 |

## GHCR 镜像

Pacgate 运行时镜像均为**公开**（已验证匿名拉取）。源码仓库保持私有。所有镜像在每个发布标签时由 `.github/workflows/build-ghcr.yml` 重建并推送到 GHCR，以确保两台 AIPC 保持同步。

| 镜像 | 内容 | 基础镜像 |
|-------|----------|------|
| `ghcr.io/pacgate-ai/pacgate-api:0.1.3` | Rust 二进制 + SQL 迁移 | `rust:1.94-bookworm` -> `debian:bookworm-slim` |
| `ghcr.io/pacgate-ai/pacgate-mcp:0.1.3` | pacgate-api MCP 桥接（10 个工具，含文档/工作流） | `python:3.12-slim` |
| `ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.3` | deer-flow 后端 + Python 适配器 | `ghcr.io/bytedance/deer-flow-backend`（固定 SHA） |
| `ghcr.io/pacgate-ai/deer-flow-frontend-pacgate:0.1.0` | deer-flow Next.js 检索界面（构建时烘焙网关地址） | `node:22-alpine` |

qm 不使用 GHCR 镜像，通过入库的 `deploy/qm-pacgate/` 目录以 `qm up` 启动。

构建/推送流程与 owner 命名空间决策见 `deploy/README-BUILD.md`。

## 测试

```powershell
cd pacgate-ai
cargo check
cargo test -p pacgate-api --test smoke
cargo test -p pacgate-agent
cargo test -p pacgate-workflow --test yaml_loader
```

集成测试需要 `localhost:5433/pacgate_test` 上的 Postgres：

```powershell
$env:PACGATE_TEST_DATABASE_URL='postgres://hermes:changeme@localhost:5433/pacgate_test'
cargo test -p pacgate-api --test integration -- --ignored
```

TypeScript 适配器测试：

```powershell
cd pacgate-adapters/typescript
npm test
```

## 许可

私有仓库。第一阶段全部交付成果的版权归 Pacgate 所有。商务条款见 `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md`。
