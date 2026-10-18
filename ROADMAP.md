# Roadmap
Last updated: 2026-10-18

## Now

- 2026-10-18: Fix Anthropic API key validation and check what TypeSafe information is available to add. PR #67 adds current-key support, richer TypeSafe details, native replacement/error-label regressions, bounded workspace recovery and current-error priority. Local build 1.9.0 (1056.5) is installed on the MBA, signature/binary verified, with prior bundles backed up. After Keychain approval, live workspace discovery reaches Anthropic and returns HTTP 403. Verified the live Admin API documentation explicitly excludes Individual accounts; the follow-up screenshot confirms the Individual API plan, which is distinct from Organization key scope. Updated Settings, errors and README to explain eligibility without inferring account type from a 403 alone. All 380 unit tests and current native UI/reliability checks pass; earlier 43 domain/lifecycle/connections/stress gates passed. The latest eligibility wording is in the PR source, not installed build 1056.5. Investigation identifies the account eligibility restriction: Console organization setup is required before live billing can be verified. Awaiting review and merge.

## Next

## Later

## Done
