export const dynamic = "force-dynamic";

type Platform = "X" | "Substack";

type Candidate = {
  platform: Platform;
  source: string;
  handle: string;
  text: string;
  title?: string;
  url: string;
  publishedAt: Date;
  credibility: number;
  firstParty?: boolean;
  metrics?: { likes?: number; reposts?: number; replies?: number };
};

type RankedSignal = {
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

const xSources = [
  { username: "karpathy", name: "Andrej Karpathy", credibility: 24, firstParty: false },
  { username: "OpenAI", name: "OpenAI", credibility: 25, firstParty: true },
  { username: "AnthropicAI", name: "Anthropic", credibility: 25, firstParty: true },
  { username: "GoogleDeepMind", name: "Google DeepMind", credibility: 25, firstParty: true },
  { username: "metaai", name: "Meta AI", credibility: 24, firstParty: true },
  { username: "nvidia", name: "NVIDIA", credibility: 25, firstParty: true },
  { username: "SemiAnalysis_", name: "SemiAnalysis", credibility: 23, firstParty: false },
  { username: "dylan522p", name: "Dylan Patel", credibility: 23, firstParty: false },
  { username: "interconnectsai", name: "Interconnects", credibility: 22, firstParty: false },
  { username: "EpochAIResearch", name: "Epoch AI", credibility: 23, firstParty: false },
  { username: "JesseJenkins", name: "Jesse Jenkins", credibility: 23, firstParty: false },
  { username: "BrianJanous", name: "Brian Janous", credibility: 21, firstParty: false },
] as const;

const rssSources = [
  { name: "SemiAnalysis", handle: "SemiAnalysis", url: "https://newsletter.semianalysis.com/feed", credibility: 23 },
  { name: "Interconnects", handle: "Nathan Lambert", url: "https://www.interconnects.ai/feed", credibility: 22 },
  { name: "Import AI", handle: "Jack Clark", url: "https://importai.substack.com/feed", credibility: 22 },
] as const;

const sectorKeywords: Record<string, string[]> = {
  Labs: ["model", "training", "inference", "benchmark", "agent", "reasoning", "research", "llm", "frontier"],
  Memory: ["memory", "hbm", "dram", "nand", "bandwidth"],
  Chips: ["gpu", "accelerator", "chip", "silicon", "compute", "asic", "tpu"],
  Semis: ["semiconductor", "foundry", "fab", "wafer", "packaging", "tsmc", "lithography"],
  Energy: ["energy", "power", "electricity", "grid", "utility", "nuclear", "cooling", "800v"],
  Hyperscalers: ["hyperscaler", "cloud", "aws", "azure", "google cloud", "data center", "datacenter", "capex"],
  Hardware: ["rack", "server", "networking", "optics", "interconnect", "hardware"],
  Software: ["software", "developer", "coding", "api", "tool use", "post-training"],
  Policy: ["policy", "regulation", "export control", "tariff", "government", "safety"],
};

const impactTerms = [
  "announce", "launch", "release", "new model", "availability", "breakthrough", "partnership",
  "acquisition", "capacity", "guidance", "capex", "supply", "shortage", "production", "roadmap",
  "benchmark", "price", "cost", "revenue", "export control", "tariff", "data center", "datacenter",
  "hbm", "memory", "gpu", "power", "grid", "800v", "inference", "training",
];

function decodeXml(value: string) {
  return value
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/\s+/g, " ")
    .trim();
}

