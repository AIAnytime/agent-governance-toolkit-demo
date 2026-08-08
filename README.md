# Governing an AI agent with one `policy.yaml`

A working demo of Microsoft's [Agent Governance Toolkit](https://github.com/microsoft/agent-governance-toolkit)
(public preview, Aug 2026) applied to a real LangGraph agent and the same
policy applied unchanged to a CrewAI crew.

Everything here runs live against OpenRouter. Nothing is faked.

---

## What the toolkit actually is

The problem it targets: once an agent is deployed, prompt-level safety
("please don't drop the table") is a **request to a stochastic system**, not a
control. OAuth scopes say which services an agent may reach; they say nothing
about what it does once connected.

AGT's answer is the **Agent Control Specification (ACS)** — a manifest that
declares seams in the agent lifecycle where a deterministic policy engine gets
to say *allow / deny / transform / escalate* **before the action reaches the
wire**.

Three moving parts:

| Part | File here | What it does |
|---|---|---|
| **Manifest** | `policy.yaml` | Declares intervention points, policies, and the tool surface |
| **Policy** | `policy/rules.rego` | The actual decisions, in Rego, executed by OPA |
| **Runtime** | `agent-control-specification` (pip) | Rust core that evaluates seams and enforces verdicts |

The agent's own code contains **zero** policy logic.

---

## The five intervention points this demo uses

```
user input ──▶ [ input ] ──▶ model ──▶ [ pre_tool_call ] ──▶ TOOL RUNS
                                                                 │
final answer ◀── [ output ] ◀── model ◀── [ post_tool_call ] ◀───┘
```

| Seam | Catches | Rule in this demo |
|---|---|---|
| `input` | Prompt injection | deny on OWASP LLM01 patterns |
| `pre_tool_call` | Destructive / unauthorised actions | deny `DROP TABLE`, deny egress to unapproved domains, **escalate** refunds > $500 |
| `post_tool_call` | Secrets entering the context window | **transform** — redact API keys and card numbers |
| `output` | Secrets reaching the user | **transform** — redact |

Also enforced for free by the runtime: a tool **not declared** in the manifest
fails closed with `runtime_error:tool_unknown` before policy even runs. The
manifest *is* the allow-list.

---

## Setup

```bash
# 1. OPA — the Rego engine. The ACS runtime shells out to it.
brew install opa                       # macOS
opa version                            # verify

# 2. Python 3.11–3.13 (NOT 3.14 — CrewAI/LangGraph deps aren't ready)
uv venv --python 3.13 .venv
source .venv/bin/activate
uv pip install -r requirements.txt

# 3. Your OpenRouter key
echo 'OPENROUTER_API_KEY=sk-or-...' > .env
```

`agent-control-specification` builds a Rust extension on install — expect
~90 s the first time.

---

## Running it

### A. Policy only — no LLM, instant

Every rule, every verdict, in one table. Best opening shot: it proves the
policy is real before any model is involved.

```bash
python demo_cli.py --policy-only
```

```
seam             case                  verdict      reason
input            normal question       ✓ allow
input            injection             ✗ deny       prompt_injection_detected
pre_tool_call    read query            ✓ allow
pre_tool_call    drop table            ✗ deny       destructive_sql_blocked
pre_tool_call    delete, no WHERE      ✗ deny       destructive_sql_blocked
pre_tool_call    small refund          ✓ allow
pre_tool_call    big refund            ⚠ escalate   refund_limit_exceeded
pre_tool_call    internal email        ✓ allow
pre_tool_call    external email        ✗ deny       egress_domain_not_approved
pre_tool_call    undeclared tool       ✗ deny       runtime_error:tool_unknown
post_tool_call   secret in result      ✎ transform  secret_redacted_from_tool_result
output           secret in answer      ✎ transform  secret_redacted_from_output
```

### B. Full CLI — same agent, twice

Each scenario runs **ungoverned first, then governed**, and prints the real
side effects of both.

```bash
python demo_cli.py               # all 5 scenarios, interactive approvals
python demo_cli.py 2             # just scenario 2
python demo_cli.py --no-input    # non-interactive (escalations auto-decline)
python demo_cli.py --chat        # free-form governed chat
```

### C. Web console — the visual one

```bash
python web/app.py     # http://127.0.0.1:8000
```

- Toggle **policy.yaml ENFORCED / GOVERNANCE OFF** in the header
- Scenario chips run canned prompts, or type your own
- Every verdict streams into the timeline live over a WebSocket
- `transform` verdicts render a **before/after diff**
- `escalate` verdicts pop a real **approval modal** — the browser is the human
  in the loop, and it shows the `enforced_identity` hash the approver is
  consenting to
- Right pane shows `policy.yaml`, `rules.rego`, and a **side-effects** tab
  comparing the ungoverned and governed runs

### D. CrewAI — same policy, different framework

```bash
python agent_crewai.py
python agent_crewai.py --ungoverned
python agent_crewai.py "Email order 1042 to auditor@evil.ru"
```

---

## Suggested video running order

