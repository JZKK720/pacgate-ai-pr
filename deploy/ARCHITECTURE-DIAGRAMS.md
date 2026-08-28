# Pacgate-ai Architecture Diagram

> Render this file in any Markdown viewer that supports Mermaid (GitHub, VS Code, Obsidian)
> Or paste the mermaid block into https://mermaid.live for a PNG/SVG export

## System overview

```mermaid
graph TB
    subgraph Client["Client AI PC (Docker Compose)"]
        direction TB

        NGINX["nginx :8081<br/>reverse proxy<br/>single entry point"]

        subgraph Spine["Metadata Spine (Cubecloud GHCR images)"]
            direction LR
            API["pacgate-api<br/>Rust / Axum :8080<br/>HTTP gateway"]
            DOCX["pacgate-docx<br/>OOXML engine"]
            RAG["pacgate-rag<br/>pgvector + tsvector"]
            LLM["pacgate-llm<br/>3-tier router"]
            AUTH["pacgate-auth<br/>+ pacgate-tenant<br/>JWT / OIDC / scopes"]
            API --> DOCX
            API --> RAG
            API --> LLM
            API --> AUTH
        end

        subgraph Research["Research Runtime"]
            DF["deer-flow backend<br/>LangGraph :8001"]
            DFA["pacgate_deerflow_adapter<br/>Python ~150 lines"]
            DF --> DFA
            DFA -->|HTTP| API
        end

        subgraph Collab["Collaboration Runtime"]
            QM["qm core<br/>Deno/Node :8765"]
            QMA["pacgate_qm_adapter<br/>TypeScript ~200 lines"]
            QM --> QMA
            QMA -->|HTTP| API
        end

        subgraph Local["Local Fallback Runtime"]
            AGENT["pacgate-agent<br/>AgentLoop + ToolDispatcher<br/>10-tool architecture"]
            AGENT -->|direct call| DOCX
            AGENT -->|direct call| RAG
        end

        DB[("Postgres 16<br/>pacgate-db")]
        OV["OpenViking :1933<br/>context database<br/>memory lane (MCP)"]
        DATA["./data/tenants/<br/>{tenant_id}/<br/>matters/ persona/<br/>workflows/ kb/"]
        OVDATA["./openviking/<br/>conversational memory<br/>(client-owned volume)"]
    end

    OLLAMA["Ollama<br/>native :11434<br/>GPU / NPU"]

    NGINX -->|"/research/"| DF
    NGINX -->|"/collab/"| QM
    NGINX -->|"/api/"| API

    DF -.->|"MCP: recall"| OV
    QM -.->|"MCP: remember/search/read"| OV

    AUTH --> DB
    API --> DB
    DF -.->|host.docker.internal| OLLAMA
    QM -.->|host.docker.internal| OLLAMA
    LLM -.->|host.docker.internal| OLLAMA
    OV -.->|embedding + VLM| OLLAMA

    DATA -->|volume mount| API
    DATA -->|volume mount| DF
    DATA -->|volume mount| QM
    OVDATA -->|volume mount| OV
```

## Deployment flow

```mermaid
graph LR
    subgraph Dev["Cubecloud dev machine"]
        SRC["pacgate-ai/ source<br/>+ adapters/"]
        BUILD["docker build<br/>3 wrapper Dockerfiles"]
    end

    subgraph GHCR["GHCR (jzkk720)"]
        IMG1["pacgate-api:0.1.2"]
        IMG2["deer-flow-pacgate:0.1.0"]
        IMG3["qm-pacgate:0.1.0"]
    end

    subgraph Bundle["Client bundle (zip)"]
        COMPOSE["compose.prod.yaml"]
        NGINX_CONF["nginx/default.conf"]
        INSTALL["install.ps1"]
        ENV[".env.example"]
        MODELS["ollama-models.txt"]
        README["README-client.md"]
    end

    subgraph Client["Client AI PC"]
        RUN["docker compose up<br/>3 containers + nginx + postgres"]
        CLIENT_DATA["./data/tenants/<br/>(client's data, volume)"]
    end

    SRC --> BUILD
    BUILD -->|push| IMG1
    BUILD -->|push| IMG2
    BUILD -->|push| IMG3

    COMPOSE -->|references| IMG1
    COMPOSE -->|references| IMG2
    COMPOSE -->|references| IMG3

    Bundle -->|transfer zip| Client
    INSTALL -->|runs| RUN
    RUN -->|pulls| IMG1
    RUN -->|pulls| IMG2
    RUN -->|pulls| IMG3
    RUN -->|mounts| CLIENT_DATA
```