function tag(block: string, name: string) {
  const match = block.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/${name}>`, "i"));
  return match ? decodeXml(match[1]) : "";
}

function hashString(value: string) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return Math.abs(hash >>> 0);
}

function clip(value: string, length: number) {
  if (value.length <= length) return value;
  return `${value.slice(0, length).replace(/\s+\S*$/, "").trim()}...`;
}

function detectSectors(text: string) {
  const normalized = text.toLowerCase();
  const matches = Object.entries(sectorKeywords)
    .filter(([, keywords]) => keywords.some((keyword) => normalized.includes(keyword)))
    .map(([sector]) => sector);
  return matches.length ? matches.slice(0, 3) : ["Labs"];
}

function relativeTime(minutes: number) {
  if (minutes < 60) return `${Math.max(1, minutes)} min ago`;
  if (minutes < 24 * 60) return `${Math.floor(minutes / 60)} hr${minutes < 120 ? "" : "s"} ago`;
  if (minutes < 48 * 60) return "Yesterday";
  return `${Math.floor(minutes / (24 * 60))} days ago`;
}

function implicationFor(sectors: string[]) {
  if (sectors.includes("Memory")) return "Test whether this changes HBM availability, memory content, or supplier pricing power.";
  if (sectors.includes("Energy")) return "Check whether this changes regional power availability, project timing, or data-center economics.";
  if (sectors.includes("Chips") || sectors.includes("Semis")) return "Map the claim to shipment timing, bottlenecks, and likely value capture across the semiconductor chain.";
  if (sectors.includes("Hyperscalers")) return "Compare the signal with current capex, utilization, and cloud-margin expectations.";
  if (sectors.includes("Policy")) return "Follow the primary proposal and identify the companies, geographies, and timelines directly exposed.";
  return "Determine whether the development changes capability, cost, adoption, or competitive positioning.";
}

function scoreCandidate(candidate: Candidate, now: Date): RankedSignal {
  const normalized = `${candidate.title || ""} ${candidate.text}`.toLowerCase();
  const sectors = detectSectors(normalized);
  const minutesAgo = Math.max(0, Math.floor((now.getTime() - candidate.publishedAt.getTime()) / 60000));
  const matchedImpactTerms = impactTerms.filter((term) => normalized.includes(term)).length;
  const hasNumbers = /\b\d+(?:\.\d+)?%?|\$\d+/i.test(normalized);
  const engagement = (candidate.metrics?.likes || 0) + 2 * (candidate.metrics?.reposts || 0) + (candidate.metrics?.replies || 0);
  const lowSignal = /\b(giveaway|gm|lol|meme|subscribe now|sponsored)\b/i.test(normalized);

  const significance = Math.min(40, 17 + Math.min(15, matchedImpactTerms * 3) + (hasNumbers ? 3 : 0) + (candidate.firstParty ? 3 : 0) + Math.min(2, Math.floor(Math.log10(engagement + 1))));
  const timeliness = minutesAgo <= 60 ? 20 : minutesAgo <= 180 ? 18 : minutesAgo <= 480 ? 15 : minutesAgo <= 1440 ? 12 : minutesAgo <= 2880 ? 8 : 4;
  const depth = Math.min(15, 5 + (candidate.text.length >= 220 ? 4 : candidate.text.length >= 120 ? 2 : 0) + (hasNumbers ? 2 : 0) + (/https?:\/\//.test(candidate.text) || candidate.platform === "Substack" ? 2 : 0) + (matchedImpactTerms >= 2 ? 2 : 0));
  const credibility = candidate.credibility;
  const score = Math.max(0, significance + credibility + timeliness + depth - (lowSignal ? 12 : 0));
  const cleanText = decodeXml(candidate.text);
  const title = candidate.title || clip(cleanText.replace(/^https?:\/\/\S+\s*/, ""), 112);

  return {
    id: hashString(candidate.url),
    platform: candidate.platform,
    source: candidate.source,
    handle: candidate.handle,
    time: relativeTime(minutesAgo),
    minutesAgo,
    title,
    summary: clip(cleanText, 310),
    implication: implicationFor(sectors),
    sectors,
    score,
    significance,
    credibility,
    timeliness,
    depth,
    evidence: candidate.platform === "X"
      ? `${candidate.firstParty ? "First-party" : "Named expert"} X post · direct source`
      : "Publisher RSS · source-linked article",
    tier: score >= 80 ? "Core" : "Secondary",
    link: candidate.url,
  };
}

async function fetchRssSource(source: typeof rssSources[number]): Promise<Candidate[]> {
  const response = await fetch(source.url, { headers: { "User-Agent": "SignalDesk/0.1" } });
  if (!response.ok) throw new Error(`${source.name} RSS returned ${response.status}`);
  const xml = await response.text();
  const blocks = xml.match(/<item(?:\s[^>]*)?>[\s\S]*?<\/item>/gi) || [];

  return blocks.slice(0, 8).map((block) => {
    const link = tag(block, "link") || tag(block, "guid");
    const dateValue = tag(block, "pubDate") || tag(block, "published") || tag(block, "updated");
    return {
      platform: "Substack" as const,
      source: source.name,
      handle: source.handle,
      title: tag(block, "title"),
      text: tag(block, "description") || tag(block, "content:encoded") || tag(block, "title"),
      url: link,
      publishedAt: dateValue ? new Date(dateValue) : new Date(),
      credibility: source.credibility,
    };
  }).filter((item) => item.url && !Number.isNaN(item.publishedAt.getTime()));
}

async function fetchXSource(source: typeof xSources[number], bearerToken: string): Promise<Candidate[]> {
  const params = new URLSearchParams({
    max_results: "10",
    exclude: "retweets,replies",
    "tweet.fields": "created_at,public_metrics",
  });
  const endpoint = `https://api.x.com/2/users/by/username/${encodeURIComponent(source.username)}/tweets?${params}`;
  const response = await fetch(endpoint, { headers: { Authorization: `Bearer ${bearerToken}` } });
  if (!response.ok) throw new Error(`@${source.username} returned ${response.status}`);
  const payload = await response.json() as {
    data?: Array<{
      id: string;
      text: string;
      created_at?: string;
      public_metrics?: { like_count?: number; retweet_count?: number; reply_count?: number };
    }>;
  };

  return (payload.data || []).map((post) => ({
    platform: "X" as const,
    source: source.name,
    handle: `@${source.username}`,
    text: post.text,
    url: `https://x.com/${source.username}/status/${post.id}`,
    publishedAt: post.created_at ? new Date(post.created_at) : new Date(),
    credibility: source.credibility,
    firstParty: source.firstParty,
    metrics: {
      likes: post.public_metrics?.like_count,
      reposts: post.public_metrics?.retweet_count,
      replies: post.public_metrics?.reply_count,
    },
  }));
}