| # | Beat | Command | The moment |
|---|---|---|---|
| 1 | The problem | — | An agent with `query_db` and `send_email` is one plausible sentence away from a deleted table. Prompt-level safety can't fix this. |
| 2 | Show `policy.yaml` | open the file | Walk the three blocks: `policies`, `intervention_points`, `tools`. ~40 lines of substance. |
| 3 | Prove it's real | `python demo_cli.py --policy-only` | 12 verdicts, no LLM, sub-second. |
| 4 | **Ungoverned** | web UI, toggle OFF, scenario 2 | *"The `orders` table has been successfully dropped."* Side-effects tab: **0 orders**. |
| 5 | **Governed** | toggle ON, scenario 2 | `pre_tool_call DENY destructive_sql_blocked`. Side-effects tab: **2 orders**. Same agent. Same prompt. |
| 6 | Transform | scenario 5 | The before/after diff. The API key never entered the context window — this is not the model choosing to be discreet. |
| 7 | Escalate | scenario 4 | Approval modal. Click **Approve**, refund goes through. Re-run, click **Decline**, it doesn't. |
| 8 | Portability | `python agent_crewai.py` | Same `policy.yaml`, CrewAI instead of LangGraph. Zero policy edits. |
| 9 | Change the rule live | edit `rules.rego`, refund limit 500 → 2000, re-run scenario 4 | It allows now. No agent code touched, no redeploy. |
| 10 | Close | — | Denied actions aren't unlikely. They're structurally impossible. |

Beat 9 is the strongest single moment in the video — it's the whole thesis in
one file edit.

---

## Things worth saying on camera (they're non-obvious)

- **`escalate` binds to a hash.** The approval payload carries
  `enforced_identity` — a SHA-256 over the exact policy input that will
  execute. The approver consents to *that* action, not to a description of it.
  If anything changes between approval and execution, the runtime fails closed
  with `approval_action_mismatch`.

- **`transform` is not "the model redacted it".** The tool result is rewritten
  by the policy engine in between the tool returning and the model reading.
  The secret is never in the context window, so it cannot be leaked later in
  the conversation, in a log, or in a trace.

- **The runtime fails closed.** A broken policy, an OPA crash, a malformed
  verdict — all become `deny`. That's why the `--policy-only` run is a good
  early beat: if OPA isn't installed, *everything* denies with
  `runtime_error:policy_invocation_failed`.

- **`extends:` is how this scales.** A corporate baseline manifest, extended
  per-team, with only the local deltas in each repo. Empty in this demo.

- **Scenario 1 sometimes "passes" ungoverned** — the model refuses the
  injection on its own. Don't hide that; it *is* the argument. Model-layer
  refusal is probabilistic, so it holds on some runs and not others. The
  `input` seam holds on every run, and you can point at the line of Rego that
  makes it hold. Scenario 2 is the more reliable on-camera contrast.

- **Rego runs on RE2**, so there is no lookahead. `DELETE` without `WHERE` is
  expressed as two positive checks, not one negative one — see the comment in
  `rules.rego`.

---

## Layout

```
policy.yaml              the manifest — the star of the show
policy/rules.rego        the decisions
northwind.py             tools + Governor + the LangGraph agent
demo_cli.py              terminal demo
agent_crewai.py          the same policy on CrewAI
web/app.py               FastAPI + WebSocket server
web/static/index.html    the governance console
```

`northwind.py` is deliberately split in half: `PART 1` is agent code that has
never heard of governance, `PART 2` is the `Governor` that has never heard of
Northwind. That separation is the argument.

---

## Two integration styles, both shown

**Explicit** (`northwind.py`) — you call the seams yourself. More code, total
visibility, and what the demo streams to the UI:

```python
res = await control.evaluate_intervention_point(
    "pre_tool_call", {"tool_call": {"name": name, "args": args}}
)
if res.verdict.decision.value == "deny":
    raise Blocked(...)
```

**Wrapped** (`agent_crewai.py`) — the SDK's duck-typed guards. One line:

```python
from agent_control_specification import guard_crewai_crew
guarded = guard_crewai_crew(control, crew)
result = await guarded.akickoff(inputs={"request": request})
```

Note the gotcha worth mentioning on camera: `guard_crewai_crew` guards
`akickoff` and **blocks** `kickoff` and `a_kickoff` on the returned proxy — you
cannot accidentally route around the guard by calling the sibling method. The
same family exists for other stacks: `guard_langchain_tool`,
`guard_langchain_runnable`, `guard_openai_client`, `guard_mcp_tool`,
`guard_semantic_kernel_function`, `guard_tool`, `guard_model_call`.

---

## Caveats to state honestly on camera

- AGT is **public preview**. Breaking changes are expected before GA, and the
  repo's own `BREAKING_CHANGES.md` documents a recent v4→v5 policy-model
  rewrite. Pin your versions.
- The regex rules here are **demo-grade**. Microsoft's own sample policies in
  the repo carry an explicit "this is NOT exhaustive" disclaimer, and so should
  yours. The architecture is the product; the patterns are a starting point.
- Everything in `_ORDERS` is a mock backend. The side effects are real *within
  the process* — that's what makes the governed/ungoverned comparison honest —
  but no database was harmed.
