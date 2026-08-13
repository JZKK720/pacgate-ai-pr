# Analysis Report Schema

Use this shape for each question entry unless the user asks for a different format.

## Required Fields Per Question

- `id`: stable question identifier
- `section`: source section or topic cluster
- `question`: original or normalized question text
- `category`: `Valid`, `Irrelevant`, `Error`, or `Needs Clarification`
- `priority`: `High`, `Medium`, or `Low`
- `why_it_matters`: short explanation of business or delivery impact
- `proposal_relation`: how this question maps to the actual proposal scope
- `direct_answer`: concise factual answer or correction
- `recommended_client_response`: the wording direction we should send back
- `research_needed`: `yes` or `no`
- `research_note`: source or validation note when research is used
- `next_action`: what should happen next in the workboard

## Recommended Summary Sections

- questions that materially affect decision-making
- client misunderstandings that should be corrected early
- questions that reveal scope creep attempts
- points where the proposal text itself may need clarification later