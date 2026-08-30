# Pacgate Law — Staff Handbook

> How to use your firm's AI assistant, in plain language.
> For attorneys, paralegals, secretaries, and partners. No technical knowledge needed.
> Version 1.0 — 2026-08-30
> 中文版本：[PACGATE-LAW-STAFF-HANDBOOK-ZH.md](PACGATE-LAW-STAFF-HANDBOOK-ZH.md)

---

## 1. What this system is

Pacgate Law has an AI assistant that helps with legal research, contract review, document drafting, and team collaboration. It runs on a dedicated **AI computer in your office** — a quiet machine on a shelf or in the IT room, not something in "the cloud."

You use it from your normal web browser. Nothing needs to be installed on your laptop.

There are two ways to work with it:

| Workspace | Use it for | Example |
|---|---|---|
| **Research** | Asking questions, analyzing documents, producing drafted memos and reports | "Review this NDA for clauses unusual under PRC law and draft a redline memo." |
| **Team** | Sharing work with colleagues, approving actions, moving documents through your matter teams | "Share this research memo with the deal team and ask for partner sign-off." |

Both workspaces see the same matters and the same documents. Think of them as two doors into one filing system.

![Two doors, one filing system](diagrams/svg/user-01-two-doors.png)

---

## 2. Your first time

1. Open Chrome or Edge.
2. Go to the address your IT administrator gave you (it looks like `http://192.168.x.x:8081`).
3. Sign in with the email and password your administrator set up for you.
4. Pick a workspace. You'll be asked to choose or create a **matter** — see next section.

If your password doesn't work, or you've never received one, contact your firm administrator. There is no self-service password reset in this system yet.

---

## 3. Matters: everything belongs to one

A **matter** is any case, deal, or engagement your firm works on — a litigation file, an M&A transaction, a patent application.

- Every document you upload, every research question you ask, and every AI answer you receive is filed **inside one matter**. Nothing floats free.
- You will only see the matters you are assigned to. If a matter you expect is missing, that is your administrator's assignment setting, not a bug.
- Some matters are **walled off** (ethical walls / conflict checks). Colleagues outside the wall cannot see the matter exists. This is enforced automatically.

**Good practice:** before uploading anything, check you have the right matter selected. The AI answers in the context of the matter you chose — its memory of your firm's documents is scoped to it.

---

## 4. The Research workspace

### 4.1 Asking a question

Type it the way you would ask a very fast junior associate:

> "Summarize recent force majeure case law in China relevant to a supply contract, with citations."

Press Enter. The assistant works in visible steps — searching your firm's documents, reading them, cross-checking — and writes its answer back in the chat. A quick question takes seconds. A full research task can take **2 to 10 minutes**. It is working, not stuck. You can leave the page and come back.

### 4.2 Reading the answer: citations

![How an answer is generated](diagrams/svg/user-02-answer-flow.png)

Every factual claim the assistant makes carries a numbered citation like `[1]`. **Click it** and the source document opens at the exact page, with the quoted passage highlighted.

This is the core rule of the system: **if the AI says it, you can trace it.** If a citation doesn't match what you expect, say so in the chat ("that citation is wrong, the clause is on page 15") — the assistant corrects itself and remembers.

### 4.3 Uploading documents

Drag a file into the chat, or click the attachment button. Word documents, PDFs, and text files are all fine. The document is stored in your matter, and the assistant can now quote, compare, and analyze it alongside everything else in that matter.

### 4.4 Getting a document out

Ask for what you want shaped like a document:

> "Draft a contract review memo in Word format based on the analysis above."

The assistant produces a real `.docx` file. It appears in the **artifacts panel** on the right of the chat — click to preview or download. Every document keeps its history: if it's edited later, the old versions stay available.

### 4.5 What it's good at (and what it isn't)

Strong: reading large volumes of your own documents, extracting terms into tables, comparing versions, first drafts of memos, research with traceable citations.

Not a substitute for: your judgment, your signature, or your malpractice carrier. The assistant is a drafting and research engine. **You are the lawyer.** Review every citation before it leaves the firm.

---

## 5. The Team workspace

### 5.1 Sharing a document

1. Open (or start) a session on the matter.
2. Attach the document, or pick one already in the matter.
3. Choose who sees it: specific colleagues, the whole matter team, or a practice group.
4. Choose **view only** or **can edit**, then share.

### 5.2 Approvals

When the assistant wants to take an action that touches other people's work — "I'll generate the review report and distribute it to the deal team" — it stops and shows an **approval card** first. Read it, then click **Approve** or **Reject** (with a note). Nothing happens on someone else's matter without a human approving it.

---

## 6. Privacy: what stays in the building, and what doesn't

This is the section your IT and compliance teams will ask about, so here is the honest picture.

![What stays in the building, and what is sent](diagrams/svg/user-03-privacy-split.png)

### Stays inside your office, on the AI computer

- Every document you upload, generate, or edit
- Every matter file, client data, and the AI's extracted memory of your work
- The knowledge base and search index
- Your full activity history and audit trail

None of this is copied to any cloud service. There is no firm account on any external storage.

### Sent to the AI service when you ask a question

- The text of your question and the specific passages the assistant reads to answer it are processed by the AI model service your firm has enabled, so that answers come back fast and at high quality.
- Your documents themselves are not uploaded there — only the working text of the conversation.

The balance (office-only storage, hosted intelligence) was chosen deliberately for speed and quality of research output. If your client matters require zero external processing of any kind, tell your firm administrator before using the system on that matter.

---

## 7. If something goes wrong

| Symptom | What to do |
|---|---|
| Page won't open at all | The AI computer may be restarting. Wait 5 minutes. If still down, call your IT administrator. |
| Answer is taking a long time | Normal for research tasks. Check back in 10 minutes. |
| "Matter not found" | You're not assigned to it. Ask your administrator. |
| A citation doesn't match | Tell the assistant in the chat; it will correct itself. |
| Password not working | Contact your firm administrator. |
| You shared something to the wrong people | Tell your administrator immediately — they can revoke access. |

Your data is never lost by a crash or an update. The system keeps everything on the AI computer's own disk, and updates never touch your documents or matters.

---

## 8. Ten-second etiquette

1. Pick the right matter before you start.
2. Ask in plain language; you don't need special prompts.
3. Click the citations. Always.
4. Use the Team workspace to share — not email attachments.
5. Approvals exist for a reason: read them before clicking.
6. If the machine is working on something big, be patient — or come back.
7. When in doubt about whether something is confidential enough to ask, ask your administrator.

---

*Questions about this handbook, or suggestions for it, go to your firm administrator.*
