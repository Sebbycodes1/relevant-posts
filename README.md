# Relevant Posts

Relevant Posts is a locally refreshed AI intelligence feed for asset-management analysts and portfolio managers. It prioritizes verified developments across models, labs, chips, memory, infrastructure, energy, hyperscalers and policy.

## Use the prototype

1. Double-click `outputs\refresh-relevant-posts.cmd`.
2. Wait for the source passes and quality checks to finish.
3. The current dashboard opens automatically as `outputs\signal-desk-live.html`.

The refresh is manual by design for the prototype, keeping xAI usage predictable. The last successful result from an individual source lane is retained if another lane fails.

## What the refresh does

1. **Broad event discovery:** runs separate searches for models/labs, semiconductors, infrastructure, hyperscalers, policy and market-moving capital or earnings, followed by a cross-lane gap audit.
2. **Primary-source verification:** uses X attention to find developments, then requires a direct official source before an event can enter the feed. The scan starts with 24 hours and falls back to 72 hours.
3. **Curated X and newsletter monitoring:** reviews configured high-signal accounts and specialist publications without limiting broad discovery to that source list.
4. **Event-specific X search:** searches every verified event independently using names, entities, metrics, links, semantic variants and quote posts. Thin searches are retried automatically.
5. **Independent commentary grading:** separates candidate discovery from grading, rejects pre-announcement posts and repetition, then applies a deterministic quality score that favors evidence, insight, independence and recency.
6. **Coverage and source learning:** records which events lacked useful commentary and gradually promotes unfamiliar accounts only after multiple distinct posts clear the quality screen.
7. **Event memory and ranking:** retains recently verified major events through imperfect refreshes, clusters duplicate coverage and ranks by quality before recency.

The visible dashboard remains a single ranked feed. Detailed evidence and score components are available only when expanded.

## Local data and credentials

The xAI key remains in the Git-ignored local secrets folder. Candidate, rejection, coverage and source-performance logs are stored under `work\` for calibration and are not shown in the dashboard.

No portfolio, client or internal company data is required.
