"use client";

import { useEffect, useMemo, useState } from "react";

type Platform = "X" | "Substack";
type Signal = {
  id: number;
  platform: Platform;
  source: string;
  handle: string;
  time: string;
  minutesAgo: number;
  title: string;
  summary: string;
  implication: string;
  sectors: string[];
  score: number;
  significance: number;
  credibility: number;
  timeliness: number;
  depth: number;
  evidence: string;
  tier: "Core" | "Secondary";
  link: string;
};

type FeedMeta = {
  mode: "live" | "rss-only" | "demo";
  xConnected: boolean;
  fetchedAt: string;
  reviewed: number;
  selected: number;
  errors: string[];
};

const demoSignals: Signal[] = [
  {
    id: 1,
    platform: "X",
    source: "Google DeepMind",
    handle: "@GoogleDeepMind",
    time: "18 min ago",
    minutesAgo: 18,
    title: "New inference architecture targets materially lower serving cost",
    summary: "DeepMind published system details and benchmark methodology for a new serving stack, with gains concentrated in long-context and tool-heavy workloads.",
    implication: "Worth testing whether the claimed utilization gains narrow the cost advantage of smaller specialist models.",
    sectors: ["Labs", "Hyperscalers"],
    score: 94,
    significance: 38,
    credibility: 24,
    timeliness: 19,
    depth: 13,
    evidence: "First-party technical release · benchmarks included",
    tier: "Core",
    link: "https://x.com/GoogleDeepMind",
  },
  {
    id: 2,
    platform: "Substack",
    source: "SemiAnalysis",
    handle: "SemiAnalysis",
    time: "42 min ago",
    minutesAgo: 42,
    title: "HBM supply map points to a tighter 2027 than consensus expects",
    summary: "A bottoms-up supplier review connects packaging capacity, yields, and accelerator roadmaps to a revised high-bandwidth memory balance.",
    implication: "The useful question is whether constrained HBM mix, rather than wafer supply, becomes the binding limit on system shipments.",
    sectors: ["Memory", "Chips", "Semis"],
    score: 92,
    significance: 37,
    credibility: 22,
    timeliness: 18,
    depth: 15,
    evidence: "Supply-chain model · multiple primary references",
    tier: "Core",
    link: "https://newsletter.semianalysis.com/",
  },
  {
    id: 3,
    platform: "X",
    source: "Andrej Karpathy",
    handle: "@karpathy",
    time: "1 hr ago",
    minutesAgo: 64,
    title: "A practical observation on agent reliability and context design",
    summary: "Karpathy argues that capability gains increasingly depend on context construction, verification loops, and interface design—not only base-model improvements.",
    implication: "A useful framing for separating durable tooling advantages from short-lived model wrappers.",
    sectors: ["Labs", "Software"],
    score: 87,
    significance: 32,
    credibility: 23,
    timeliness: 18,
    depth: 14,
    evidence: "Named expert · concrete technical examples",
    tier: "Core",
    link: "https://x.com/karpathy",
  },
  {
    id: 4,
    platform: "X",
    source: "NVIDIA",
    handle: "@nvidia",
    time: "2 hrs ago",
    minutesAgo: 121,
    title: "NVIDIA expands reference design for 800V data-center power",
    summary: "The company outlined a broader supplier ecosystem for rack-scale power conversion and cooling around its next infrastructure platform.",
    implication: "Watch for content-per-rack gains shifting value toward power electronics, thermal management, and electrical equipment.",
    sectors: ["Hardware", "Energy", "Chips"],
    score: 86,
    significance: 35,
    credibility: 24,
    timeliness: 16,
    depth: 11,
    evidence: "First-party announcement · named ecosystem partners",
    tier: "Core",
    link: "https://x.com/nvidia",
  },
  {
    id: 5,
    platform: "Substack",
    source: "Interconnects",
    handle: "Nathan Lambert",
    time: "3 hrs ago",
    minutesAgo: 184,
    title: "Why post-training is becoming a distinct scaling axis",
    summary: "A technical synthesis compares recent reasoning-model recipes and argues that data quality and environment design are now key differentiators.",
    implication: "Potentially important for the relative value accruing to labs, data vendors, and inference providers.",
    sectors: ["Labs", "Software"],
    score: 82,
    significance: 29,
    credibility: 21,
    timeliness: 16,
    depth: 16,
    evidence: "Comparative analysis · citations to model reports",
    tier: "Core",
    link: "https://www.interconnects.ai/",
  },
  {
    id: 6,
    platform: "X",
    source: "Jesse Jenkins",
    handle: "@JesseJenkins",
    time: "5 hrs ago",
    minutesAgo: 302,
    title: "New utility tariff isolates grid costs for large AI loads",
    summary: "A state filing proposes that new data-center customers fund incremental generation and transmission rather than socializing those costs.",
    implication: "The structure may become a template for hyperscaler procurement and change project economics by region.",
    sectors: ["Energy", "Hyperscalers"],
    score: 80,
    significance: 33,
    credibility: 22,
    timeliness: 14,
    depth: 11,
    evidence: "Regulatory filing linked · expert interpretation",
    tier: "Core",
    link: "https://x.com/JesseJenkins",
  },
  {
    id: 7,
    platform: "X",
    source: "Epoch AI",
    handle: "@EpochAIResearch",
    time: "7 hrs ago",
    minutesAgo: 425,
    title: "Updated compute dataset revises frontier training estimates",
    summary: "Epoch AI released new estimates and confidence intervals for recent frontier runs, including adjustments for utilization and failed experiments.",
    implication: "A better baseline for tracking whether training scale is accelerating or flattening.",
    sectors: ["Labs", "Chips"],
    score: 77,
    significance: 27,
    credibility: 23,
    timeliness: 13,
    depth: 14,
    evidence: "Dataset release · transparent methodology",
    tier: "Secondary",
    link: "https://x.com/EpochAIResearch",
  },
  {
    id: 8,
    platform: "Substack",
    source: "Import AI",
    handle: "Jack Clark",
    time: "Yesterday",
    minutesAgo: 1320,
    title: "This week in model evaluation, robotics, and AI policy",
    summary: "A broad weekly synthesis highlights a new embodied benchmark, shifting evaluation practices, and two consequential policy proposals.",
    implication: "Good context, but individual claims should be followed to their primary sources before investment use.",
    sectors: ["Labs", "Policy"],
    score: 71,
    significance: 26,
    credibility: 21,
    timeliness: 10,
    depth: 14,
    evidence: "Curated synthesis · primary links supplied",
    tier: "Secondary",
    link: "https://importai.substack.com/",
  },
];

