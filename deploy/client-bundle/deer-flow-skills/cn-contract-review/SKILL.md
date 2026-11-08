---
name: cn-contract-review
description: Review a commercial contract from a specified party's position under Chinese law, run the firm's review workflow when one matches, and produce a clause-by-clause risk table with redlines. Use for 合同审阅, 合同审查, or when a user asks whether a contract is safe to sign.
---

<!-- Pacgate 2026-10-30: no `allowed-tools` on purpose - see cn-nda-review for the
     measured reason (union semantics amputate the surface; a scalar is rejected
     by the loader outright). -->

# Commercial contract review - Chinese law

Two paths, and choosing correctly is the whole skill:

- **A workflow template already covers this contract type.** Run it. The firm's
  220+ templates encode the review dimensions its lawyers actually use, and a
  generic review is worse than a template run.
- **No template matches.** Do the manual review below.

Never do both for the same document. A template run followed by a manual pass
produces two overlapping risk tables and the user cannot tell which to trust.

## Step 1 - establish position and scope

Ask, via `ask_clarification`, if not already clear:
- **Which side are we?** 买方/卖方, 出租方/承租方, 委托方/受托方, 发包方/承包方,
  投资人/公司/创始人. Every risk call depends on this. Never default to "neutral
  review" - that produces a checklist with no positions, which is useless.
- **What kind of contract?** (买卖、租赁、服务、承揽、股权转让、增资、借款、保密、
  劳动、许可...)

## Step 2 - find a matching workflow

```
pacgate_pacgate_list_workflows(search="<contract type in Chinese>")
```

Categories that carry contract review: `contract_review`, `investment_financing`,
`ma_due_diligence`, `banking_general`, `capital_markets`, `compliance_corporate`.

If one matches, inspect before running:

```
pacgate_pacgate_get_workflow(workflow_id="<id>")
```

Read the `steps` - note that a template's `steps` reference *internal* tool names
(`read_document`, `find_in_document`, `generate_docx`) executed by pacgate-api
itself, **not** tools you call. Then execute:

```
pacgate_pacgate_execute_workflow(workflow_id="<id>", matter_id="<matter>")
```

Relay the per-step `content` and `citations` back to the user. Do not paraphrase
away the citations - they are the point.

If nothing matches, continue to Step 3.

## Step 3 - manual review

Read with `pacgate_pacgate_read_document` (convert first with
`pacgate_pacgate_convert_document` if binary). Then cover:

**形式 (form)** - 合同名称与内容是否匹配; 当事人信息/主体资格是否完整; 签约日期与
生效条件; 附件清单; 签署页与骑缝.

**实质 (substance)** - 定义条款; 标的描述的明确性; 数量与质量标准; 价款与支付节点;
交付与验收; 双方权利义务的对等性; 违约责任(情形是否穷尽、违约金计算、与解除的关系);
合同解除与清算; 不可抗力; 保密; 知识产权归属与许可; 争议解决(管辖法院/仲裁机构);
合同期限与续签; 通知与送达.

**我方特殊关注点** - driven by position from Step 1. A 承租方 cares about 押金退还
and 提前解约; a 投资人 cares about 对赌 and 回购; a 买方 cares about 质量异议期.

## Step 4 - output

| 条款号 | 条款标题 | 风险等级 | 风险描述 | 修改建议 | 修改后文本 |
|--------|----------|----------|----------|----------|------------|

**高** = 必须修改方可签署 · **中** = 建议谈判 · **低** = 可接受，备注留档.

Follow with an overall assessment: the two or three issues that actually decide
whether to sign, stated plainly. A 40-row table where everything is 中 is a
non-answer.

## Research reality

`pacgate_pacgate_kb_search` searches the firm's own corpus and **works**. Use it
for house positions and precedent clauses:

```
pacgate_pacgate_kb_search(query="违约金 调整 司法实践", matter_id="<matter>")
```

`pacgate_pacgate_connector_search` (external 北大法宝 / 元典 / 企查查 etc.)
returns `[]` on this deployment - the Chinese connectors have no API keys and
there is no outbound TLS. Check `pacgate_pacgate_list_connectors` if unsure.
Never claim a statute was verified against an external database. Mark anything
not found in the corpus as **需律师核验**.

## Boundaries

- Output is a **draft for lawyer review**, not a client deliverable.
- Do not invent clause numbers, statute articles, or case citations.
- Do not execute a workflow against a matter the user has not identified; a run
  writes into that matter's record.

## Improving this skill

If a contract type keeps needing a dimension this checklist lacks, add it via
`skill_manage` action `patch`. If it recurs across matters, tell the user it may
be worth a workflow template in pacgate-api instead - a template is shared and
versioned; a skill is prose.
