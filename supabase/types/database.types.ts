
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "graphql_public": {
          Tables: {
            [_ in never]: never
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "graphql":
{ Args: { "extensions"?: Json,"operationName"?: string,"query"?: string,"variables"?: Json }; Returns: Json
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        },"public": {
          Tables: {
            "chat_messages": {
                  Row: {
                    "based_on_reading_at": string | null,"content": string,"created_at": string,"error": string | null,"id": number,"model": string | null,"plant_id": string,"reply_to": number | null,"role": string,"tokens_in": number | null,"tokens_out": number | null
                  }
                  ComputedFields: never
                  Insert: {
                    "based_on_reading_at"?: string | null,"content": string,"created_at"?: string,"error"?: string | null,"id"?: never,"model"?: string | null,"plant_id": string,"reply_to"?: number | null,"role": string,"tokens_in"?: number | null,"tokens_out"?: number | null
                  }
                  Update: {
                    "based_on_reading_at"?: string | null,"content"?: string,"created_at"?: string,"error"?: string | null,"id"?: never,"model"?: string | null,"plant_id"?: string,"reply_to"?: number | null,"role"?: string,"tokens_in"?: number | null,"tokens_out"?: number | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "chat_messages_plant_id_fkey"
      columns: ["plant_id"]
isOneToOne: false
      referencedRelation: "plant_status_v"
      referencedColumns: ["plant_id"]
    },{
      foreignKeyName: "chat_messages_plant_id_fkey"
      columns: ["plant_id"]
isOneToOne: false
      referencedRelation: "plants"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "chat_messages_reply_to_fkey"
      columns: ["reply_to"]
isOneToOne: true
      referencedRelation: "chat_messages"
      referencedColumns: ["id"]
    }
                  ]
                },"devices": {
                  Row: {
                    "created_at": string,"fw": string | null,"id": string,"last_seen_at": string | null,"owner_id": string | null,"plant_id": string | null,"soil_calibrated_at": string | null,"soil_dry_raw": number | null,"soil_wet_raw": number | null,"status": string,"status_changed_at": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"fw"?: string | null,"id": string,"last_seen_at"?: string | null,"owner_id"?: string | null,"plant_id"?: string | null,"soil_calibrated_at"?: string | null,"soil_dry_raw"?: number | null,"soil_wet_raw"?: number | null,"status"?: string,"status_changed_at"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"fw"?: string | null,"id"?: string,"last_seen_at"?: string | null,"owner_id"?: string | null,"plant_id"?: string | null,"soil_calibrated_at"?: string | null,"soil_dry_raw"?: number | null,"soil_wet_raw"?: number | null,"status"?: string,"status_changed_at"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "devices_plant_id_fkey"
      columns: ["plant_id"]
isOneToOne: true
      referencedRelation: "plant_status_v"
      referencedColumns: ["plant_id"]
    },{
      foreignKeyName: "devices_plant_id_fkey"
      columns: ["plant_id"]
isOneToOne: true
      referencedRelation: "plants"
      referencedColumns: ["id"]
    }
                  ]
                },"gateways": {
                  Row: {
                    "buffer_depth": number | null,"id": string,"last_seen_at": string,"owner_id": string | null,"version": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "buffer_depth"?: number | null,"id": string,"last_seen_at"?: string,"owner_id"?: string | null,"version"?: string | null
                  }
                  Update: {
                    "buffer_depth"?: number | null,"id"?: string,"last_seen_at"?: string,"owner_id"?: string | null,"version"?: string | null
                  }
                  Relationships: [
                    
                  ]
                },"plant_profiles": {
                  Row: {
                    "care_notes": string,"common_name": string,"id": string,"scientific_name": string,"sources": (string)[],"thresholds": NonNullable<Json>
                  }
                  ComputedFields: never
                  Insert: {
                    "care_notes": string,"common_name": string,"id": string,"scientific_name": string,"sources"?: (string)[],"thresholds": NonNullable<Json>
                  }
                  Update: {
                    "care_notes"?: string,"common_name"?: string,"id"?: string,"scientific_name"?: string,"sources"?: (string)[],"thresholds"?: NonNullable<Json>
                  }
                  Relationships: [
                    
                  ]
                },"plants": {
                  Row: {
                    "created_at": string,"id": string,"location": string | null,"nickname": string,"owner_id": string,"profile_id": string,"threshold_overrides": NonNullable<Json>,"timezone": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"id"?: string,"location"?: string | null,"nickname"?: string,"owner_id": string,"profile_id": string,"threshold_overrides"?: NonNullable<Json>,"timezone"?: string
                  }
                  Update: {
                    "created_at"?: string,"id"?: string,"location"?: string | null,"nickname"?: string,"owner_id"?: string,"profile_id"?: string,"threshold_overrides"?: NonNullable<Json>,"timezone"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "plants_profile_id_fkey"
      columns: ["profile_id"]
isOneToOne: false
      referencedRelation: "plant_profiles"
      referencedColumns: ["id"]
    }
                  ]
                },"readings": {
                  Row: {
                    "boot_id": string,"clock_source": string,"device_id": string,"humidity_pct": number | null,"id": number,"lux": number | null,"received_at": string,"recorded_at": string,"rssi_dbm": number | null,"seq": number,"soil_raw": number | null,"temperature_c": number | null,"uptime_ms": number
                  }
                  ComputedFields: never
                  Insert: {
                    "boot_id": string,"clock_source"?: string,"device_id": string,"humidity_pct"?: number | null,"id"?: never,"lux"?: number | null,"received_at"?: string,"recorded_at": string,"rssi_dbm"?: number | null,"seq": number,"soil_raw"?: number | null,"temperature_c"?: number | null,"uptime_ms": number
                  }
                  Update: {
                    "boot_id"?: string,"clock_source"?: string,"device_id"?: string,"humidity_pct"?: number | null,"id"?: never,"lux"?: number | null,"received_at"?: string,"recorded_at"?: string,"rssi_dbm"?: number | null,"seq"?: number,"soil_raw"?: number | null,"temperature_c"?: number | null,"uptime_ms"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "readings_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "readings_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "plant_status_v"
      referencedColumns: ["device_id"]
    }
                  ]
                },"readings_daily": {
                  Row: {
                    "bucket": string,"device_id": string,"humidity_pct_avg": number | null,"humidity_pct_max": number | null,"humidity_pct_min": number | null,"humidity_pct_n": number,"lux_avg": number | null,"lux_max": number | null,"lux_min": number | null,"lux_n": number,"n": number,"sealed": boolean,"soil_raw_avg": number | null,"soil_raw_counts": (number)[],"soil_raw_max": number | null,"soil_raw_min": number | null,"soil_raw_n": number,"soil_raw_values": (number)[],"temperature_c_avg": number | null,"temperature_c_max": number | null,"temperature_c_min": number | null,"temperature_c_n": number
                  }
                  ComputedFields: never
                  Insert: {
                    "bucket": string,"device_id": string,"humidity_pct_avg"?: number | null,"humidity_pct_max"?: number | null,"humidity_pct_min"?: number | null,"humidity_pct_n": number,"lux_avg"?: number | null,"lux_max"?: number | null,"lux_min"?: number | null,"lux_n": number,"n": number,"sealed"?: boolean,"soil_raw_avg"?: number | null,"soil_raw_counts"?: (number)[],"soil_raw_max"?: number | null,"soil_raw_min"?: number | null,"soil_raw_n": number,"soil_raw_values"?: (number)[],"temperature_c_avg"?: number | null,"temperature_c_max"?: number | null,"temperature_c_min"?: number | null,"temperature_c_n": number
                  }
                  Update: {
                    "bucket"?: string,"device_id"?: string,"humidity_pct_avg"?: number | null,"humidity_pct_max"?: number | null,"humidity_pct_min"?: number | null,"humidity_pct_n"?: number,"lux_avg"?: number | null,"lux_max"?: number | null,"lux_min"?: number | null,"lux_n"?: number,"n"?: number,"sealed"?: boolean,"soil_raw_avg"?: number | null,"soil_raw_counts"?: (number)[],"soil_raw_max"?: number | null,"soil_raw_min"?: number | null,"soil_raw_n"?: number,"soil_raw_values"?: (number)[],"temperature_c_avg"?: number | null,"temperature_c_max"?: number | null,"temperature_c_min"?: number | null,"temperature_c_n"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "readings_daily_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "readings_daily_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "plant_status_v"
      referencedColumns: ["device_id"]
    }
                  ]
                },"readings_hourly": {
                  Row: {
                    "bucket": string,"device_id": string,"humidity_pct_avg": number | null,"humidity_pct_max": number | null,"humidity_pct_min": number | null,"humidity_pct_n": number,"lux_avg": number | null,"lux_max": number | null,"lux_min": number | null,"lux_n": number,"n": number,"sealed": boolean,"soil_raw_avg": number | null,"soil_raw_counts": (number)[],"soil_raw_max": number | null,"soil_raw_min": number | null,"soil_raw_n": number,"soil_raw_values": (number)[],"temperature_c_avg": number | null,"temperature_c_max": number | null,"temperature_c_min": number | null,"temperature_c_n": number
                  }
                  ComputedFields: never
                  Insert: {
                    "bucket": string,"device_id": string,"humidity_pct_avg"?: number | null,"humidity_pct_max"?: number | null,"humidity_pct_min"?: number | null,"humidity_pct_n": number,"lux_avg"?: number | null,"lux_max"?: number | null,"lux_min"?: number | null,"lux_n": number,"n": number,"sealed"?: boolean,"soil_raw_avg"?: number | null,"soil_raw_counts"?: (number)[],"soil_raw_max"?: number | null,"soil_raw_min"?: number | null,"soil_raw_n": number,"soil_raw_values"?: (number)[],"temperature_c_avg"?: number | null,"temperature_c_max"?: number | null,"temperature_c_min"?: number | null,"temperature_c_n": number
                  }
                  Update: {
                    "bucket"?: string,"device_id"?: string,"humidity_pct_avg"?: number | null,"humidity_pct_max"?: number | null,"humidity_pct_min"?: number | null,"humidity_pct_n"?: number,"lux_avg"?: number | null,"lux_max"?: number | null,"lux_min"?: number | null,"lux_n"?: number,"n"?: number,"sealed"?: boolean,"soil_raw_avg"?: number | null,"soil_raw_counts"?: (number)[],"soil_raw_max"?: number | null,"soil_raw_min"?: number | null,"soil_raw_n"?: number,"soil_raw_values"?: (number)[],"temperature_c_avg"?: number | null,"temperature_c_max"?: number | null,"temperature_c_min"?: number | null,"temperature_c_n"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "readings_hourly_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "readings_hourly_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "plant_status_v"
      referencedColumns: ["device_id"]
    }
                  ]
                },"rollup_seals": {
                  Row: {
                    "device_id": string,"late_rows_ignored": number,"sealed_before": string
                  }
                  ComputedFields: never
                  Insert: {
                    "device_id": string,"late_rows_ignored"?: number,"sealed_before": string
                  }
                  Update: {
                    "device_id"?: string,"late_rows_ignored"?: number,"sealed_before"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "rollup_seals_device_id_fkey"
      columns: ["device_id"]
isOneToOne: true
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "rollup_seals_device_id_fkey"
      columns: ["device_id"]
isOneToOne: true
      referencedRelation: "plant_status_v"
      referencedColumns: ["device_id"]
    }
                  ]
                },"rollup_state": {
                  Row: {
                    "id": boolean,"processed_until": string
                  }
                  ComputedFields: never
                  Insert: {
                    "id"?: boolean,"processed_until"?: string
                  }
                  Update: {
                    "id"?: boolean,"processed_until"?: string
                  }
                  Relationships: [
                    
                  ]
                }
          }
          Views: {
            "plant_status_v": {
                  Row: {
                    "computed_at": string | null,"device_id": string | null,"device_status": string | null,"humidity_label": string | null,"humidity_status": string | null,"issues": (string)[] | null,"latest_reading_at": string | null,"light_label": string | null,"light_status": string | null,"overall": string | null,"overall_label": string | null,"plant_id": string,"soil_calibrated": boolean | null,"soil_label": string | null,"soil_status": string | null,"summary": string | null,"temperature_label": string | null,"temperature_status": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"readings_daily_v": {
                  Row: {
                    "bucket": string,"device_id": string,"humidity_pct_avg": number | null,"humidity_pct_max": number | null,"humidity_pct_min": number | null,"humidity_pct_n": number,"lux_avg": number | null,"lux_max": number | null,"lux_min": number | null,"lux_n": number,"n": number,"sealed": boolean,"soil_pct_avg": number | null,"soil_pct_max": number | null,"soil_pct_min": number | null,"soil_raw_avg": number | null,"soil_raw_counts": (number)[],"soil_raw_max": number | null,"soil_raw_min": number | null,"soil_raw_n": number,"soil_raw_values": (number)[],"temperature_c_avg": number | null,"temperature_c_max": number | null,"temperature_c_min": number | null,"temperature_c_n": number
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "readings_daily_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "readings_daily_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "plant_status_v"
      referencedColumns: ["device_id"]
    }
                  ]
                },"readings_hourly_v": {
                  Row: {
                    "bucket": string,"device_id": string,"humidity_pct_avg": number | null,"humidity_pct_max": number | null,"humidity_pct_min": number | null,"humidity_pct_n": number,"lux_avg": number | null,"lux_max": number | null,"lux_min": number | null,"lux_n": number,"n": number,"sealed": boolean,"soil_pct_avg": number | null,"soil_pct_max": number | null,"soil_pct_min": number | null,"soil_raw_avg": number | null,"soil_raw_counts": (number)[],"soil_raw_max": number | null,"soil_raw_min": number | null,"soil_raw_n": number,"soil_raw_values": (number)[],"temperature_c_avg": number | null,"temperature_c_max": number | null,"temperature_c_min": number | null,"temperature_c_n": number
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "readings_hourly_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "readings_hourly_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "plant_status_v"
      referencedColumns: ["device_id"]
    }
                  ]
                },"readings_v": {
                  Row: {
                    "boot_id": string,"clock_source": string,"device_id": string,"humidity_pct": number | null,"id": number,"lux": number | null,"received_at": string,"recorded_at": string,"rssi_dbm": number | null,"seq": number,"soil_pct": number | null,"soil_raw": number | null,"temperature_c": number | null,"uptime_ms": number
                  }
                  ComputedFields: never
                  Relationships: [
                    {
      foreignKeyName: "readings_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "devices"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "readings_device_id_fkey"
      columns: ["device_id"]
isOneToOne: false
      referencedRelation: "plant_status_v"
      referencedColumns: ["device_id"]
    }
                  ]
                }
          }
          Functions: {
            "apply_retention":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"chat_admit":
{ Args: { "p_content": string,"p_owner_id": string,"p_plant_id": string }; Returns: {
              "based_on_reading_at": string | null,
"content": string,
"created_at": string,
"error": string | null,
"id": number,
"model": string | null,
"plant_id": string,
"reply_to": number | null,
"role": string,
"tokens_in": number | null,
"tokens_out": number | null
            }
                          SetofOptions: {
        from: "*"
        to: "chat_messages"
        isOneToOne: true
        isSetofReturn: false
      } },
"device_offline_periods":
{ Args: { "p_device_id": string,"p_from": string,"p_to": string }; Returns: {
              "cause": string,"duration_s": number,"ended_at": string,"ongoing": boolean,"started_at": string
            }[]
                           },
"effective_thresholds":
{ Args: { "p_plant_id": string }; Returns: Json
                           },
"in_middle_half":
{ Args: { "t": Json,"v": number }; Returns: boolean
                           },
"rebuild_daily_for_timezone":
{ Args: { "p_device_id": string }; Returns: undefined
                           },
"rebuild_rollups":
{ Args: { "p_device_id": string,"p_from": string,"p_to": string }; Returns: undefined
                           },
"refresh_rollups":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"rollup_aggregate":
{ Args: { "p_device_ids": (string)[],"p_ends": (string)[],"p_starts": (string)[] }; Returns: {
              "bucket_start": string,"device_id": string,"humidity_pct_avg": number,"humidity_pct_max": number,"humidity_pct_min": number,"humidity_pct_n": number,"lux_avg": number,"lux_max": number,"lux_min": number,"lux_n": number,"n": number,"soil_raw_avg": number,"soil_raw_counts": (number)[],"soil_raw_max": number,"soil_raw_min": number,"soil_raw_n": number,"soil_raw_values": (number)[],"temperature_c_avg": number,"temperature_c_max": number,"temperature_c_min": number,"temperature_c_n": number
            }[]
                           },
"rollup_catch_up":
{ Args: Record<PropertyKey, never>; Returns: undefined
                           },
"rollup_write_daily":
{ Args: { "p_days": (string)[],"p_device_ids": (string)[] }; Returns: number
                           },
"rollup_write_hourly":
{ Args: { "p_buckets": (string)[],"p_device_ids": (string)[] }; Returns: number
                           },
"soil_pct":
{ Args: { "dry_raw": number,"raw": number,"wet_raw": number }; Returns: number
                           },
"soil_pct_avg":
{ Args: { "cnts": (number)[],"dry_raw": number,"vals": (number)[],"wet_raw": number }; Returns: number
                           },
"threshold_status":
{ Args: { "t": Json,"v": number }; Returns: string
                           },
"valid_threshold_overrides":
{ Args: { "o": Json }; Returns: boolean
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "graphql_public": {
          Enums: {
            
          }
        },"public": {
          Enums: {
            
          }
        }
} as const
