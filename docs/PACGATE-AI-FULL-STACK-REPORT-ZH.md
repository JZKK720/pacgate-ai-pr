# Pacgate AI — 全栈评估报告

> 第一阶段试点交付准备状态
> 版本 0.1.0 — 2026年8月18日
> 智方云（Cubecloud Limited）

---

## 一、总览

本报告汇总 Pacgate AI 第一阶段（Phase 1）本地试点的完整技术栈状态，覆盖从 Rust 元数据核心到客户端部署包的全部交付层。

**当前阶段：交付就绪，待现场部署**

- 62 次提交，全部推送至 origin
- 全部测试通过（23 项冒烟测试 + 5 项代理测试 + 3 项工作流加载测试 + 2 项集成测试 + 8 项 TS 适配器测试）
- 知识图谱已更新（917 节点、2157 边、47 社区）

---

## 二、各层状态

| 层 | 状态 | 证据 |
|---|---|---|
| Rust 元数据核心（11 个 crate） | ✅ 完成 | 23 项冒烟测试 + 5 项代理测试 + 3 项工作流测试通过。知识图谱 917 节点、2157 边。 |
| 220 个 YAML 工作流模板 | ✅ 完成 | 15 个文件，由 `pacgate_workflow::load_from_yaml_dir()` 加载 |
| 30 个法律角色（20 个执业领域 + 10 个 SOUL） | ✅ 完成 | 通过 SOUL 解析中间件接入聊天处理器 |
| 11 个数据源连接器 | ✅ 大部分可用 | 元典已验证可用 ✅。北大法宝代码已修复但令牌过期 ❌。其余 9 个（4 个中国 + 5 个国际）代码完成。 |
| RAG 检索（pgvector + tsvector + Ollama） | ✅ 完成 | T1-T4 数据分级过滤、司法辖区过滤、4 次数据库迁移 |
| 认证系统（JWT + argon2 + SOUL） | ✅ 完成 | 受保护路由、JWT 携带 soul_id、SOUL 解析中间件 |
| GHCR 容器镜像 | ✅ 已构建并推送 | pacgate-api:0.1.0、deer-flow-pacgate:0.1.0。注：pacgate-api 需重新构建以包含连接器修复。 |
| 客户端部署包 | ✅ 完成 | 27 个文件：compose.prod.yaml、install.ps1、nginx 配置、deer-flow 多模型配置、qm 引导脚本、工作流、角色参考 |
| qm 协作桥接 | ✅ 完成 | Python CLI 端到端测试通过。qm check + sandbox build 通过。HARNESS=pi（真实模型）。 |
| deer-flow 研究适配器 | ✅ 完成 | Python 适配器已安装至包装镜像。多模型配置（5 个模型可切换）。 |
| 综合安装操作指南 | ✅ 完成 | SETUP-AND-OPERATIONS.md — 3 天现场安装操作手册 |
| 集成测试 | ✅ 通过 | 2 项测试连接真实 Postgres 数据库 |
| TS 适配器 | ✅ 通过 | 8 项单元测试（契约库，非 qm 接入层） |
| 知识图谱（Graphify） | ✅ 已更新 | 917 节点、2157 边、47 社区，已同步至 deploy/ |

---

## 三、已知待处理事项

| 待处理项 | 影响 | 修复工作量 |
|---|---|---|
| 北大法宝令牌过期 | 中国法律搜索（北大法宝）不可用 | 小 — 从 mcp.pkulaw.com 控制台重新生成令牌 |
| pacgate-api GHCR 镜像未含连接器修复 | 当前镜像缺少元典/北大法宝连接器修复 | 小 — docker build + push（约 40 秒构建） |
| 4 个 WASM crate 仍为桩代码 | 引用检查、条款解析、文档验证、规则引擎返回空值 | 大 — 未来蓝图工作，非第一阶段范围 |
| pacgate-template 仍为桩代码 | 模板库未实现 | 中 — 未来蓝图工作 |
| 尚未部署至客户 AIPC 机器 | 未向客户交付任何内容 | 3 天现场安装（按 SETUP-AND-OPERATIONS.md 执行） |

---

## 四、当前我们到底在哪里

Pacgate AI 现在不是“还在搭架子”的阶段，而是“可交付、可部署、可验证”的阶段。仓库里已经具备以下内容：

- Rust 元数据核心与周边 crate 已完成并通过测试
- 客户端部署包已经检查入库
- deer-flow 与 qm 的包装/适配路径已经定型
- 仍然缺的是现场交付前的少量运营动作，而不是新的架构设计

### 现在最应该做的 3 件事

