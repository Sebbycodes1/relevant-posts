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
  assert.match(html, /Source book/);
  assert.match(html, /Scoring rubric/);
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

  }

  assert.ok(signals.some((signal) => signal.mustInclude || Number(signal.score) >= 60));
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
    assert.match(published, /This shared prototype is a read-only snapshot/);
    assert.doesNotMatch(published, /dashboard file and your feedback stay on this device/i);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});