const sources = [
  ["Andrej Karpathy", "@karpathy", "X", "Labs · software"],
  ["OpenAI", "@OpenAI", "X", "Frontier lab"],
  ["Anthropic", "@AnthropicAI", "X", "Frontier lab"],
  ["Google DeepMind", "@GoogleDeepMind", "X", "Frontier lab"],
  ["Meta AI", "@metaai", "X", "Open models · lab"],
  ["NVIDIA", "@nvidia", "X", "Chips · systems"],
  ["SemiAnalysis", "@SemiAnalysis_", "X", "Semis · infrastructure"],
  ["Dylan Patel", "@dylan522p", "X", "Semis · supply chain"],
  ["Interconnects", "@interconnectsai", "X", "Models · research"],
  ["Epoch AI", "@EpochAIResearch", "X", "Compute · benchmarks"],
  ["Jesse Jenkins", "@JesseJenkins", "X", "Energy · grid"],
  ["Brian Janous", "@BrianJanous", "X", "Data-center energy"],
  ["SemiAnalysis", "newsletter.semianalysis.com", "Substack", "Deep research"],
  ["Interconnects", "interconnects.ai", "Substack", "Research synthesis"],
  ["Import AI", "importai.substack.com", "Substack", "Research · policy"],
];

const sectorOptions = ["All", "Labs", "Memory", "Chips", "Semis", "Energy", "Hyperscalers", "Hardware", "Software", "Policy"];

