# Roadmap
Last updated: 2026-10-18

## Now

- 2026-10-18: Fix Anthropic API key validation and check what TypeSafe information is available to add. PR #67 adds ordinary-key validation, richer TypeSafe details, and native replacement/error-label regression tests. Local test build 1.9.0 (1056.4) is installed on the MBA, verified against the packaged binary, with the previous app backed up. Investigation found a fresh HTTP 400 hidden by an older "Key valid" heading. Added bounded recovery for Anthropic's documented missing workspace-context response, endpoint-specific errors, current-error priority, and clearing previous validation on replacement. Workspace context does not filter organization spend. All 376 unit tests, 43 domain checks and native UI/reliability/lifecycle/connections/stress gates pass. After Keychain approval, live build 1056.3 still reports Models API HTTP 400. The stale heading is fixed; missing-workspace recovery is not established as the cause. Corrected organization request authentication to the endpoint-specific Admin API guide's x-api-key form and added fixed rejection categories. All 377 unit tests pass; build 1056.4 is installed, signature and binary verified, and waiting for the updated app's Keychain authorization. Native refresh reliability passes with the latest parser/header change. Awaiting review and merge.

## Next

## Later

## Done
