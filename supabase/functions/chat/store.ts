import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.119.0";
import {
  type ChatRow,
  hourlyWindowStart,
  localDateWindow,
  type PlantContext,
  type Reading,
  type StatusRow,
  type SummaryRow,
} from "./context.ts";
import { AdmitError, type NewReply, type Store } from "./handler.ts";

const SUMMARY_COLS = [
  "bucket",
  ...["temperature_c", "humidity_pct", "lux"].flatMap((m) => [`${m}_n`, `${m}_avg`, `${m}_min`, `${m}_max`]),
  "soil_raw_n",
  "soil_pct_avg",
  "soil_pct_min",
  "soil_pct_max",
].join(",");

function check<T>(res: { data: T | null; error: { message: string } | null }, what: string): T {
  if (res.error) throw new Error(`${what}: ${res.error.message}`);
  return res.data as T;
}

export class SupabaseStore implements Store {
  constructor(
    private readonly url: string,
    private readonly publishableKey: string,
    private readonly admin: SupabaseClient,
  ) {}

  async canSeePlant(jwt: string, plantId: string): Promise<boolean> {
    const asUser = createClient(this.url, this.publishableKey, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const rows = check(await asUser.from("plants").select("id").eq("id", plantId).limit(1), "plant lookup");
    return rows.length === 1;
  }

  async admit(ownerId: string, plantId: string, content: string): Promise<ChatRow> {
    const { data, error } = await this.admin
      .rpc("chat_admit", { p_owner_id: ownerId, p_plant_id: plantId, p_content: content })
      .single();
    if (error) {
      if (error.code === "P0002") throw new AdmitError("not_found");
      if (error.code === "P0429") throw new AdmitError("rate_limited", Number(error.details) || 60);
      if (error.code === "22023") throw new AdmitError("invalid");
      throw new Error(`chat_admit: ${error.message}`);
    }
    return data as ChatRow;
  }

  async loadContext(plantId: string, now: Date): Promise<Omit<PlantContext, "now">> {
    const plant = check(
      await this.admin
        .from("plants")
        .select("nickname, location, timezone, profile:plant_profiles(common_name, scientific_name, care_notes)")
        .eq("id", plantId)
        .single(),
      "plant",
    ) as unknown as {
      nickname: string;
      location: string | null;
      timezone: string;
      profile: { common_name: string; scientific_name: string; care_notes: string };
    };

    const nowIso = now.toISOString();
    const hourlyFrom = hourlyWindowStart(now).toISOString();
    const [thresholds, statusRows, deviceRows] = await Promise.all([
      this.admin.rpc("effective_thresholds", { p_plant_id: plantId }).then((r) => check(r, "thresholds")),
      this.admin.from("plant_status_v").select("*").eq("plant_id", plantId).limit(1).then((r) => check(r, "status")),
      this.admin.from("devices").select("id").eq("plant_id", plantId).limit(1).then((r) => check(r, "device")),
    ]);

    let latest: Reading | null = null;
    let hourly: SummaryRow[] = [];
    let daily: SummaryRow[] = [];
    const deviceId = (deviceRows as { id: string }[])[0]?.id;
    const week = localDateWindow(now, plant.timezone, 7);
    if (deviceId) {
      const [l, h, d] = await Promise.all([
        this.admin.from("readings_v")
          .select("recorded_at, temperature_c, humidity_pct, lux, soil_pct")
          .eq("device_id", deviceId).in("clock_source", ["ntp", "backfilled"]).lte("recorded_at", nowIso)
          .order("recorded_at", { ascending: false }).limit(1)
          .then((r) => check(r, "latest reading")),
        this.admin.from("readings_hourly_v").select(SUMMARY_COLS)
          .eq("device_id", deviceId).gte("bucket", hourlyFrom).lte("bucket", nowIso)
          .order("bucket").then((r) => check(r, "hourly")),
        this.admin.from("readings_daily_v").select(SUMMARY_COLS)
          .eq("device_id", deviceId).gte("bucket", week.from).lte("bucket", week.to).order("bucket")
          .then((r) => check(r, "daily")),
      ]);
      latest = (l as Reading[])[0] ?? null;
      hourly = h as unknown as SummaryRow[];
      daily = d as unknown as SummaryRow[];
    }

    return {
      nickname: plant.nickname,
      location: plant.location,
      timezone: plant.timezone,
      commonName: plant.profile.common_name,
      scientificName: plant.profile.scientific_name,
      careNotes: plant.profile.care_notes,
      thresholds,
      status: ((statusRows as StatusRow[])[0]) ?? null,
      latest,
      hourly,
      daily,
    };
  }

  async loadHistory(plantId: string, beforeId: number): Promise<ChatRow[]> {
    const replies = check(
      await this.admin.from("chat_messages").select("*")
        .eq("plant_id", plantId).eq("role", "plant").lt("reply_to", beforeId)
        .order("reply_to", { ascending: false }).limit(10),
      "history replies",
    ) as ChatRow[];
    if (replies.length === 0) return [];
    const questions = check(
      await this.admin.from("chat_messages").select("*").in("id", replies.map((r) => r.reply_to!)),
      "history questions",
    ) as ChatRow[];
    return [...questions, ...replies];
  }

  async insertReply(row: NewReply): Promise<ChatRow> {
    return check(await this.admin.from("chat_messages").insert(row).select("*").single(), "insert reply") as ChatRow;
  }
}
