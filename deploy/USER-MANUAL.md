# Pacgate-ai User Manual

> For attorneys, paralegals, and partners at the law firm
> Version 0.1.0 — Phase 1 pilot

## What Pacgate-ai is

Pacgate-ai is your firm's private legal AI assistant. It runs on the AI PC in your office — your documents, your matters, and your research never leave your building. There is no cloud, no third-party server, no data sent to external APIs.

Pacgate-ai has **two working modes**, each for a different kind of task:

| Mode | What it's for | When to use it |
|---|---|---|
| **Research** | Deep legal research with citations, document analysis, contract review | "Research this jurisdiction's recent case law on X" |
| **Collaborate** | Share documents, approve workflows, distribute work to the team | "Share this contract draft with the M&A team for review" |

You switch between them by clicking a different link in your browser. Both run on the same AI PC; both see the same matters and documents.

---

## Getting started

### How to access

1. Open your web browser (Chrome, Edge, or Firefox)
2. Go to: **http://<your-ai-pc-ip>:8081**
   - Ask your IT person for the AI PC's IP address
   - If you're on the AI PC itself, use **http://localhost:8081**
3. You'll see the Pacgate-ai landing page with two options:
   - **"Research a matter"** → opens the research workspace
   - **"Collaborate on a matter"** → opens the collaboration workspace

### Logging in

Your IT administrator will give you:
- A username (usually your email)
- A password

Enter these on the login page. Your session stays active until you log out or close the browser.

---

## Mode 1: Research (deer-flow)

### What this mode does

The research workspace is for tasks that need deep analysis:

- **Legal research**: "Find recent case law on force majeure clauses in China mainland courts, with citations"
- **Contract review**: "Analyze this contract for unfavorable clauses and risk areas"
- **Document comparison**: "Compare these two contract versions and show what changed"
- **Tabular extraction**: "Extract all payment terms from these 10 contracts into a table"
- **Report generation**: "Research cross-border M&A precedent in Hong Kong and produce a cited memo"

### How to use it

1. Click **"Research a matter"** on the landing page
2. Select which **matter** you're working on (a dropdown of your firm's active matters)
3. Type your research question or task in the chat box
4. Press Enter or click Send
5. The AI will:
   - Break your request into steps
   - Search your firm's knowledge base and documents
   - Read and analyze the relevant files
   - Produce a structured response with **citations** to specific documents and pages
6. The response appears in the chat, with a panel on the right showing **artifacts** (files the AI produced)

### Understanding the response

- **Inline citations** look like `[1]`, `[2]` — click them to jump to the source document and page
- **Artifacts** (files produced by the AI) appear in the right panel — click to preview, download, or open
- **Tool calls** show what the AI did step-by-step (read document, search knowledge base, generate DOCX)

### Working with documents

**Upload a source document:**
- Drag a file into the chat, or click the attachment button
- Supported: `.docx`, `.pdf`, `.txt`, `.md`
- The document is stored under your matter's folder

**Generate a new document:**
- Ask: "Generate a contract review memo for matter M-001 based on the research above"
- The AI produces a `.docx` file via the document engine
- It appears as an artifact — click to download or preview

**Version history:**
- Every document has versions (v1, v2, v3...)
- Each edit or generation creates a new version
- You can view and download any previous version

### Research skills available

The research workspace comes with specialized legal skills:

| Skill | What it does |
|---|---|
| Deep Research | Multi-step research with source gathering and cross-checking |
| Systematic Literature Review | Structured review of legal literature and precedent |
| Academic Paper Review | Analyze and summarize legal academic papers |
| Consulting Analysis | Business/legal consulting frameworks |
| GitHub Deep Research | Analyze a codebase or technical repository |

The AI automatically selects the right skill based on your request. You don't need to choose manually.

---

## Mode 2: Collaborate (qm)

### What this mode does

The collaboration workspace is for working with your team:

- **Share documents**: "Share this contract draft with the M&A team"
- **Approve workflows**: Review and approve a document generation workflow before it runs
- **Distribute work**: "Send this research memo to all partners on matter M-001"
- **Track approvals**: See what's pending your approval and what you've approved

### How to use it

1. Click **"Collaborate on a matter"** on the landing page
2. You'll see your firm's collaboration dashboard
3. The left sidebar shows your **sessions** — each is a conversation about a specific matter or topic
4. The center is the chat area — type messages or attach files
5. The right panel shows **files** shared in this session

### Sharing documents

1. In a collaboration session, click the file/attachment button
2. Select a document from your matter (or upload a new one)
3. Choose who to share with:
   - **Specific people** (select attorneys from your firm)
   - **The matter team** (everyone on this matter)
   - **The practice group** (e.g., "all M&A attorneys")
4. Choose permission: **View only** or **Can edit**
5. Click Share

The people you shared with will see the document in their next collaboration session for that matter.

### Approving workflows

When the AI proposes an action that needs approval (e.g., "I'll generate a contract review report and share it with the team"):

1. You'll see an **approval card** in the chat
2. Review what the AI wants to do
3. Click **Approve** to let it proceed, or **Reject** with feedback
4. The AI only acts after you approve

### Ethical walls

Your firm's administrator can set **ethical walls** on specific matters. If a matter has an ethical wall:

- Only assigned attorneys can see that matter's documents
- The AI will not reference documents from a walled matter when working on other matters
- This prevents conflict-of-interest exposure

If you try to access a matter you're not assigned to, you'll see "Matter not found" — this is intentional, not an error.

---

## Matters and documents

