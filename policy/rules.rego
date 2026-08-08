# ─────────────────────────────────────────────────────────────────────────────
#  rules.rego — the actual decisions for the Northwind support agent.
#
#  Every rule receives one document, `input`, shaped by the ACS runtime:
#
#    input.intervention_point  -> "input" | "pre_tool_call" | "post_tool_call" | "output"
#    input.policy_target.value -> the thing the manifest exposed at this seam
#    input.tool_call.name      -> tool name (pre/post_tool_call only)
#    input.snapshot            -> the full runtime snapshot
#
#  Every rule returns one verdict:
#
#    {"decision": "allow"}
#    {"decision": "deny",      "reason": "...", "message": "..."}
#    {"decision": "escalate",  "reason": "...", "message": "..."}   -> human approval
#    {"decision": "transform", "reason": "...", "transform": {"path": "...", "value": ...}}
# ─────────────────────────────────────────────────────────────────────────────

package northwind

import rego.v1

# ── Fail-open defaults per seam. The RUNTIME fails closed on errors;
#    these defaults just mean "no rule matched -> nothing to complain about".
default verdict := {"decision": "allow"}
default input_verdict := {"decision": "allow"}
default pre_tool_call_verdict := {"decision": "allow"}
default post_tool_call_verdict := {"decision": "allow"}
default output_verdict := {"decision": "allow"}

# Generic dispatch entrypoint (used when a binding omits its own query).
verdict := input_verdict if input.intervention_point == "input"
verdict := pre_tool_call_verdict if input.intervention_point == "pre_tool_call"
verdict := post_tool_call_verdict if input.intervention_point == "post_tool_call"
verdict := output_verdict if input.intervention_point == "output"


# ═════════════════════════════════════════════════════════════════════════════
#  SEAM 1 — input:  block prompt injection before the model ever sees it
# ═════════════════════════════════════════════════════════════════════════════

user_text := lower(sprintf("%v", [object.get(input.policy_target.value, "text", "")]))

injection_patterns := [
	`ignore\s+(all\s+)?(your\s+)?previous\s+instructions`,
	`disregard\s+(all\s+)?(above|prior|previous)`,
	`you\s+are\s+now\s+(a|an|in)\b`,
	`reveal\s+(your\s+)?(system\s+prompt|instructions)`,
	`developer\s+mode`,
	`\bDAN\s+mode\b`,
	`pretend\s+you\s+(are|have)\s+no\s+(rules|restrictions)`,
]

injection_hit contains p if {
	some p in injection_patterns
	regex.match(p, user_text)
}

input_verdict := {
	"decision": "deny",
	"reason": "prompt_injection_detected",
	"message": sprintf("Input matched %d prompt-injection pattern(s). OWASP LLM01.", [count(injection_hit)]),
} if count(injection_hit) > 0


# ═════════════════════════════════════════════════════════════════════════════
#  SEAM 2 — pre_tool_call:  the model asked for a tool. Should it run?
# ═════════════════════════════════════════════════════════════════════════════

# The runtime projects the resolved manifest entry for this tool into
# `input.tool`, so `input.tool.name` is the authoritative tool name.
# (The raw request is still at input.snapshot.tool_call.)
tool := input.tool.name
args := input.policy_target.value

# ── 2a. Capability surface ───────────────────────────────────────────────────
# No rule needed. A tool absent from the manifest's `tools:` block never
# reaches this policy — the runtime fails closed with
# `runtime_error:tool_unknown`. The manifest IS the allow-list.

# ── 2b. SQL: no destructive statements, ever ─────────────────────────────────
sql := lower(sprintf("%v", [object.get(args, "sql", "")]))

destructive_sql := [
	`\bdrop\s+(table|database|index|view|schema)\b`,
	`\btruncate\s+table\b`,
	`\balter\s+table\b`,
	`\bgrant\b`,
	`\brevoke\b`,
]

