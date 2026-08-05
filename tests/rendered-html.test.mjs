import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const projectRoot = new URL("../", import.meta.url);
const projectRootPath = fileURLToPath(projectRoot);
const publishedDashboardUrl = new URL("../docs/index.html", import.meta.url);
const builderUrl = new URL("../scripts/build-live-dashboard.ps1", import.meta.url);
const publisherUrl = new URL("../scripts/publish-dashboard.ps1", import.meta.url);
const refreshUrl = new URL("../scripts/refresh-signal-desk.ps1", import.meta.url);
const budgetHelperUrl = new URL("../scripts/xai-cost-budget.ps1", import.meta.url);
const dailyRefreshUrl = new URL("../refresh-and-publish.cmd", import.meta.url);
const balancedRefreshUrl = new URL("../refresh-and-publish-balanced.cmd", import.meta.url);
const fullRefreshUrl = new URL("../refresh-and-publish-full.cmd", import.meta.url);
const breakingRefreshUrl = new URL("../scripts/fetch-breaking-events.ps1", import.meta.url);
const xRefreshUrl = new URL("../scripts/fetch-xai-signals.ps1", import.meta.url);
const mergeUrl = new URL("../scripts/merge-live-feeds.ps1", import.meta.url);
const commentaryRefreshUrl = new URL("../scripts/fetch-event-commentary.ps1", import.meta.url);
const newsletterRefreshUrl = new URL("../scripts/fetch-substack.ps1", import.meta.url);
const newsletterSourcesUrl = new URL("../scripts/newsletter-sources.json", import.meta.url);

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

function extractEmbeddedFeed(html) {
  const match = html.match(
    /const demoSignals = (\[.*?\]);\s*const feedMeta = (\{.*?\});\s*const sources =/s,
  );
  assert.ok(match, "dashboard should contain readable embedded feed data");
  return {
    signals: JSON.parse(match[1]),
    meta: JSON.parse(match[2]),
  };
}

function powershellExecutable() {
  return process.platform === "win32" ? "powershell.exe" : "pwsh";
}

function runPowerShell(scriptUrl, args) {
  execFileSync(
    powershellExecutable(),
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      fileURLToPath(scriptUrl),
      ...args,
    ],
    { cwd: projectRootPath, stdio: "pipe" },
  );
}

test("server renders the Relevant Posts product", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Relevant Posts/i);
  assert.match(html, /Morning brief/);
  assert.match(html, />Sources</);
  assert.match(html, /How we filter/);
  assert.doesNotMatch(html, /Your site is taking shape|Codex is working|react-loading-skeleton/);
});