### What is a matter?

A **matter** is a legal case, project, or engagement. Every document, research task, and collaboration session belongs to a matter. Matters belong to your firm (the tenant).

Your firm's matters might include:
- M-001: Smith v. Jones litigation
- M-002: Acme Corp M&A transaction
- M-003: Patent application #2026-XXX

### Document structure

Each matter has:
```
M-001 (matter)
├── Documents (versioned .docx, .pdf, .txt)
├── Uploads (source files you attach)
├── Memory (facts the AI extracted from your work)
└── Run history (what the AI did, when)
```

### Document versions

Every document is versioned:
- When the AI generates a document, it creates v1
- When you or the AI edits it, it creates v2, v3, etc.
- You can download or preview any version
- The current version is always the latest

### Citations

When the AI cites a source in its response:
- `[1]` means it's referencing a specific document and page
- Click the citation to open that document at the right page
- The verbatim quote (≤25 words) is shown alongside the citation

This is critical for legal work — every AI claim should be traceable to a source document.

---

## Personas

Pacgate-ai comes with legal **personas** — specialized AI assistants tuned for different practice areas:

| Persona | Practice area |
|---|---|
| M&A Partner | Mergers and acquisitions |
| Litigation Associate | Court proceedings, discovery |
| IP Counsel | Intellectual property |
| Compliance Officer | Regulatory compliance |
| Cross-border Advisor | International/cross-border matters |
| ... | 20 total, firm-customizable |

Your firm can customize personas or add new ones. Ask your administrator if you need a persona that doesn't exist yet.

---

## The three-tier model system

Pacgate-ai uses three model tiers for different tasks, all running locally on your AI PC:

| Tier | Model | Used for | Speed |
|---|---|---|---|
| **Main** | nemotron3:33b | Deep analysis, contract review, complex reasoning | Slower, most capable |
| **Mid** | qwen3.6:27b | Tabular review, batch extraction, structured output | Medium |
| **Low** | qwen3.5:9b | Titles, short summaries, quick labels | Fastest |

You don't choose the tier — the AI automatically picks the right model for each subtask. A quick label uses Low; a contract review uses Main.

Your firm's administrator can override which models are used for each tier (per-tenant model config).

---

## Privacy and security

### What stays on your machine

- **All documents** — uploaded, generated, and edited
- **All matter data** — case files, research, memory
- **All AI processing** — runs on the local AI PC's GPU/NPU
- **All collaboration** — shared within your firm's network only

### What never leaves your building

- No documents are sent to external APIs
- No matter data is uploaded to any cloud service
- The AI models run locally via Ollama on your AI PC
- The only external network access is for web search during research (if enabled by your administrator)

### Who can see what

- You can only see matters you're assigned to
- Documents are scoped to their matter
- Ethical walls prevent cross-matter data leakage
- Every document access and AI action is logged (audit trail)

---

## Frequently asked questions

### "The AI is slow"

Deep research tasks (Main tier) take longer because they run multiple steps: search, read, analyze, cross-check, generate. A full research report may take 2-5 minutes. Quick tasks (summaries, labels) take seconds. This is normal — quality takes time.

### "I don't see a matter I should have access to"

Contact your firm administrator. They control matter assignments and ethical walls. If you're not assigned to a matter, it won't appear in your list.

### "The AI cited something wrong"

Click the citation to open the source document. If the citation is inaccurate, tell the AI in the chat: "That citation is wrong — the correct page is 15, not 12." The AI will correct itself and update its memory for future tasks.

### "Can I edit a document the AI generated?"

Yes. Download the `.docx` artifact, edit it in Word, and re-upload it. It becomes a new version (v2, v3...). The AI can also edit documents directly if you ask it to.

### "How do I share my research with a colleague?"

1. In the research workspace, the AI produces an artifact (e.g., a research memo `.docx`)
2. Switch to the collaboration workspace
3. Start a session on the same matter
4. Share the document with your colleague

### "What if the AI PC goes down?"

Your data is safe — it's on the AI PC's disk, in a Docker volume. When the AI PC restarts, Docker Desktop auto-starts the containers (if configured), and all your matters, documents, and history are preserved. If you need help, contact your IT administrator.

### "How do I get a new version of the software?"

Your administrator will tell you when an update is available. They run a one-command update script. Your data is never affected by updates — only the software engine changes. All your matters, documents, and customizations are preserved.

---

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Enter | Send message |
| Shift+Enter | New line in message |
| Ctrl+K | Search matters/documents (if available) |
| Esc | Close artifact preview |

---

## Getting help

- **Technical issues** (can't log in, page won't load): Contact your firm's IT administrator
- **Feature requests** (want a new persona, new workflow template): Contact your firm's Pacgate-ai administrator
- **Training** (how to use research or collaboration effectively): Ask your administrator to arrange a session with Cubecloud support

---

## Glossary

| Term | Meaning |
|---|---|
| **Matter** | A legal case, project, or engagement |
| **Tenant** | Your law firm (the organization boundary) |
| **Artifact** | A file produced by the AI (e.g., a .docx research memo) |
| **Citation** | A reference to a specific document and page, shown as [1], [2] |
| **Persona** | A specialized AI assistant for a practice area (e.g., "M&A Partner") |
| **Ethical wall** | A restriction preventing certain attorneys from seeing a matter's data |
| **Tier** | The model capability level (Main/Mid/Low) used for a task |
| **Scope** | The access boundary for a matter or practice group |
| **Ollama** | The local AI model runner on your AI PC |