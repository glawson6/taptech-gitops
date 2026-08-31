# Deployed apps inventory

Running list of every workload Application under `applications/` — what it
does, where its source lives, what image it runs, which hostname it serves.
This is the "what's in prod?" answer that doesn't require reading YAML.

If this table falls out of sync with `applications/`, **`applications/` wins**
— update the table.

## Workloads

| # | App | Purpose | Source repo | Image | Hostname(s) | Namespace | Status |
|---|---|---|---|---|---|---|---|
| 1 | `holdings-ui` | TapTech Holdings marketing SPA | `holdings.taptech.net` | `tooling.taptech.net:5000/taptech-holdings-ui` | `holdings.taptech.net` | `taptech-prod` | ✅ deployed |
| 2 | `jaiclaw-io` | JaiClaw.io marketing SPA | `openclaw/jaiclaw.io` | `tooling.taptech.net:5000/jaiclaw-io` | `jaiclaw.io`, `www.jaiclaw.io` | `taptech-prod` | ✅ deployed |
| 3 | `mcp-client` | AI chat backend (`/api/chat/*`) for the holdings SPA | `taptech-ai-agent-parent/taptech-ai-agent-mcp-client` | `tooling.taptech.net:5000/taptech-ai-agent-mcp-client` | `mcp-client.taptech.net` | `taptech-prod` | 🟡 pending first sync |
| 4 | `mcp-calendar` | Calendar/scheduling MCP tools consumed by `mcp-client` over SSE | `taptech-ai-agent-parent/taptech-ai-agent-mcp-calendar-server` | `tooling.taptech.net:5000/taptech-ai-agent-mcp-calendar-server` | (internal only) | `taptech-prod` | 🟡 pending first sync |
| 5 | `taptech-crm` | Contact-form / lead intake for both sites | `taptech-company/taptech-crm/taptech-platform-app` | `tooling.taptech.net:5000/taptech-platform-app` | `api-crm.taptech.net` | `taptech-prod` | 🟡 pending first sync |
| 6 | `taptech-gitops-agent-service` | GitOps automation agent (ArgoCD / Jenkins ops via chat + Telegram) | `taptech-gitops-agent-service` | `tooling.taptech.net:5000/taptech-gitops-agent-service` | (none — Telegram poll) | `taptech-prod` | ✅ deployed |

**Status legend:** ✅ deployed and healthy · 🟡 manifests in `applications/`, awaiting first ArgoCD sync (or image push) · ❌ intentionally removed / disabled.

## Management-cluster apps

Not listed here. Those live under `argocd/clusters/mgmt/` — see
[`docs/mgmt-ui-inventory.md`](mgmt-ui-inventory.md) for the full table
with URLs and auth model.

## Traffic flow

```
                     ┌───────────────────────────────┐
                     │  holdings.taptech.net (SPA)   │
                     └─────────────┬─────────────────┘
                     chat          │        form
                       ┌───────────┴────────────┐
                       ▼                        ▼
        ┌───────────────────────────┐   ┌─────────────────────────┐
        │ mcp-client.taptech.net    │   │ api-crm.taptech.net     │
        │        (mcp-client)       │   │      (taptech-crm)      │
        └─────────────┬─────────────┘   └────────────▲────────────┘
              SSE / MCP                              │ form
                      ▼                              │
        ┌───────────────────────────┐   ┌────────────┴────────────┐
        │  mcp-calendar (in-cluster │   │   jaiclaw.io (SPA)      │
        │   ClusterIP, no ingress)  │   └─────────────────────────┘
        └───────────────────────────┘
```

All three backends share one Redis instance in-cluster but use distinct
databases (mcp-client=0, mcp-calendar=1, taptech-crm=2) and distinct
credentials (`TapTech-MCP-Client-Redis`, `TapTech-Calendar-Server-Redis`,
`TapTech-CRM-Redis` in 1Password vault `taptech-prod`) so they rotate
independently.

## Update discipline

- **Adding an app.** Create `applications/<name>/` following the pattern in
  `applications/mcp-client/`; add a row to the table with status 🟡; flip
  to ✅ after the first ArgoCD sync succeeds.
- **Removing an app.** Delete the directory; either delete the row or mark
  it ❌ with a one-line note on why.
- **Renaming a host / repo.** Edit the row. The `applications/*/overlays/prod`
  ArgoCD ApplicationSet auto-picks-up the rename on the next reconcile.
