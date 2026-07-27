# Relevant Posts

Relevant Posts is a locally refreshed AI intelligence feed for asset-management analysts and portfolio managers. It prioritizes verified developments across models, labs, chips, memory, infrastructure, energy, hyperscalers and policy.

## Use the prototype

1. Double-click `outputs\refresh-relevant-posts.cmd`.
2. Wait for the three source passes to finish.
3. The current dashboard opens automatically as `outputs\signal-desk-live.html`.

The refresh is manual by design for the prototype, keeping xAI usage predictable. The last successful result from an individual source lane is retained if another lane fails.

## What the refresh does

1. **Breaking-event discovery:** searches broadly across X and the web, verifies major events against primary sources and falls back from 24 to 72 hours when the current window is quiet.
2. **Curated X monitoring:** reviews the configured high-signal accounts and records why borderline posts were excluded.
3. **Newsletter and RSS monitoring:** collects recent specialist analysis and applies separate thresholds for evidence-led analysis and commentary.
4. **Commentary enrichment:** searches X and the collected newsletters only for posts published after the verified event, rejects predictions and selects the newest analysis that clears the quality gate.
5. **Event clustering:** combines multiple posts about the same development, uses the best qualifying commentary as the main link and preserves the official source as evidence.
6. **PM ranking:** scores significance, credibility, timeliness and depth, while ensuring verified major events remain visible even when their depth score is modest.

The visible dashboard remains a single ranked feed. Detailed evidence and score components are available only when expanded.

## Local data and credentials

The xAI key remains in the Git-ignored local secrets folder. Generated candidate and rejection logs are stored under `work\` for calibration and are not shown in the dashboard.

No portfolio, client or internal company data is required.
