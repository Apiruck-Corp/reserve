# Roadmap
Last updated: 2026-10-18

## Now
- 2026-10-18: Claude Team account shows only the 5-hour window: show model limits (Fable) that Anthropic marks inactive, and read plan limits from `limits` when `seven_day` is missing. Fixed on branch t3/fix-team-subscription-usage-details, not released yet.

- 2026-10-18: Fix personal and Nimbus Team Claude limits and token history mixing between accounts (implemented and validated; awaiting review and release).

- 2026-10-18: Fix Anthropic API key validation and check what TypeSafe information is available to add. PR #67 adds current-key support, richer TypeSafe details, native replacement/error-label regressions, bounded workspace recovery and current-error priority. Local build 1.9.0 (1056.5) is installed on the MBA, signature/binary verified, with prior bundles backed up. After Keychain approval, live workspace discovery reaches Anthropic and returns HTTP 403. Verified the live Admin API documentation explicitly excludes Individual accounts; the follow-up screenshot confirms the Individual API plan, which is distinct from Organization key scope. Updated Settings, errors and README to explain eligibility without inferring account type from a 403 alone. All 380 unit tests and current native UI/reliability checks pass; earlier 43 domain/lifecycle/connections/stress gates passed. The latest eligibility wording is in the PR source, not installed build 1056.5. Investigation identifies the account eligibility restriction: Console organization setup is required before live billing can be verified. Prepared a portable MacBookPro handoff in docs/handoffs/API_KEYS_MBP_2026-10-18.md; remote session launch is blocked by desktop controls. Awaiting review and merge.

- 2026-10-18: Improve the Insight window with T3 Code-style detail, layout and filters, keeping the daily heatmap and every provider used in the selected period. Implemented and validated, including smooth chart curves connected across missing days and a light, more colorful palette adapted to light and dark mode; awaiting PR review and merge.

## Next

## Later

## Done
