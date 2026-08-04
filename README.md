# Relevant Posts

Relevant Posts is a locally refreshed AI intelligence feed for asset-management analysts and portfolio managers. It prioritizes verified developments across models, labs, chips, memory, infrastructure, energy, hyperscalers and policy.

## Use the prototype

### Refresh and publish

1. In the morning, double-click `refresh-and-publish-full.cmd` for the complete curated edition. Independent discovery requests run in bounded pairs, while quality gates and source verification remain unchanged.
2. Leave the window open while the source passes and quality checks run.
3. If every source lane succeeds, the workflow updates the shared GitHub Pages dashboard automatically.
4. After major afternoon earnings or announcements, double-click `refresh-and-publish-catch-up.cmd`. This lighter pass retains the morning account and newsletter scans, with a five-request / $0.60 stop-limit.

`refresh-and-publish.cmd` remains available as the low-cost fallback: it uses the lower-cost model, makes no more than eight xAI requests and stops near a $1 run limit.

The public page is never changed after a partial or failed refresh. The command requires the local xAI key to be configured and this repository to be signed in to GitHub.

For a local-only update, double-click `outputs\refresh-relevant-posts.cmd`. The resulting dashboard opens as `outputs\signal-desk-live.html` without changing the shared link.

The refresh is manual by design for the prototype. Every run records the exact per-request cost returned by xAI in `work\xai-refresh-budget.json`; budget runs also enforce their configured stop limits. The last successful result from an individual source lane is retained if another lane fails.

## What the refresh does

1. **Broad event discovery:** runs separate searches for models/labs, semiconductors, infrastructure, hyperscalers, policy and market-moving capital or earnings, plus a deterministic official-source catalyst watchlist. Independent lanes run two at a time; a second pass and cross-lane gap audit run only when verified coverage is actually thin.
2. **Primary-source verification:** uses X attention to find developments, then requires a direct official source before an event can enter the feed. The scan starts with 24 hours and may search back 48 hours for coverage completeness.
3. **Curated X and newsletter monitoring:** reviews configured high-signal accounts and specialist publications without limiting broad discovery to that source list.
4. **Event-specific X search:** searches every verified event independently using names, entities, metrics, links, semantic variants and quote posts. Thin searches are retried automatically.
5. **Independent commentary grading:** separates candidate discovery from grading, rejects pre-announcement posts and repetition, then applies a deterministic quality score that favors evidence, insight, independence and recency.
6. **Coverage and source learning:** records which events lacked useful commentary and gradually promotes unfamiliar accounts only after multiple distinct posts clear the quality screen.
7. **Strict recency and ranking:** the visible dashboard contains only signals published in the last 48 hours. Breaking news remains first, duplicates are clustered, and older verified events stay only in local audit history rather than occupying the live feed.

The visible dashboard remains a single ranked feed. Detailed evidence and score components are available only when expanded.

## Local data and credentials

The xAI key remains in the Git-ignored local secrets folder. Candidate, rejection, coverage and source-performance logs are stored under `work\` for calibration and are not shown in the dashboard.

No portfolio, client or internal company data is required.
