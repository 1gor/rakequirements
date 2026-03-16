Based on reading all three files, here is my concrete recommendation as a knowledge engineer.

## File Structure Reality Check

Your documents break down as follows: 

| File | Size | Role in the task |
|---|---|---|
| `participants.jsonl` | ~2.6k chars | 12 participant types (P-01.1 → P-05.2), small and clean |
| `KBP1_opis.md` | ~53k chars | Full BPMN table with ~100+ steps, actors column, timing, descriptions |
| `processes.jsonl` | ~71k chars | Catalog of ALL processes (KBP1–KBP30+, TBP1–TBP102+) — only a fraction relevant to KBP1 |

## Recommendation: 3-Step Pipeline

A single run will reliably fail here — not due to context window limits, but because you're asking the model to simultaneously **extract structure**, **validate mappings**, and **generate creative content**. These are cognitively distinct modes that compete for attention. The intermediate artifacts are also unverifiable. Here's the optimal split:

### Step 1 — Role Extraction + Participant Mapping
**Input:** `KBP1_opis.md` (actors column only) + `participants.jsonl`

Extract the unique actor names from the step table (you already have them: Истец, Ответчик, Канцелярия, Судья, Помощник судьи, Иные ЛУВД, Система) and map each to a participant code. Output: `roles_mapping.jsonl`.

This is a pure structured-extraction task. It's deterministic, verifiable, and you can correct errors before they propagate. 

### Step 2 — Pre-filter `processes.jsonl`
**Important:** Do not feed the full 71k `processes.jsonl` to any LLM prompt. The KBP1 opis references specific TBPs (TBP7, TBP31, TBP53, TBP65, TBP66–TBP91, etc.). Pre-filter to only those TBP entries relevant to KBP1 before any LLM call — this reduces noise significantly and keeps the prompt tight. 

### Step 3 — User Story Generation
**Input:** `roles_mapping.jsonl` (verified in Step 1) + `KBP1_opis.md` (full, for context including timing and descriptions) + filtered TBPs

Now the model has a **fixed list of roles** it cannot hallucinate away from, and full process context to derive the **Возможность** and **Цель/Результат** components accurately.

## Why Not Single Run

- Extraction + mapping + generation is three instruction modes; quality of each degrades when combined
- If a role is hallucinated or mis-mapped in step 1, every user story for that role is wrong — with no checkpoint to catch it
- The `processes.jsonl` catalog at 71k chars is mostly noise for KBP1; feeding it unfiltered wastes context and introduces confusion

## Why Not Steps Table Only

The `КBP1_opis.md` description column (Описание процесса) contains the **"почему"** — the business rationale behind each step — which directly maps to the **Цель/Результат** component of user stories. Stripping it out would produce shallow, formulaic stories. Keep the full opis for Step 3. 

## Quick Reference: What Goes In Each Prompt

```
Step 1:  participants.jsonl + KBP1_opis.md  →  roles_mapping.jsonl
Step 2:  (offline) filter processes.jsonl   →  relevant_tbps.jsonl  
Step 3:  roles_mapping.jsonl + KBP1_opis.md + relevant_tbps.jsonl  →  user_stories.jsonl
```

This gives you a clean audit trail, a human review gate between steps, and focused prompts that each do one thing well.
