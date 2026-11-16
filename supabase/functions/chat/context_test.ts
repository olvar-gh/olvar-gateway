import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.13";
import {
  anchoredHistory,
  buildContextBlock,
  type ChatRow,
  condenseHourly,
  fallbackReply,
  type PlantContext,
  type StatusRow,
  type SummaryRow,
} from "./context.ts";

const PLANT = "00000000-0000-4000-8000-0000000000b1";

function row(id: number, role: "user" | "plant", content: string, replyTo: number | null = null): ChatRow {
  return {
    id,
    plant_id: PLANT,
    role,
    content,
    created_at: new Date(Date.UTC(2026, 10, 16, 0, 0, id)).toISOString(),
    based_on_reading_at: null,
    reply_to: replyTo,
    model: null,
    tokens_in: null,
    tokens_out: null,
    error: null,
  };
}

function assertAlternates(turns: { role: string }[]) {
  turns.forEach((t, i) => assertEquals(t.role, i % 2 === 0 ? "user" : "assistant", `turn ${i}`));
  assertEquals(turns.at(-1)!.role, "user");
}

Deno.test("history: completed pairs in user-id order, then the admitted message last", () => {
  const rows = [row(1, "user", "q1"), row(3, "user", "q2"), row(4, "plant", "a2", 3), row(2, "plant", "a1", 1)];
  const admitted = row(5, "user", "q3");
  const turns = anchoredHistory([...rows, admitted], admitted);
  assertEquals(turns.map((t) => t.content), ["q1", "a1", "q2", "a2", "q3"]);
  assertAlternates(turns);
});

Deno.test("history: overlapping requests A then B, both admitted before either is answered", () => {
  const done = [row(1, "user", "hello"), row(2, "plant", "hi!", 1)];
  const a = row(3, "user", "How are you?");
  const b = row(4, "user", "물 줘야 해?");
  const all = [...done, a, b];

  const forA = anchoredHistory(all, a);
  assertEquals(forA.map((t) => t.content), ["hello", "hi!", "How are you?"]);
  assertAlternates(forA);

  const forB = anchoredHistory(all, b);
  assertEquals(forB.map((t) => t.content), ["hello", "hi!", "물 줘야 해?"]);
  assert(!forB.some((t) => t.content === a.content), "B must not see A's unanswered question");
  assertAlternates(forB);
});

Deno.test("history: a later answer to an older question does not leak a newer pair into A's prompt", () => {
  const a = row(1, "user", "A");
  const b = row(2, "user", "B");
  const bReply = row(3, "plant", "answer B", 2);
  const turns = anchoredHistory([a, b, bReply], a);
  assertEquals(turns.map((t) => t.content), ["A"]);
});

Deno.test("history: keeps only the last 10 completed pairs and skips failed requests", () => {
  const rows: ChatRow[] = [];
  let id = 1;
  for (let i = 0; i < 12; i++) {
    const q = row(id++, "user", `q${i}`);
    rows.push(q);
    if (i !== 5) rows.push(row(id++, "plant", `a${i}`, q.id));
  }
  const admitted = row(id, "user", "now");
  const turns = anchoredHistory([...rows, admitted], admitted);
  assertEquals(turns.length, 21);
  assertEquals(turns[0].content, "q1");
  assert(!turns.some((t) => t.content === "q5"));
  assertAlternates(turns);
});

const STATUS: StatusRow = {
  overall: "needs_attention",
  overall_label: "Needs attention",
  summary: "Soil is getting dry — water soon",
  temperature_status: "ok",
  temperature_label: "Just right",
  humidity_status: "ok",
  humidity_label: "Just right",
  light_status: "ok",
  light_label: "Just right",
  soil_status: "low",
  soil_label: "Getting dry",
  soil_calibrated: true,
  device_status: "online",
  latest_reading_at: "2026-11-16T05:04:00Z",
  issues: ["soil"],
};