function readStoredIds(key: string): number[] {
  if (typeof window === "undefined") return [];
  try {
    const value: unknown = JSON.parse(window.localStorage.getItem(key) || "[]");
    return Array.isArray(value)
      ? value.filter((item): item is number => typeof item === "number" && Number.isFinite(item))
      : [];
  } catch {
    return [];
  }
}

export default function Home() {
  const [sector, setSector] = useState("All");
  const [platform, setPlatform] = useState<"All" | Platform>("All");
  const [query, setQuery] = useState("");
  const [activeView, setActiveView] = useState<"feed" | "sources" | "rubric">("feed");
  const [saved, setSaved] = useState<number[]>(() => readStoredIds("signal-saved"));
  const [dismissed, setDismissed] = useState<number[]>(() => readStoredIds("signal-dismissed"));
  const [useful, setUseful] = useState<number[]>(() => readStoredIds("signal-useful"));
  const [expanded, setExpanded] = useState<number | null>(1);
  const [refreshed, setRefreshed] = useState("6:30 AM ET");
  const [feedSignals, setFeedSignals] = useState<Signal[]>(demoSignals);
  const [feedMeta, setFeedMeta] = useState<FeedMeta>({ mode: "demo", xConnected: false, fetchedAt: "", reviewed: 47, selected: demoSignals.length, errors: [] });
  const [refreshing, setRefreshing] = useState(false);

  const refreshFeed = async () => {
    setRefreshing(true);
    try {
      const response = await fetch("/api/feed", { cache: "no-store" });
      if (!response.ok) throw new Error(`Feed refresh returned ${response.status}`);
      const payload = await response.json() as { signals: Signal[]; meta: FeedMeta };
      if (payload.signals.length) setFeedSignals(payload.signals);
      setFeedMeta(payload.signals.length ? payload.meta : { ...payload.meta, mode: "demo" });
      setRefreshed(new Date(payload.meta.fetchedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }));
    } catch {
      setFeedMeta((current) => ({ ...current, mode: "demo" }));
    } finally {
      setRefreshing(false);
    }
  };

  useEffect(() => {
    const refreshTimer = window.setTimeout(() => {
      void refreshFeed();
    }, 0);
    return () => window.clearTimeout(refreshTimer);
  }, []);

  const persist = (key: string, value: number[]) => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem(key, JSON.stringify(value));
    }
    return value;
  };

  const toggle = (id: number, list: number[], setter: (v: number[]) => void, key: string) => {
    setter(persist(key, list.includes(id) ? list.filter((x) => x !== id) : [...list, id]));
  };

  const filtered = useMemo(() => feedSignals.filter((item) => {
    const haystack = `${item.title} ${item.summary} ${item.source} ${item.sectors.join(" ")}`.toLowerCase();
    return !dismissed.includes(item.id)
      && (sector === "All" || item.sectors.includes(sector))
      && (platform === "All" || item.platform === platform)
      && haystack.includes(query.toLowerCase());
  }), [sector, platform, query, dismissed, feedSignals]);

  const modeLabel = feedMeta.mode === "live" ? "X + RSS live" : feedMeta.mode === "rss-only" ? "RSS live" : "Demo feed";

  return (
    <main className="shell">
      <header className="topbar">
        <div className="brand-block">
          <div className="brand-mark">R<span>P</span></div>
          <div><h1>Relevant Posts</h1></div>
        </div>
        <nav aria-label="Primary navigation">
          <button className={activeView === "feed" ? "nav-active" : ""} onClick={() => setActiveView("feed")}>Morning brief</button>
          <button className={activeView === "sources" ? "nav-active" : ""} onClick={() => setActiveView("sources")}>Source book</button>
          <button className={activeView === "rubric" ? "nav-active" : ""} onClick={() => setActiveView("rubric")}>Scoring rubric</button>
        </nav>
        <div className="refresh-block">
          <span className={`live-dot ${feedMeta.mode}`} />
          <div><small>{modeLabel}</small><strong>{refreshing ? "Refreshing..." : refreshed}</strong></div>
          <button className={`refresh-button ${refreshing ? "refreshing" : ""}`} disabled={refreshing} onClick={() => void refreshFeed()} aria-label="Refresh feed">↻</button>
        </div>
      </header>

      {activeView === "feed" && <>
        <section className="brief-head">
          <div>
            <p className="date-line">TUESDAY · JULY 21, 2026</p>
            <h2>Your highest-conviction AI signals.</h2>
            <p>{feedSignals.length} items cleared today’s significance threshold across the AI stack.</p>
          </div>
          <div className="brief-stats">
            <div><strong>{feedSignals.length}</strong><span>Selected</span></div>
            <div><strong>{feedMeta.reviewed}</strong><span>Reviewed</span></div>
            <div><strong>{feedMeta.reviewed ? Math.max(0, Math.round((1 - feedSignals.length / feedMeta.reviewed) * 100)) : 0}%</strong><span>Filtered out</span></div>
          </div>
        </section>

        <section className="control-rail" aria-label="Feed filters">
          <label className="search-box"><span>⌕</span><input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search signals, sources, sectors" /></label>
          <div className="platform-toggle">
            {(["All", "X", "Substack"] as const).map((p) => <button key={p} className={platform === p ? "selected" : ""} onClick={() => setPlatform(p)}>{p}</button>)}
          </div>
        </section>
        <div className="sector-strip">
          {sectorOptions.map((s) => <button key={s} className={sector === s ? "selected" : ""} onClick={() => setSector(s)}>{s}</button>)}
        </div>

        <div className="content-grid">
          <section className="feed" aria-live="polite">
            <div className="section-label"><span>Ranked by investment significance</span><span>{filtered.length} signals</span></div>
            {filtered.map((item, index) => (
              <article className={`signal-card ${item.tier === "Secondary" ? "secondary" : ""}`} key={item.id}>
                <div className="rank">{String(index + 1).padStart(2, "0")}</div>
                <div className="signal-body">
                  <div className="signal-meta">
                    <span className={`platform ${item.platform.toLowerCase()}`}>{item.platform === "X" ? "𝕏" : "S"}</span>
                    <strong>{item.source}</strong><span>{item.handle}</span><i /> <span>{item.time}</span>
                  </div>
                  <h3>{item.title}</h3>
                  <p className="summary">{item.summary}</p>
                  <div className="tags">{item.sectors.map((tag) => <span key={tag}>{tag}</span>)}</div>
                  <div className="implication"><span>Brief implication</span><p>{item.implication}</p></div>
                  {expanded === item.id && <div className="score-detail">
                    <div><span>Significance</span><b>{item.significance}/40</b></div>
                    <div><span>Credibility</span><b>{item.credibility}/25</b></div>
                    <div><span>Timeliness</span><b>{item.timeliness}/20</b></div>
                    <div><span>Depth</span><b>{item.depth}/15</b></div>
                    <p>{item.evidence}</p>
                  </div>}
                  <div className="card-actions">
                    <button onClick={() => setExpanded(expanded === item.id ? null : item.id)}>{expanded === item.id ? "Hide score" : "Why this scored"}</button>
                    <a href={item.link} target="_blank" rel="noreferrer">Open source ↗</a>
                    <span />
                    <button className={useful.includes(item.id) ? "feedback-active" : ""} onClick={() => toggle(item.id, useful, setUseful, "signal-useful")}>↑ Useful</button>
                    <button className={saved.includes(item.id) ? "feedback-active" : ""} onClick={() => toggle(item.id, saved, setSaved, "signal-saved")}>{saved.includes(item.id) ? "◆ Saved" : "◇ Save"}</button>
                    <button onClick={() => toggle(item.id, dismissed, setDismissed, "signal-dismissed")}>× Dismiss</button>
                  </div>
                </div>
                <div className="score-ring" style={{"--score": `${item.score * 3.6}deg`} as React.CSSProperties}><div><strong>{item.score}</strong><span>score</span></div></div>
              </article>
            ))}
            {!filtered.length && <div className="empty-state"><strong>No signals match this view.</strong><p>Clear a filter or restore dismissed items from this device.</p><button onClick={() => { setSector("All"); setPlatform("All"); setQuery(""); setDismissed(persist("signal-dismissed", [])); }}>Reset feed</button></div>}
          </section>

          <aside>
            <div className="side-card watch-card">
              <p className="eyebrow">Coverage today</p><h3>AI stack watch</h3>
              {["Labs", "Chips & memory", "Energy & grid", "Hyperscalers", "Hardware"].map((label, i) => <div className="watch-row" key={label}><span>{label}</span><div><i style={{width: `${[86, 74, 61, 58, 45][i]}%`}} /></div><b>{[9, 7, 5, 4, 3][i]}</b></div>)}
            </div>
            <div className="side-card threshold-card">
              <p className="eyebrow">Quality gate</p><h3>What made the cut</h3>
              <p>Core feed requires a score of <strong>80+</strong>. Secondary context requires <strong>70+</strong> and a credible primary trail.</p>
              <div className="threshold"><span>70</span><i /><i className="core" /><span>100</span></div>
              <small>Material launches can bypass the depth requirement, but never the credibility check.</small>
            </div>
            <div className="side-card schedule-card">
              <span className="calendar">21</span><div><p className="eyebrow">Next full refresh</p><h3>Tomorrow, 6:30 AM ET</h3><small>Priority polling can later move to every 15 minutes without changing the feed.</small></div>
            </div>
            <p className="demo-note">{feedMeta.mode === "live" ? "Live X and RSS sources are connected. Scores use the visible prototype rubric." : feedMeta.mode === "rss-only" ? "Public RSS is live. Configure the X API locally to add X posts." : "Representative items are shown because no live source returned enough qualifying signals yet."}</p>
          </aside>
        </div>
      </>}

      {activeView === "sources" && <section className="page-panel">
        <p className="date-line">INITIAL MONITORING UNIVERSE</p><h2>15 deliberately narrow sources.</h2>
        <p className="panel-lead">Chosen for first-party authority or repeatable technical signal across labs, compute, memory, semiconductors, hyperscalers, and power.</p>
        <div className="source-table">
          {sources.map((source, i) => <div className="source-row" key={`${source[1]}-${source[2]}`}><span className="source-num">{String(i + 1).padStart(2, "0")}</span><strong>{source[0]}</strong><span>{source[1]}</span><em>{source[2]}</em><small>{source[3]}</small></div>)}
        </div>
      </section>}

      {activeView === "rubric" && <section className="page-panel">
        <p className="date-line">SIGNAL QUALITY MODEL · V0.1</p><h2>Significance first. Credibility always.</h2>
        <p className="panel-lead">The score is intentionally legible so an analyst can challenge it. Engagement is supporting evidence—not a quality proxy.</p>
        <div className="rubric-grid">
          <div><span>01 · 40 points</span><h3>Investment significance</h3><p>Magnitude, breadth of impact, surprise versus expectations, and relevance to the AI capital stack.</p></div>
          <div><span>02 · 25 points</span><h3>Source credibility</h3><p>First-party evidence, demonstrated expertise, transparent sourcing, and corroboration by independent sources.</p></div>
          <div><span>03 · 20 points</span><h3>Timeliness</h3><p>Freshness and whether the item advances the information set rather than recycling a known narrative.</p></div>
          <div><span>04 · 15 points</span><h3>Analytical depth</h3><p>Specificity, mechanism, data, and testable reasoning. Breaking primary news is not penalized for brevity.</p></div>
        </div>
        <div className="penalty-box"><strong>Automatic penalties</strong><span>Unsupported certainty</span><span>Recycled news</span><span>Promotion without substance</span><span>Engagement bait</span><span>Anonymous claims without corroboration</span></div>
      </section>}
    </main>
  );
}
