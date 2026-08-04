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
const breakingRefreshUrl = new URL("../scripts/fetch-breaking-events.ps1", import.meta.url);
const xRefreshUrl = new URL("../scripts/fetch-xai-signals.ps1", import.meta.url);
const mergeUrl = new URL("../scripts/merge-live-feeds.ps1", import.meta.url);
const commentaryRefreshUrl = new URL("../scripts/fetch-event-commentary.ps1", import.meta.url);

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