function summary(bucket: string, temp: number | null, n = 60): SummaryRow {
  return {
    bucket,
    temperature_c_n: temp === null ? 0 : n,
    temperature_c_avg: temp,
    temperature_c_min: temp === null ? null : temp - 1,
    temperature_c_max: temp === null ? null : temp + 1,
    humidity_pct_n: n,
    humidity_pct_avg: 50,
    humidity_pct_min: 45,
    humidity_pct_max: 55,
    lux_n: n,
    lux_avg: 1000,
    lux_min: 0,
    lux_max: 3000,
    soil_raw_n: n,
    soil_pct_avg: 40,
    soil_pct_min: 35,
    soil_pct_max: 45,
  };
}

const NOW = new Date("2026-11-16T05:05:00Z");

function ctx(overrides: Partial<PlantContext> = {}): PlantContext {
  return {
    nickname: "Lily",
    location: "Living room",
    timezone: "Asia/Seoul",
    commonName: "Peace lily",
    scientificName: "Spathiphyllum wallisii",
    careNotes: "Keep moist, not soggy.",
    thresholds: { soil_pct: { low: 35 } },
    status: STATUS,
    latest: {
      recorded_at: "2026-11-16T05:04:00Z",
      temperature_c: 23.44,
      humidity_pct: 48.2,
      lux: 1520,
      soil_pct: null,
    },
    hourly: [summary("2026-11-16T04:00:00Z", 22), summary("2026-11-16T03:00:00Z", 24)],
    daily: [summary("2026-11-15", 21), summary("2026-11-14", 20)],
    now: NOW,
    ...overrides,
  };
}

Deno.test("context block: local time, status, measurements, summaries, thresholds, care notes", () => {
  const block = buildContextBlock(ctx());
  assertStringIncludes(block, "LOCAL TIME: Monday 2026-11-16 14:05 (Asia/Seoul)");
  assertStringIncludes(block, "PLANT: Lily, Peace lily (Spathiphyllum wallisii), location: Living room");
  assertStringIncludes(block, "STATUS: Needs attention (needs_attention). Soil is getting dry — water soon");
  assertStringIncludes(block, "soil: Getting dry (low)");
  assertStringIncludes(block, "1 min ago");
  assertStringIncludes(block, "temperature 23.4 °C");
  assertStringIncludes(block, "soil moisture unknown");
  assertStringIncludes(block, '"soil_pct":{"low":35}');
  assertStringIncludes(block, "CARE NOTES: Keep moist, not soggy.");
  const days = block.split("\n").filter((l) => /^ {2}2026-11-1\d:/.test(l));
  assertEquals(days.map((l) => l.slice(2, 12)), ["2026-11-14", "2026-11-15"]);
});

Deno.test("context block: is a pure function of its input", () => {
  assertEquals(buildContextBlock(ctx()), buildContextBlock(ctx()));
});

Deno.test("context block: no device and no readings", () => {
  const block = buildContextBlock(ctx({ status: null, latest: null, hourly: [], daily: [] }));
  assertStringIncludes(block, "STATUS: unknown");
  assertStringIncludes(block, "MEASUREMENTS: none yet");
  assertEquals(block.match(/no data/g)?.length, 5);
});

Deno.test("context block: flags an uncalibrated soil probe", () => {
  const block = buildContextBlock(ctx({ status: { ...STATUS, soil_calibrated: false, soil_status: "unknown" } }));
  assertStringIncludes(block, "not calibrated");
});

Deno.test("condenseHourly: four 6 h blocks with n-weighted averages and overall min/max", () => {
  const rows = [
    summary("2026-11-16T04:00:00Z", 20, 60),
    summary("2026-11-16T03:00:00Z", 26, 20),
    summary("2026-11-16T00:00:00Z", null),
    summary("2026-11-15T10:00:00Z", 18),
  ];
  const blocks = condenseHourly(rows, NOW, "UTC");
  assertEquals(blocks.length, 4);
  assertStringIncludes(blocks[3], "23:05–05:05");
  assertStringIncludes(blocks[3], "temperature 19 °C / 21.5 °C / 27 °C");
  assertStringIncludes(blocks[0], "temperature 17 °C / 18 °C / 19 °C");
  assertStringIncludes(blocks[1], "no data");
});

Deno.test("fallbackReply: deterministic and built from the status summary", () => {
  assertEquals(fallbackReply(STATUS), fallbackReply(STATUS));
  assertStringIncludes(fallbackReply(STATUS), "Soil is getting dry — water soon");
  assert(fallbackReply(null).length > 0);
});