test("published dashboard embeds a valid ranked feed", async () => {
  const html = await readFile(publishedDashboardUrl, "utf8");
  const { signals, meta } = extractEmbeddedFeed(html);

  assert.ok(signals.length > 0);
  assert.ok(Array.isArray(meta.sourceFeeds));
  assert.ok(meta.sourceFeeds.length >= 4);
  assert.ok(Number(meta.staleAfterHours) > 0);

  const ids = new Set();
  const urls = new Set();
  for (const signal of signals) {
    assert.ok(signal.id);
    assert.ok(signal.url);
    assert.match(signal.url, /^https:\/\//);
    assert.equal(
      Number(signal.score),
      Number(signal.significance)
        + Number(signal.credibility)
        + Number(signal.timeliness)
        + Number(signal.depth),
    );
    assert.equal(ids.has(String(signal.id)), false, `duplicate id: ${signal.id}`);
    assert.equal(urls.has(signal.url), false, `duplicate URL: ${signal.url}`);
    ids.add(String(signal.id));
    urls.add(signal.url);

    assert.notEqual(
      signal.commentaryUrl,
      "https://x.com/HedgeyeComm/status/2082542496727584945",
      "explicitly rejected Meta/BlackRock commentary must not be republished",
    );

    if (signal.featuredCommentary) {
      assert.equal(signal.url, signal.primarySourceUrl, "event card should retain its primary-source URL");
      assert.equal(signal.source, signal.primarySourceName, "event card should retain its primary-source name");
      assert.equal(signal.platform, signal.primarySourcePlatform, "event card should retain its primary-source platform");
      assert.equal(signal.publishedAt, signal.eventPublishedAt, "event card should retain its event timestamp");
      assert.match(signal.commentaryUrl, /^https:\/\/(?:www\.)?x\.com\//, "commentary should keep a separate X URL");
      assert.ok(signal.commentarySource, "commentary should keep a separate source label");
      assert.ok(Number(signal.commentaryScore) > 0, "commentary should keep its own score");
      if (signal.commentarySourceFamiliarity === "unknown") {
        assert.ok(Number(signal.commentaryScore) >= 74, "unknown commentary needs the higher quality floor");
        assert.equal(signal.commentaryHasDirectEvidenceLinks, true, "unknown commentary needs direct evidence");
      }
    }

    if (signal.isBreaking) {
      const eventPublishedAt = new Date(signal.eventPublishedAt || signal.publishedAt);
      const generatedAt = new Date(meta.generatedAt);
      const ageHours = (generatedAt.getTime() - eventPublishedAt.getTime()) / 3_600_000;
      assert.ok(ageHours >= 0 && ageHours <= 24, "Breaking should expire 24 hours after the underlying event");
      assert.ok(Number(signal.score) >= 80, "Breaking requires a high-quality verified event");
    }

  }

  assert.ok(signals.some((signal) => signal.mustInclude || Number(signal.score) >= 60));
  const modularDatacenterCoverage = signals.filter((signal) => {
    const source = String(signal.source ?? "")
      .replace(/[^a-z0-9]/gi, "")
      .toLowerCase();
    return (
      source === "semianalysis" &&
      /(?:modular|lego).*(?:data.?center|datacenter)|(?:data.?center|datacenter).*(?:modular|lego)/i.test(
        signal.title,
      )
    );
  });
  assert.ok(modularDatacenterCoverage.length <= 1, "same-publisher X and newsletter coverage should be clustered");
  assert.match(
    html,
    /Number\(isBreakingNow\(right\)\) - Number\(isBreakingNow\(left\)\)/,
    "current breaking news should receive first ranking priority",
  );
  assert.match(html, /function sourceLinkLabel\(item\)/, "source links should use evidence-aware labels");
  assert.match(html, /sourceTrustClass === "trade_press"\) return "Open reporting"/);
  assert.match(html, /<meta property="og:title" content="Relevant Posts - AI Stack Brief">/);
  assert.doesNotMatch(html, /[\u0080-\u009f]/, "dashboard should not contain mojibake control characters");
});

test("dashboard builder refreshes static and runtime metadata idempotently", async () => {
  const tempDirectory = await mkdtemp(join(tmpdir(), "relevant-posts-test-"));
  try {
    const templatePath = join(tempDirectory, "template.html");
    const feedPath = join(tempDirectory, "feed.json");
    const firstOutputPath = join(tempDirectory, "first.html");
    const secondOutputPath = join(tempDirectory, "second.html");
    const publishedPath = join(tempDirectory, "published.html");
    const staleFeedPath = join(tempDirectory, "stale-feed.json");
    const blockedPublishPath = join(tempDirectory, "blocked-publish.html");
    const template = await readFile(publishedDashboardUrl, "utf8");
    const { signals, meta } = extractEmbeddedFeed(template);
    const fixedTimestamp = "2099-07-29T12:30:00.0000000Z";
    const futureFeed = {
      ...meta,
      generatedAt: fixedTimestamp,
      sourceUpdatedAt: fixedTimestamp,
      oldestSourceAt: fixedTimestamp,
      sourceFeeds: meta.sourceFeeds.map((lane) => ({
        ...lane,
        generatedAt: fixedTimestamp,
      })),
      signals,
    };

    await Promise.all([
      writeFile(templatePath, template, "utf8"),
      writeFile(feedPath, JSON.stringify(futureFeed), "utf8"),
    ]);

    runPowerShell(builderUrl, [
      "-TemplatePath", templatePath,
      "-FeedPath", feedPath,
      "-OutputPath", firstOutputPath,
    ]);
    runPowerShell(builderUrl, [
      "-TemplatePath", firstOutputPath,
      "-FeedPath", feedPath,
      "-OutputPath", secondOutputPath,
    ]);

    const first = await readFile(firstOutputPath, "utf8");
    const second = await readFile(secondOutputPath, "utf8");
    const staticMode = second.match(/<span id="feedMode">([^<]*)<\/span>/)?.[1];
    const runtimeMode = second.match(/const state\s*=\s*\{.*?\bmode:\s*"([^"]*)"/s)?.[1];
    assert.equal(runtimeMode, staticMode);
    assert.match(staticMode ?? "", /sources refreshed Jul 29, 2099/);
    assert.equal(extractEmbeddedFeed(second).meta.sourceUpdatedAt, fixedTimestamp);
    assert.equal(first, second);

    const staleFeed = {
      ...futureFeed,
      sourceFeeds: futureFeed.sourceFeeds.map((lane, index) => ({
        ...lane,
        generatedAt: index === 0 ? "2000-01-01T00:00:00.000Z" : fixedTimestamp,
      })),
    };
    await writeFile(staleFeedPath, JSON.stringify(staleFeed), "utf8");
    assert.throws(() => runPowerShell(publisherUrl, [
      "-DashboardPath", secondOutputPath,
      "-FeedPath", staleFeedPath,
      "-PublishedPath", blockedPublishPath,
      "-SkipGit",
    ]), /Command failed/);

    runPowerShell(publisherUrl, [
      "-DashboardPath", secondOutputPath,
      "-FeedPath", feedPath,
      "-PublishedPath", publishedPath,
      "-SkipGit",
    ]);
    const published = await readFile(publishedPath, "utf8");
    assert.match(published, /How we filter out slop/);
    assert.doesNotMatch(published, /100-point hurdle against slop|PM evidence discipline|Human feedback loop|Prototype boundary/);
    assert.doesNotMatch(published, /data-action="(?:save|useful|dismiss)"|Display threshold|shared prototype/i);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("daily refresh has an enforceable low-cost xAI profile", async () => {
  const [refreshScript, budgetHelper, dailyRefresh] = await Promise.all([
    readFile(refreshUrl, "utf8"),
    readFile(budgetHelperUrl, "utf8"),
    readFile(dailyRefreshUrl, "utf8"),
  ]);

  assert.match(dailyRefresh, /-Budget\b/);
  assert.match(dailyRefresh, /-MaxXaiSpendUsd 1\.00/);
  assert.match(dailyRefresh, /-MaxXaiRequests 8/);
  assert.match(refreshScript, /-CommentaryEventLimit 2\b/);
  assert.match(refreshScript, /-MaxBatches 1\b/);
  assert.match(refreshScript, /-Model "grok-4\.3"/);
  assert.match(budgetHelper, /cost_in_usd_ticks/);
  assert.match(budgetHelper, /maximumRequests/);
});

test("balanced refresh preserves broad coverage behind a four-dollar serial stop-limit", async () => {
  const [refreshScript, breakingScript, newsletterScript, balancedRefresh, fullRefresh] = await Promise.all([
    readFile(refreshUrl, "utf8"),
    readFile(breakingRefreshUrl, "utf8"),
    readFile(newsletterRefreshUrl, "utf8"),
    readFile(balancedRefreshUrl, "utf8"),
    readFile(fullRefreshUrl, "utf8"),
  ]);

  assert.match(balancedRefresh, /-Balanced\b/);
  assert.match(balancedRefresh, /-MaxXaiSpendUsd 4\.00/);
  assert.match(balancedRefresh, /-MaxXaiRequests 16/);
  assert.doesNotMatch(fullRefresh, /-Balanced\b/);
  assert.match(refreshScript, /-ReservePerRequestUsd 0\.75/);
  assert.match(refreshScript, /-CommentaryEventLimit 5\b/);
  assert.match(refreshScript, /-MaxCandidates 25\b/);
  assert.match(refreshScript, /-LookbackHours 36\b/);
  assert.match(breakingScript, /Balanced capabilities policy and open ecosystem/);
  assert.match(breakingScript, /Balanced compute infrastructure and AI economics/);
  assert.match(breakingScript, /profile = if \(\$Economy\) \{ "economy" \} elseif \(\$Balanced\) \{ "balanced" \}/);
  assert.match(newsletterScript, /-MaxConcurrency \$MaxConcurrency/);
});

test("full refresh is bounded, adaptive, measurable, and rebuilt once", async () => {
  const [refreshScript, breakingScript, xScript, commentaryScript, mergeScript, budgetHelper] = await Promise.all([
    readFile(refreshUrl, "utf8"),
    readFile(breakingRefreshUrl, "utf8"),
    readFile(xRefreshUrl, "utf8"),
    readFile(commentaryRefreshUrl, "utf8"),
    readFile(mergeUrl, "utf8"),
    readFile(budgetHelperUrl, "utf8"),
  ]);

  assert.match(refreshScript, /-CommentaryEventLimit 12\b/);
  assert.match(refreshScript, /-MaxConcurrency 2\b/);
  assert.match(refreshScript, /-StrategicRetentionHours 168\b/);
  assert.match(refreshScript, /Initialize-XaiCostBudget[^\r\n]+-TrackOnly/);
  assert.match(refreshScript, /Test-IsXaiUnavailable/);
  assert.match(refreshScript, /\$CatchUp -or \$xaiUnavailable/);
  assert.ok((refreshScript.match(/-SkipMerge\b/g) ?? []).length >= 4);
  assert.equal((refreshScript.match(/merge-live-feeds\.ps1/g) ?? []).length, 1);

  assert.match(breakingScript, /Invoke-XaiResponseBatch/);
  assert.match(breakingScript, /coverageNeedsGapAudit/);
  assert.doesNotMatch(breakingScript, /requiresExhaustivePasses/);
  assert.match(xScript, /Invoke-XaiResponseBatch/);
  assert.match(commentaryScript, /checkpointAgeHours -le \(\$LookbackDays \* 24\)/);
  assert.match(commentaryScript, /checkpointHasCandidates/);
  assert.match(budgetHelper, /enforceLimits/);
  assert.match(mergeScript, /strategicRetentionHours/);
  assert.match(mergeScript, /isStrategic/);
  assert.match(mergeScript, /visibleLookbackHours = 48/);
  assert.match(refreshScript, /BreakingFallbackHours = 48/);
  assert.match(refreshScript, /-LookbackDays 2\b/);
});

test("newsletter universe is vetted and every scored candidate is audited", async () => {
  const [sourcesText, newsletterScript, dashboard] = await Promise.all([
    readFile(newsletterSourcesUrl, "utf8"),
    readFile(newsletterRefreshUrl, "utf8"),
    readFile(publishedDashboardUrl, "utf8"),
  ]);
  const sources = JSON.parse(sourcesText);
  const approved = sources.filter((source) => source?.vetting?.status === "approved");

  assert.ok(approved.length >= 25, "newsletter universe should contain at least 25 approved sources");
  assert.equal(new Set(approved.map((source) => source.name)).size, approved.length);
  for (const source of approved) {
    assert.match(source.feedUrl, /^https:\/\//);
    assert.ok(["core", "context", "event"].includes(source.tier));
    assert.ok(["free", "mixed", "paid"].includes(source.accessPolicy));
    assert.ok(source.vetting.rationale.length >= 40);
    assert.ok(source.vetting.evidenceUrls.length >= 1);
  }

  assert.match(newsletterScript, /Get-FeedEntries/);
  assert.match(newsletterScript, /local-name\(\)='feed'/);
  assert.match(newsletterScript, /paywalled_preview/);
  assert.match(newsletterScript, /Return exactly one decision for every supplied candidate URL/);
  assert.match(newsletterScript, /minItems = \$candidates\.Count/);
  assert.match(newsletterScript, /decision_completeness_check/);
  assert.match(newsletterScript, /batchSize = 10/);
  assert.match(newsletterScript, /Invoke-XaiResponseBatch/);
  assert.match(newsletterScript, /newsletter-xai-budget\.json/);
  assert.match(dashboard, /Recommended analysis:/);
  assert.match(dashboard, /Paywalled preview/);
});

test("related newsletter research attaches to an event instead of disappearing in dedupe", async () => {
  const tempDirectory = await mkdtemp(join(tmpdir(), "relevant-posts-newsletter-merge-"));
  try {
    const now = new Date().toISOString();
    const breakingPath = join(tempDirectory, "breaking.json");
    const newsletterPath = join(tempDirectory, "newsletter.json");
    const combinedPath = join(tempDirectory, "combined.json");
    const missingXPath = join(tempDirectory, "missing-x.json");
    const missingCommentaryPath = join(tempDirectory, "missing-commentary.json");
    const base = {
      age: "1h", publishedAt: now, implication: "Analyst question", sectors: ["Models"],
      significance: 30, credibility: 22, timeliness: 18, depth: 10, score: 80,
      postType: "announcement", eventType: "model_release", entities: ["Example AI"],
      whyNow: "New today", evidenceSummary: "Direct release", corroboratingUrls: [],
      hasPrimaryEvidence: true, hasIndependentConfirmation: false,
      hasMeasurableFirstOrderImpact: true, mustInclude: true, isBreaking: true,
    };
    await writeFile(breakingPath, JSON.stringify({ generatedAt: now, fallbackLookbackHours: 72, signals: [{
      ...base, eventKey: "example-model-release", id: "official", source: "Example AI",
      handle: "example", platform: "Web", title: "Example AI releases a new model",
      summary: "Official model release", url: "https://example.com/model-release",
    }] }), "utf8");
    await writeFile(newsletterPath, JSON.stringify({ generatedAt: now, signals: [{
      ...base, eventKey: "example-model-release", id: "analysis", source: "Vetted Analysis",
      handle: "Newsletter", platform: "Substack", title: "Inside the new Example AI model",
      summary: "Technical analysis", url: "https://analysis.example.com/model-release",
      score: 72, significance: 25, credibility: 18, timeliness: 15, depth: 14,
      postType: "analysis", hasPrimaryEvidence: false, mustInclude: false, isBreaking: false,
      recommendedAnalysis: true, analysisValue: "high", incrementalValue: "Explains the architecture and cost tradeoffs.",
      isOriginalResearch: false, accessLevel: "partial_preview",
    }] }), "utf8");

    runPowerShell(mergeUrl, [
      "-BreakingFeedPath", breakingPath,
      "-XFeedPath", missingXPath,
      "-SubstackFeedPath", newsletterPath,
      "-CommentaryFeedPath", missingCommentaryPath,
      "-OutputPath", combinedPath,
      "-SkipBuild",
    ]);

    const combined = JSON.parse(await readFile(combinedPath, "utf8"));
    assert.equal(combined.signals.length, 1);
    assert.equal(combined.signals[0].url, "https://example.com/model-release");
    assert.equal(combined.signals[0].recommendedAnalysis, true);
    assert.equal(combined.signals[0].analysisSource, "Vetted Analysis");
    assert.equal(combined.signals[0].analysisUrl, "https://analysis.example.com/model-release");
    assert.equal(combined.signals[0].analysisAccessLevel, "partial_preview");
    assert.equal(combined.signals[0].hasIndependentConfirmation, false);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("source trust policy prevents secondary reports from posing as primary breaking news", async () => {
  const tempDirectory = await mkdtemp(join(tmpdir(), "relevant-posts-source-policy-"));
  try {
    const now = new Date().toISOString();
    const breakingPath = join(tempDirectory, "breaking.json");
    const combinedPath = join(tempDirectory, "combined.json");
    const missingXPath = join(tempDirectory, "missing-x.json");
    const missingSubstackPath = join(tempDirectory, "missing-substack.json");
    const missingCommentaryPath = join(tempDirectory, "missing-commentary.json");
    const baseSignal = {
      handle: "source",
      platform: "Web",
      age: "1h",
      publishedAt: now,
      summary: "Test signal",
      implication: "Test implication",
      whyNow: "Published during the test window",
      evidenceSummary: "Test evidence",
      sectors: ["Memory"],
      significance: 35,
      credibility: 25,
      timeliness: 20,
      depth: 15,
      score: 95,
      postType: "analysis",
      eventType: "supply_chain",
      entities: ["NVIDIA"],
      hasPrimaryEvidence: true,
      hasIndependentConfirmation: false,
      hasMeasurableFirstOrderImpact: true,
      mustInclude: true,
      isBreaking: true,
    };
    const feed = {
      generatedAt: now,
      fallbackLookbackHours: 72,
      signals: [
        {
          ...baseSignal,
          eventKey: "trendforce-test",
          id: "trendforce-test",
          source: "TrendForce",
          title: "TrendForce reports an unannounced supplier plan",
          entities: ["NVIDIA"],
          url: "https://www.trendforce.com/presscenter/news/example.html",
        },
        {
          ...baseSignal,
          eventKey: "digitimes-test",
          id: "digitimes-test",
          source: "DigiTimes",
          title: "DigiTimes reports memory capacity allocations",
          entities: ["Samsung"],
          url: "https://www.digitimes.com/news/example.html",
        },
        {
          ...baseSignal,
          eventKey: "official-test",
          id: "official-test",
          source: "AWS What's New",
          title: "AWS publishes its own product announcement",
          entities: ["Amazon"],
          eventType: "model_release",
          url: "https://aws.amazon.com/about-aws/whats-new/example",
        },
      ],
    };
    await writeFile(breakingPath, JSON.stringify(feed), "utf8");

    runPowerShell(mergeUrl, [
      "-BreakingFeedPath", breakingPath,
      "-XFeedPath", missingXPath,
      "-SubstackFeedPath", missingSubstackPath,
      "-CommentaryFeedPath", missingCommentaryPath,
      "-OutputPath", combinedPath,
      "-SkipBuild",
    ]);

    const combined = JSON.parse(await readFile(combinedPath, "utf8"));
    const trendforce = combined.signals.find((signal) => signal.id === "trendforce-test");
    const digitimes = combined.signals.find((signal) => signal.id === "digitimes-test");
    const official = combined.signals.find((signal) => signal.id === "official-test");

    assert.equal(trendforce.sourceTrustClass, "specialist_research");
    assert.equal(trendforce.hasPrimaryEvidence, false);
    assert.equal(trendforce.isBreaking, false);
    assert.equal(trendforce.mustInclude, false);
    assert.ok(trendforce.credibility <= 16);
    assert.ok(trendforce.score <= 69);

    assert.equal(digitimes.sourceTrustClass, "trade_press");
    assert.equal(digitimes.hasPrimaryEvidence, false);
    assert.equal(digitimes.isBreaking, false);
    assert.ok(digitimes.credibility <= 14);
    assert.ok(digitimes.score <= 69);

    assert.equal(official.sourceTrustClass, "official_primary");
    assert.equal(official.hasPrimaryEvidence, true);
    assert.ok(official.credibility <= 22, "single-source official claims should not receive full corroboration credit");
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});
