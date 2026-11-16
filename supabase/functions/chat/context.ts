import type { ChatTurn } from "./deepseek.ts";

export interface ChatRow {
  id: number;
  plant_id: string;
  role: "user" | "plant";
  content: string;
  created_at: string;
  based_on_reading_at: string | null;
  reply_to: number | null;
  model: string | null;
  tokens_in: number | null;
  tokens_out: number | null;
  error: string | null;
}

export interface StatusRow {
  overall: string;
  overall_label: string;
  summary: string;
  temperature_status: string;
  temperature_label: string;
  humidity_status: string;
  humidity_label: string;
  light_status: string;
  light_label: string;
  soil_status: string;
  soil_label: string;
  soil_calibrated: boolean | null;
  device_status: string | null;
  latest_reading_at: string | null;
  issues: string[] | null;
}

export interface Reading {
  recorded_at: string;
  temperature_c: number | null;
  humidity_pct: number | null;
  lux: number | null;
  soil_pct: number | null;
}

type MetricCols<P extends string> =
  & { [K in `${P}_avg` | `${P}_min` | `${P}_max`]: number | null }
  & { [K in `${P}_n`]: number };

export type SummaryRow =
  & { bucket: string }
  & MetricCols<"temperature_c">
  & MetricCols<"humidity_pct">
  & MetricCols<"lux">
  & { soil_raw_n: number; soil_pct_avg: number | null; soil_pct_min: number | null; soil_pct_max: number | null };

export interface PlantContext {
  nickname: string;
  location: string | null;
  timezone: string;
  commonName: string;
  scientificName: string;
  careNotes: string;
  thresholds: unknown;
  status: StatusRow | null;
  latest: Reading | null;
  hourly: SummaryRow[];
  daily: SummaryRow[];
  now: Date;
}

export const HISTORY_PAIRS = 10;

// Completed pairs strictly before the admitted message, then that message last (D23). Unanswered user rows belong
// to overlapping or failed requests and are left out, so turns always alternate.
export function anchoredHistory(rows: ChatRow[], admitted: ChatRow, maxPairs = HISTORY_PAIRS): ChatTurn[] {
  const replies = new Map<number, ChatRow>();
  for (const r of rows) if (r.role === "plant" && r.reply_to !== null) replies.set(r.reply_to, r);
  const pairs = rows
    .filter((r) => r.role === "user" && r.id < admitted.id && replies.has(r.id))
    .sort((a, b) => a.id - b.id)
    .slice(-maxPairs);
  const turns: ChatTurn[] = [];
  for (const q of pairs) {
    turns.push({ role: "user", content: q.content });
    turns.push({ role: "assistant", content: replies.get(q.id)!.content });
  }
  turns.push({ role: "user", content: admitted.content });
  return turns;
}

function localParts(d: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    weekday: "long",
    hourCycle: "h23",
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return { date: `${get("year")}-${get("month")}-${get("day")}`, time: `${get("hour")}:${get("minute")}`, weekday: get("weekday") };
}

export function localTime(d: Date, timeZone: string): string {
  const p = localParts(d, timeZone);
  return `${p.weekday} ${p.date} ${p.time}`;
}

function fmt(v: number | null | undefined, unit: string, digits = 1): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return "unknown";
  return `${Number(v.toFixed(digits))}${unit}`;
}

function ago(from: Date, to: Date): string {
  const min = Math.max(0, Math.round((to.getTime() - from.getTime()) / 60_000));
  if (min < 60) return `${min} min ago`;
  if (min < 48 * 60) return `${Math.round(min / 60)} h ago`;
  return `${Math.round(min / 1440)} days ago`;
}

interface Agg {
  n: number;
  sum: number;
  min: number | null;
  max: number | null;
}

function addAgg(a: Agg, n: number, avg: number | null, min: number | null, max: number | null) {
  if (n > 0 && avg !== null) {
    a.n += n;
    a.sum += avg * n;
  }
  if (min !== null) a.min = a.min === null ? min : Math.min(a.min, min);
  if (max !== null) a.max = a.max === null ? max : Math.max(a.max, max);
}

function aggText(a: Agg, unit: string, digits = 1): string {
  if (a.n === 0) return "no data";
  return `${fmt(a.min, unit, digits)} / ${fmt(a.sum / a.n, unit, digits)} / ${fmt(a.max, unit, digits)}`;
}