sql_hit contains p if {
	some p in destructive_sql
	regex.match(p, sql)
}

# OPA's regex engine is RE2 — no lookahead — so "mass mutation" is expressed
# as two positive checks instead of one negative one.
sql_hit contains "delete_without_where" if {
	regex.match(`\bdelete\s+from\b`, sql)
	not contains(sql, "where")
}

sql_hit contains "update_without_where" if {
	regex.match(`\bupdate\b[\s\S]*\bset\b`, sql)
	not contains(sql, "where")
}

pre_tool_call_verdict := {
	"decision": "deny",
	"reason": "destructive_sql_blocked",
	"message": "Statement is destructive or unbounded. Support agents get read-only access.",
} if {
	tool == "query_orders_db"
	count(sql_hit) > 0
}

# ── 2c. Money: refunds over $500 need a human, not a better prompt ───────────
refund_amount := to_number(object.get(args, "amount_usd", 0))

pre_tool_call_verdict := {
	"decision": "escalate",
	"reason": "refund_limit_exceeded",
	# %v, not %.2f — Rego numbers stay integers when the JSON had no decimal
	# point, and %.2f on an int64 renders as a Go format error.
	"message": sprintf("Refund of $%v exceeds the $500 autonomous limit. Human approval required.", [refund_amount]),
} if {
	tool == "issue_refund"
	refund_amount > 500
}

# ── 2d. Egress: the agent may only email approved domains ───────────────────
recipient := lower(sprintf("%v", [object.get(args, "to", "")]))

approved_domains := ["@northwind-store.com", "@northwind-store.co.uk"]

recipient_approved if {
	some d in approved_domains
	endswith(recipient, d)
}

pre_tool_call_verdict := {
	"decision": "deny",
	"reason": "egress_domain_not_approved",
	"message": sprintf("%q is outside the approved egress domains. Possible exfiltration.", [recipient]),
} if {
	tool == "send_email"
	not recipient_approved
}


# ═════════════════════════════════════════════════════════════════════════════
#  SEAM 3 — post_tool_call:  DLP. Secrets never enter the context window.
# ═════════════════════════════════════════════════════════════════════════════

tool_result := sprintf("%v", [input.policy_target.value])

# API keys (sk-..., ghp_...), and 16-digit card numbers.
redacted_result := r3 if {
	r1 := regex.replace(tool_result, `sk-[A-Za-z0-9_\-]{16,}`, "[REDACTED:API_KEY]")
	r2 := regex.replace(r1, `ghp_[A-Za-z0-9]{20,}`, "[REDACTED:GITHUB_TOKEN]")
	r3 := regex.replace(r2, `\b(?:\d[ -]*?){13,16}\b`, "[REDACTED:CARD_NUMBER]")
}

post_tool_call_verdict := {
	"decision": "transform",
	"reason": "secret_redacted_from_tool_result",
	"message": "Tool result contained credential/PAN material; redacted before it reached the model.",
	"transform": {
		"path": "$policy_target",
		"value": redacted_result,
	},
} if redacted_result != tool_result


# ═════════════════════════════════════════════════════════════════════════════
#  SEAM 4 — output:  last line of defence before the user sees anything
# ═════════════════════════════════════════════════════════════════════════════

output_text := sprintf("%v", [object.get(input.policy_target.value, "text", "")])

redacted_output := o2 if {
	o1 := regex.replace(output_text, `sk-[A-Za-z0-9_\-]{16,}`, "[REDACTED:API_KEY]")
	o2 := regex.replace(o1, `\b(?:\d[ -]*?){13,16}\b`, "[REDACTED:CARD_NUMBER]")
}

output_verdict := {
	"decision": "transform",
	"reason": "secret_redacted_from_output",
	"message": "Assistant output contained credential/PAN material; redacted before delivery.",
	"transform": {
		"path": "$policy_target.text",
		"value": redacted_output,
	},
} if redacted_output != output_text