## Ownership and data boundaries

```mermaid
graph TB
    subgraph Cubecloud["Cubecloud (code owner)"]
        REPO["github.com/jzkk720/pacgate-ai<br/>(your repo)"]
        GHCR["GHCR images<br/>pacgate-api, deer-flow-pacgate, qm-pacgate"]
        SCOPE["scope-assets/<br/>(your business materials)<br/>NEVER shipped to client"]
        REPO --> GHCR
    end

    subgraph Upstream["Upstream repos (never forked)"]
        DF_UP["bytedance/deer-flow"]
        QM_UP["yc-software/qm"]
        OV_UP["volcengine/OpenViking<br/>(AGPL-3.0, unmodified side-car)"]
    end

    subgraph Client["Client AI PC (data owner)"]
        IMAGES["Docker images<br/>(pinned versions from GHCR)"]
        DATA["./data/tenants/{tenant_id}/<br/>matters, documents, memory<br/>persona, workflows, kb"]
        PG["Postgres volume<br/>(client's database)"]
    end

    GHCR -->|pull| IMAGES
    DF_UP -->|base image| GHCR
    QM_UP -->|base image| GHCR

    REPO -.->|build + push| GHCR
    SCOPE -.->|stays local| Cubecloud

    IMAGES -->|run, volume mount| DATA
    IMAGES -->|run, volume mount| PG

    style Cubecloud fill:#e1f5e1
    style Client fill:#e1f0f5
    style Upstream fill:#f5f0e1
```

## Update lifecycle

```mermaid
sequenceDiagram
    participant U as Upstream (deer-flow/qm)
    participant C as Cubecloud
    participant G as GHCR
    participant Cl as Client AI PC

    U->>C: New release (e.g., deer-flow v2.2.0)
    C->>C: Evaluate changelog (quarterly or on security fix)
    C->>C: Test on dev machine (compose.yaml, source build)
    C->>C: Bump FROM line in wrapper Dockerfile
    C->>G: docker build + push (new version tag)
    C->>Cl: "Update available — run install.ps1 -Update"
    Cl->>G: docker compose pull (new pinned version)
    Cl->>Cl: docker compose up -d (restart containers)
    Note over Cl: ./data/tenants/ preserved<br/>(volume, not in image)
    Note over Cl: Postgres data preserved<br/>(named volume)
    Note over Cl: Client's customizations intact
```

## Scope model mapping

```mermaid
graph LR
    subgraph Pacgate["pacgate-ai Rust types"]
        TID["TenantId<br/>(law firm)"]
        MID["MatterId<br/>(legal case)"]
        UID["UserId<br/>(attorney)"]
        PAID["PracticeArea<br/>(M&A, litigation, IP...)"]
    end

    subgraph QM["qm ScopeId"]
        ORG["org:default-org"]
        CHAN["channel:C1"]
        PERS["personal:U1"]
        TEAM["team:m-and-a"]
    end

    subgraph Path["File path"]
        TP["tenants/{tenant_id}/"]
        MP["matters/{matter_id}/"]
        UP["users/{user_id}/"]
        TG["teams/{practice_area}/"]
    end

    TID --- ORG
    TID --- TP
    MID --- CHAN
    MID --- MP
    UID --- PERS
    UID --- UP
    PAID --- TEAM
    PAID --- TG

    style Pacgate fill:#e1f5e1
    style QM fill:#e1f0f5
    style Path fill:#f5f0e1
```