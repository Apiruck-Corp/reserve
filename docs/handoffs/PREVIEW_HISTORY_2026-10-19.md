# Reserve continuation — 2026-10-19

The combined preview work lands through [PR #71](https://github.com/Apiruck-Corp/reserve/pull/71),
from `fix/preview-feedback` into `main`. The user authorized merging for work on
another computer. A public release remains pending; do not tag, publish, or
start the release workflow without authorization.

## What is included

- The earlier API-key, Insights, Claude account-isolation and plan-limit work
  from PRs #67–70, plus the preview feedback fixes already on this branch.
- Local history storage bounds increased from 12 MiB to 64 MiB for the published
  index and 128 MiB for resumable checkpoints. Capacity failures preserve saved
  totals and explain the failure without claiming activity is still gathering.
- Today uses timestamped hourly Claude/Codex usage. Its headline, token types,
  cache detail and model rows publish before historical backfill completes.
- Charts rescale for the selected period, provider and metric; date axes and
  heatmaps fill their available width. Account-only daily history is explicitly
  unavailable as hourly data.
- Older priced caches reparse once to recover model and token-type details.
  Ambiguous historical Codex model attribution remains unavailable rather than
  guessing. Unknown model prices also remain unavailable.

## Continuing on another Mac

In the existing Reserve checkout, preserve any local changes, then fetch and
switch to `main` and pull with `--ff-only`. Check PR #71's merged status before
assuming it is included. Read `AGENTS.md` and `ROADMAP.md` in that checkout.

The installed preview on the originating Mac is version 1.9.0, build **1060**,
locally ad-hoc signed. Pulling source does not install it on another Mac or
transfer accounts, Keychain credentials, session logs or cached history. Each
Mac derives local history from its own Claude/Codex logs.

For a local preview package, use the repository's existing script:

```sh
RESERVE_VERSION=1.9.0 RESERVE_BUILD_NUMBER=1060 \
RESERVE_OUTPUT_DIR="$PWD/.workspace/preview-1060" \
  Scripts/package_app.sh --mode local
Scripts/verify_package.sh --mode local --version 1.9.0 --build 1060 \
  "$PWD/.workspace/preview-1060/Reserve.app"
```

Back up an existing installed app before replacing it. Keep the destination
Mac's history and account configuration intact; allow bounded local migration
to complete. The separate hourly cache rebuilds for the current day/time zone.

## Verification and remaining limits

- Warnings-as-errors build; 408 Swift tests in 37 suites; 43 core self-tests;
  native UI, provider connections and refresh-reliability checks passed locally.
- Storage regressions exercise publication above the old limit, checkpoint
  recovery, reload, deduplication and preservation on capacity failure. Hourly
  tests cover corrections, cumulative deltas, time zones and partial recovery.
- The installed 1060 app was checked with actual data: Today showed hourly
  activity, token-type detail and named models; seven days showed both providers
  on every day, with 14/14 detailed provider-days and different chart scales.
- The broader local lifecycle gate was not green: its search-focus failure was
  reproduced on the unchanged branch baseline; a separate popover-position
  failure was also observed. Do not claim full `make check` passed locally.
  GitHub CI on PR #71 is the authoritative record for its exact pushed head.
- Some older mixed/partial OpenAI cumulative records cannot be assigned safely
  to a model. This is a data limitation, not permission to invent attribution.
- Local evidence and backups remain in the originating checkout's ignored
  `.workspace/` directory and are not transferred through Git.

Implementation details: [history storage and recovery](../EFFICIENCY_AND_RECOVERY.md)
and [UI checks](../UI_UPDATE_CHECKS.md). The older
[API-key handoff](API_KEYS_MBP_2026-10-18.md) is historical context; its installed
build references predate this preview.
