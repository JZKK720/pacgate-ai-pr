---
name: pacgate-qa-workboard
description: 'Run the Pacgate clarification workflow for client question rounds. Use for converting question forms to markdown, classifying valid versus irrelevant questions, identifying client misunderstandings, building suggested responses with research notes, and planning a temporary HTML/Kanban/PDF workboard that stays outside production proposal and onboarding surfaces.'
argument-hint: 'Describe the source question file or notes, the proposal surface being clarified, and whether you need markdown conversion, question analysis, workboard planning, or all three.'
user-invocable: true
---

# Pacgate Q&A Workboard

Use this skill for the clarification workflow that follows a client feedback round on the Pacgate proposal.

This skill is for working material, not public product surfaces.

## What This Skill Produces

The workflow should aim to produce three linked artifacts:

1. A markdown representation of the source questions
2. An analysis report that classifies and responds to each question
3. A temporary workboard plan or implementation concept for HTML, Kanban, and PDF outputs

Load [artifact requirements](./references/artifact-requirements.md) before finalizing output.

## When To Use

- Client sends clarification questions after a proposal round
- A question form must be converted into markdown for review
- Questions need triage into relevant, irrelevant, mistaken, or incomplete categories
- Responses need more than direct answers and should include pushback, correction, or evidence
- A temporary Q&A board must be planned for ongoing feedback rounds

## Core Boundary

- The Q&A layer is strictly a working-in-progress tool for internal and client communication during the feedback cycle.
- It must stay outside the public proposal index, onboarding flow, and committed production scope unless the user explicitly changes that decision.

## Workflow

### Step 1: Normalize The Input

- Convert the source form into structured markdown.
- Preserve question numbering, section grouping, and any client wording that may signal misunderstanding or scope drift.
- If extraction is lossy or uncertain, flag the ambiguity instead of guessing.

### Step 2: Triage Each Question

Classify every question using one primary status:

- `Valid` - directly relevant and answerable within the proposal context
- `Irrelevant` - outside the proposed scope or tied to a different solution shape
- `Error` - based on a factual misunderstanding, false assumption, or misread proposal detail
- `Needs Clarification` - too ambiguous to answer cleanly without a follow-up question

Then assign a handling priority:

- `High` - affects scope, commercial terms, architecture, delivery confidence, or buying decision
- `Medium` - matters for understanding but is not decision-critical
- `Low` - useful to answer later or roll into a broader clarification pack

## Step 3: Build The Analysis Report

For each question, produce the fields defined in [analysis report schema](./references/analysis-report-schema.md).

At minimum, each question entry should contain:

- source question
- category and priority
- why the question matters or does not matter
- direct answer or corrective response
- suggested response framing for the client
- notes on whether internet research is needed to support the answer

## Step 4: Add Research Where It Actually Helps

- Research is for validating technical and commercial claims against current market or implementation reality.
- Do not research every question by default. Focus on questions where external grounding strengthens the response or counters a mistaken assumption.
- If a question is irrelevant to the proposal, say so clearly instead of padding the answer with unnecessary research.
- If a question contains a factual error, correct it plainly and explain the consequence for scope or expectations.

## Step 5: Shape The Temporary Workboard

Default recommendation:

- Kanban tooling: self-contained HTML and JavaScript component, not a third-party board dependency
- persistence: local JSON file
- outputs: browser-readable HTML plus exportable PDF-friendly structure

The workboard should normally include lanes such as:

- `Inbox`
- `Triaged`
- `Needs Research`
- `Draft Response`
- `Ready To Send`
- `Deferred / Out Of Scope`

Use [workboard architecture notes](./references/workboard-architecture.md) for the board structure and output expectations.

## Step 6: Verify Before Finishing

Use the verification checklist in [verification checklist](./references/verification-checklist.md).

The workflow is not done until all three of these pass:

1. Markdown Output - the converted question set is complete and reviewable
2. Analysis Report - each question has a category, response direction, and evidence note when needed
3. Design Mockup / Workboard Plan - the temporary HTML, Kanban, and PDF approach is coherent and clearly non-production

## Output Style

- Keep the tone analytical and commercially grounded.
- Push back when a client question conflicts with the actual proposal.
- Prefer precise, reviewable tables or structured lists over loose narrative when handling many questions.
- Separate what is committed scope from what is optional suggestion.

## Anti-Patterns

- answering every question as if the client is automatically correct
- treating out-of-scope questions as accepted scope
- hiding mistaken assumptions inside vague diplomatic wording
- designing the workboard as if it is a public-facing feature
- using a third-party Kanban dependency before a simple static HTML board has been evaluated
- storing temporary workflow data in a heavyweight database before a local JSON model has been proven necessary

## Done Criteria

- The question form is available in markdown.
- The analysis report clearly distinguishes valid, irrelevant, mistaken, and ambiguous questions.
- The workboard plan is explicitly temporary, export-friendly, and separate from production surfaces.
- The recommended board implementation remains self-contained unless the user asks for a more complex stack.