function summaryLine(rows: SummaryRow[]): string {
  const t: Agg = { n: 0, sum: 0, min: null, max: null };
  const h: Agg = { ...t }, l: Agg = { ...t }, s: Agg = { ...t };
  for (const r of rows) {
    addAgg(t, r.temperature_c_n, r.temperature_c_avg, r.temperature_c_min, r.temperature_c_max);
    addAgg(h, r.humidity_pct_n, r.humidity_pct_avg, r.humidity_pct_min, r.humidity_pct_max);
    addAgg(l, r.lux_n, r.lux_avg, r.lux_min, r.lux_max);
    addAgg(s, r.soil_pct_avg === null ? 0 : r.soil_raw_n, r.soil_pct_avg, r.soil_pct_min, r.soil_pct_max);
  }
  return `temperature ${aggText(t, " °C")}; humidity ${aggText(h, " %", 0)}; light ${aggText(l, " lx", 0)}; ` +
    `soil ${aggText(s, " %", 0)}`;
}

// Four 6-hour blocks ending at `now`, so the prompt stays small (§2.7).
export function condenseHourly(rows: SummaryRow[], now: Date, timeZone: string): string[] {
  const out: string[] = [];
  const end = now.getTime();
  for (let i = 3; i >= 0; i--) {
    const from = end - (i + 1) * 6 * 3_600_000;
    const to = end - i * 6 * 3_600_000;
    const block = rows.filter((r) => {
      const t = Date.parse(r.bucket);
      return t >= from && t < to;
    });
    const label = `${localParts(new Date(from), timeZone).time}–${localParts(new Date(to), timeZone).time}`;
    out.push(`  ${label}: ${block.length ? summaryLine(block) : "no data"}`);
  }
  return out;
}

export function buildContextBlock(c: PlantContext): string {
  const lines: string[] = [];
  lines.push(`LOCAL TIME: ${localTime(c.now, c.timezone)} (${c.timezone})`);
  lines.push(
    `PLANT: ${c.nickname}, ${c.commonName} (${c.scientificName})` + (c.location ? `, location: ${c.location}` : ""),
  );

  const s = c.status;
  if (s) {
    lines.push(`STATUS: ${s.overall_label} (${s.overall}). ${s.summary}`);
    lines.push(
      `  temperature: ${s.temperature_label} (${s.temperature_status}); humidity: ${s.humidity_label} ` +
        `(${s.humidity_status}); light: ${s.light_label} (${s.light_status}); soil: ${s.soil_label} (${s.soil_status})`,
    );
    if (!s.soil_calibrated) lines.push("  soil probe: not calibrated, so soil moisture is unknown");
    if (s.device_status) lines.push(`  sensor device: ${s.device_status}`);
  } else {
    lines.push("STATUS: unknown (no sensor device)");
  }

  const r = c.latest;
  if (r) {
    lines.push(
      `MEASUREMENTS (latest reading ${localTime(new Date(r.recorded_at), c.timezone)}, ` +
        `${ago(new Date(r.recorded_at), c.now)}): temperature ${fmt(r.temperature_c, " °C")}, ` +
        `humidity ${fmt(r.humidity_pct, " %", 0)}, light ${fmt(r.lux, " lx", 0)}, soil moisture ${fmt(r.soil_pct, " %", 0)}`,
    );
  } else {
    lines.push("MEASUREMENTS: none yet");
  }

  lines.push("LAST 24 H (6-hour blocks, min / avg / max):");
  lines.push(...condenseHourly(c.hourly, c.now, c.timezone));

  lines.push("LAST 7 DAYS (daily min / avg / max):");
  const days = [...c.daily].sort((a, b) => a.bucket.localeCompare(b.bucket)).slice(-7);
  if (days.length === 0) lines.push("  no data");
  for (const d of days) lines.push(`  ${d.bucket}: ${summaryLine([d])}`);

  lines.push(`THRESHOLDS: ${JSON.stringify(c.thresholds)}`);
  lines.push(`CARE NOTES: ${c.careNotes}`);
  return lines.join("\n");
}

export function fallbackReply(status: StatusRow | null): string {
  const summary = status?.summary ? ` ${status.summary}.` : "";
  return `I can't find my words right now — please try again in a moment.${summary}`.slice(0, 2000);
}
