# Relevant Posts

Relevant Posts is a locally refreshed AI intelligence feed for asset-management analysts and portfolio managers. It prioritizes verified developments across models, labs, chips, memory, infrastructure, energy, hyperscalers and policy.

The production surface is the static dashboard at `docs\index.html`, published through GitHub Pages. It has no database, authentication layer or client-side API credentials; source collection, grading and audit logs run locally before a vetted snapshot is published. The Vinext application files support local build validation and a possible future hosted runtime, but are not used by the current GitHub Pages deployment.

## Use the prototype

### Refresh and publish

The `Morning dashboard refresh` GitHub Actions workflow runs every day at 7:07 a.m. America/New_York time. It uses the recommended balanced profile, scans the full vetted X and newsletter universes, limits expensive event commentary to the top five verified events, and stops near a $4 xAI run limit. It publishes only when every source lane and dashboard validation completes successfully.

One repository administrator must add the xAI credential as the Actions secret `XAI_API_KEY` under **Settings > Secrets and variables > Actions**. The key is injected only while the workflow runs and is never stored in the repository or dashboard. The workflow can also be started on demand from **Actions > Morning dashboard refresh > Run workflow**.

For a local fallback:

1. Double-click `refresh-and-publish-balanced.cmd` for the same recommended curated edition.
2. Leave the window open while the source passes and quality checks run.
3. If every source lane succeeds, the workflow updates the shared GitHub Pages dashboard automatically.
4. After major afternoon earnings or announcements, double-click `refresh-and-publish-catch-up.cmd`. This lighter pass retains the morning account and newsletter scans, with a five-request / $0.60 stop-limit.

`refresh-and-publish.cmd` remains available as the low-cost fallback: it uses one consolidated discovery scan, makes no more than eight xAI requests and stops near a $1 run limit. `refresh-and-publish-full.cmd` remains the unrestricted deep-scan option for presentation days or a difficult news cycle.

The public page is never changed after a partial or failed refresh. The command requires the local xAI key to be configured and this repository to be signed in to GitHub.

For a local-only update, double-click `outputs\refresh-relevant-posts.cmd`. The resulting dashboard opens as `outputs\signal-desk-live.html` without changing the shared link.

Every run records the exact per-request cost returned by xAI in `work\xai-refresh-budget.json`; balanced and budget runs also enforce their configured stop limits. xAI reports the exact cost only after a request completes, so the final request can cause a small overshoot; serial execution prevents multiple requests from doing so at once. The last successful result from an individual source lane is retained if another lane fails. Automated run status, request count, cost and runtime appear in that run's GitHub Actions summary.

## What the refresh does

1. **Broad event discovery:** the recommended balanced mode consolidates the full coverage universe into two complementary searches, then runs a deterministic official-source catalyst watchlist. Full mode can still run separate model/lab, semiconductor, infrastructure, hyperscaler, policy and market-moving capital or earnings lanes when a deeper audit is warranted.
2. **Primary-source verification:** uses X attention to find developments, then requires a direct official source before an event can enter the feed. The scan starts with 24 hours and may search back 48 hours for coverage completeness.
3. **Curated X and newsletter monitoring:** reviews configured high-signal accounts and 25 vetted specialist publications without limiting broad discovery to that source list. The newsletter lane supports RSS and Atom, reads the longest publicly available article text, labels full/partial/paywalled access, and records an include-or-exclude decision for every candidate. It never bypasses a paywall.
4. **Event-specific X search:** searches every verified event independently using names, entities, metrics, links, semantic variants and quote posts. Thin searches are retried automatically.
5. **Independent commentary grading:** separates candidate discovery from grading, rejects pre-announcement posts and repetition, then applies a deterministic quality score that favors evidence, insight, independence and recency.
6. **Coverage and source learning:** records which events lacked useful commentary and gradually promotes unfamiliar accounts only after multiple distinct posts clear the quality screen.
7. **Strict recency and ranking:** the visible dashboard contains only signals published in the last 48 hours. Breaking news remains first, duplicates are clustered, and older verified events stay only in local audit history rather than occupying the live feed.

The visible dashboard remains a single ranked feed. Detailed evidence and score components are available only when expanded.

The newsletter source register and its vetting rationale live in `scripts\newsletter-sources.json`. To test every feed without spending xAI credits, run `scripts\fetch-substack.ps1 -LimitPerSource 2 -LookbackDays 7 -CollectOnly`; the health report is written to `work\newsletter-source-audit.json`.

## Local data and credentials

The xAI key remains in the Git-ignored local secrets folder. Candidate, rejection, coverage and source-performance logs are stored under `work\` for calibration and are not shown in the dashboard.

No portfolio, client or internal company data is required.