export async function GET() {
  const now = new Date();
  const bearerToken = process.env.X_BEARER_TOKEN?.trim();
  const jobs: Array<Promise<Candidate[]>> = rssSources.map(fetchRssSource);
  if (bearerToken) jobs.push(...xSources.map((source) => fetchXSource(source, bearerToken)));

  const settled = await Promise.allSettled(jobs);
  const candidates = settled.flatMap((result) => result.status === "fulfilled" ? result.value : []);
  const errors = settled.flatMap((result) => result.status === "rejected" ? [String(result.reason?.message || result.reason)] : []);
  const seen = new Set<string>();
  const ranked = candidates
    .filter((candidate) => {
      const key = candidate.url || candidate.text.toLowerCase().replace(/\W/g, "").slice(0, 120);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .map((candidate) => scoreCandidate(candidate, now))
    .filter((signal) => signal.score >= 70 && signal.minutesAgo <= 90 * 24 * 60)
    .sort((a, b) => b.score - a.score || a.minutesAgo - b.minutesAgo)
    .slice(0, 20);

  return Response.json({
    signals: ranked,
    meta: {
      mode: ranked.length ? (bearerToken ? "live" : "rss-only") : "demo",
      xConnected: Boolean(bearerToken),
      fetchedAt: now.toISOString(),
      reviewed: candidates.length,
      selected: ranked.length,
      errors,
    },
  }, { headers: { "Cache-Control": "no-store" } });
}