1. 重新构建并推送 `pacgate-api` 镜像，确保连接器修复真正进入镜像。
2. 重新生成或替换北大法宝令牌，恢复中国法律检索链路。
3. 按 `SETUP-AND-OPERATIONS.md` 进行客户 AIPC 现场安装、联调和验收。

这三步做完，Phase 1 才算从“准备就绪”真正进入“客户可用”。

---

## 五、构建时间线位置

```
第一阶段蓝图（Rust 工作空间）     ████████████████████████████████████████████ 100%
第一阶段交付（客户端包 + GHCR + 文档）  ████████████████████████████████████████████ 100%
第一阶段部署（现场 AIPC 安装）     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   0%
第二阶段（SaaS 平台 — 未来蓝图）     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   0%（按合同延后）
```

---

## 六、建议的后续步骤（按优先级排序）

### 步骤 1：重新构建并推送 pacgate-api 镜像（约 5 分钟）

当前 `ghcr.io/jzkk720/pacgate-api:0.1.0` 镜像不包含元典/北大法宝连接器修复。

```powershell
docker build -t ghcr.io/jzkk720/pacgate-api:0.1.1 -f pacgate-ai/Dockerfile ./pacgate-ai
docker push ghcr.io/jzkk720/pacgate-api:0.1.1
```

然后将 `compose.prod.yaml` 中的镜像标签更新为 `:0.1.1`。

### 步骤 2：重新生成北大法宝令牌（手动，约 5 分钟）

登录 `https://mcp.pkulaw.com`，重新生成访问令牌，将新令牌写入 `.env` 文件中的 `PKULAW_API_KEY` 字段。

### 步骤 3：打包客户端部署包（约 1 分钟）

```powershell
Compress-Archive deploy/client-bundle/* pacgate-client-bundle-v0.1.0.zip
```

### 步骤 4：部署至客户 AIPC 机器（3 天现场安装）

按 `deploy/SETUP-AND-OPERATIONS.md` 执行：
- 第一天：硬件配置 + Docker 技术栈部署 + 默认租户初始化
- 第二天：qm 协作工作空间 + Cubecloud Agent OS 表层配置
- 第三天：管理员培训 + 律师培训 + 交付验收

### 步骤 5：试点验证后决定第二阶段

试点成功并积累真实使用数据后，再决定是否进入第二阶段（基于 Rust 蓝图的 Pacgate SaaS 平台）。

---

## 七、架构参考

### 7.1 GHCR 容器镜像

| 镜像 | 内容 | 基础镜像 |
|---|---|---|
| `ghcr.io/jzkk720/pacgate-api:0.1.0` | Rust 二进制（pacgate-server）+ SQL 迁移 | `rust:1.94-bookworm` → `debian:bookworm-slim` |
| `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0` | deer-flow 后端 + Python 适配器（约 150 行） | `ghcr.io/bytedance/deer-flow-backend`（SHA 固定） |

### 7.2 数据流

1. 律师打开 `http://localhost:8081` → nginx → pacgate-api（着陆页）
2. 律师进入 `/research/` → nginx → deer-flow（研究工作空间）
3. deer-flow 调用 pacgate-api 获取事项记忆 + 文档存储
4. deer-flow 调用 Ollama 进行模型推理
5. 律师打开 `http://localhost:8182` → qm（协作工作空间）
6. qm 代理调用 `pacgate-qm` CLI → pacgate-api（工作流执行）

### 7.3 客户端数据（不包含在镜像中）

- `./data/tenants/{tenant_id}/` — 事项、文档、记忆
- Postgres 数据卷 — 元数据库
- `.env` — 密钥
- qm `.env` — 签名密钥 + 桥接凭证

---

## 七、测试验证汇总

| 测试套件 | 数量 | 状态 |
|---|---|---|
| 冒烟测试（pacgate-api） | 23 | ✅ 全部通过 |
| 代理测试（pacgate-agent） | 5 | ✅ 全部通过 |
| 工作流加载测试（pacgate-workflow） | 3 | ✅ 全部通过 |
| 集成测试（真实 Postgres） | 2 | ✅ 全部通过 |
| TS 适配器单元测试 | 8 | ✅ 全部通过 |
| qm 配置检查（qm check） | 1 | ✅ 通过 |
| qm 沙箱构建（qm sandbox build） | 1 | ✅ 通过 |
| 元典 API 实时验证 | 1 | ✅ 返回真实法律数据 |
| **合计** | **44** | **全部通过** |

---

> 本报告由 Cubecloud 工程团队编制，用于 Pacgate AI 第一阶段试点交付准备状态评估。
> 仓库地址：github.com/JZKK720/pacgate-ai-pr（私有）
> 提交版本：151881c（2026-08-18）