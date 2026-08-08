# Governing an AI agent with one `policy.yaml`

A working demo of Microsoft's [Agent Governance Toolkit](https://github.com/microsoft/agent-governance-toolkit)
(public preview, Aug 2026) applied to a real LangGraph agent and the same
policy applied unchanged to a CrewAI crew.

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

## Two integration styles

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
