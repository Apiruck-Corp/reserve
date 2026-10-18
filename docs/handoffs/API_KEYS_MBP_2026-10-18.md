# API key management handoff to MacBookPro

Prepared October 18, 2026. The user requested a new session on the MacBookPro.

## Start here

- Repository: https://github.com/Apiruck-Corp/reserve
- Branch: `codex/api-key-management`
- PR: https://github.com/Apiruck-Corp/reserve/pull/67
- Implementation and diagnosis checkpoint before this handoff: `4dbecbfaa25d5058af0b81591e133c4c63c27b1a`.
- Read the current `AGENTS.md` and `ROADMAP.md`, run the required GitHub preflight, and preserve any dirty or diverged checkout. Fetch this branch from GitHub in the MacBookPro environment; the MBA's local worktree is not a shared filesystem.
- Verify the actual execution host before building or installing. The preceding session ran on the M2 MacBook Air. T3's destination label for the requested continuation is **PO MBP**.

The new MacBookPro session has not been launched by this handoff document. Current-environment thread tools cannot select a different host. Desktop attempts to select the destination returned `Computer Use server error -10005: noWindowsAvailable`.

## Confirmed diagnosis

Anthropic's Admin API is unavailable to Individual accounts. The user supplied a follow-up Console screenshot explicitly showing **Individual API plan**. An API key having **Organization** scope does not change that account eligibility.

The billing endpoints are part of the Admin API. This restriction explains why changing key types did not produce billing data. A configured, eligible Console organization and appropriate linked-account access are required before live spend reporting can be verified.

Sources:

- https://platform.claude.com/docs/en/manage-claude/admin-api
- https://platform.claude.com/docs/en/manage-claude/usage-cost-api
- https://platform.claude.com/docs/en/manage-claude/authentication
- https://platform.claude.com/docs/en/manage-claude/workspaces

Important retrieval detail: article scrapers omitted the Individual-account warning. It was verified in the **live browser DOM** near the top of the Admin API page. Do not repeat the earlier assumption that Organization key scope alone permits billing access.

## Implemented in PR 67

- Current personal/service-account key support, current Console key creation link, and endpoint-specific documented authentication.
- Billing is tried first. A billing refusal can fall back to a read-only Models API check; no inference calls and no invented zero spend.
- Organization identity keys may require `anthropic-workspace-id` for model access. Recovery discovers the default active workspace using `include_default=true`, then retries once. The header does not filter organization cost reports.
- Missing-context recovery recognizes a named absent header instead of requiring the exact English words "is required". Supplied-context failures cannot restart discovery. Pagination is bounded and ambiguous workspaces are not chosen arbitrarily.
- Current request errors override older validation snapshots. Replacing a key clears the previous credential's validation. Error explanations update while editing without discarding drafts.
- Fixed response categories and sanitized HTTP statuses provide diagnostics without exposing provider free text or credentials.
- Eligibility guidance now explains Individual accounts versus Organization key scope, while retaining conditional role advice for eligible organizations. HTTP 403 alone does not establish account type.
- TypeSafe details now include model descriptions and release dates, with published pricing/context information clearly separated from live account data. Its documented API exposes models, not account spend or balance.

Primary files: `Sources/ReserveCore/APIConsumptionClient.swift`, `Sources/Reserve/SettingsWindowController.swift`, `Sources/Reserve/UsageStore.swift`, `Sources/Reserve/RefreshReliabilitySelfTest.swift`, and API consumption tests under `Tests/ReserveCoreTests`.

## Validation and installation boundary

- Latest source: warnings-as-errors build, **380 Swift Testing tests**, native UI and refresh-reliability checks pass.
- Earlier complete gate also passed 43 domain checks, native lifecycle, connection recovery and the 30-cycle UI stress check.
- The MBA's default SwiftBuild engine failed parsing a property list. Validation used SwiftPM's native build engine and explicit installed Testing framework search paths, with XCTest disabled. Try the normal project gate first on the MacBookPro; this workaround may be host-specific.
- MBA installed app: **1.9.0 (1056.5)**, source **`c454af1`**, local ad-hoc signed production configuration. Package/signature verification and installed binary hash equality passed. Prior app bundles were backed up.
- That build completed Keychain authorization. Live recovery reached the Anthropic Workspaces API, which returned **HTTP 403**.
- The newer **account-eligibility wording is in the PR source, not MBA build 1056.5**.
- No build installation on the MacBookPro has been verified. No live billing success is claimed.

## Continue on the MacBookPro

1. Open a new Reserve session on **PO MBP**, load this branch and this handoff, and verify checkout provenance and execution host.
2. Preserve the confirmed Individual-plan diagnosis. Account setup is the external prerequisite for billing; another key in the same Individual account does not remove it.
3. Continue with the user's chosen next step: organization setup guidance, PR review, or a local build/install of the updated guidance. Handoff alone does not authorize changing provider account type, billing settings, membership or roles.
4. Verify live billing only after eligible Console organization setup and the user saving the appropriate key locally.
5. Keep `ROADMAP.md` accurate. The item remains in Now pending review/merge and the external billing prerequisite.

Never paste, print, commit, or transfer API keys. Keychain credentials and browser sign-ins are machine-local; no secrets were included in this handoff. Repeated local ad-hoc build updates can require new Keychain authorization. The user must operate protected macOS prompts; computer-use tooling blocks SecurityAgent.
