import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export interface Database {
  public: {
    Tables: {
      profiles: {
        Row: { id: string; display_name: string; avatar_path: string | null; created_at: string; updated_at: string };
        Insert: { id: string; display_name?: string; avatar_path?: string | null };
        Update: { display_name?: string; avatar_path?: string | null };
        Relationships: [];
      };
      trips: {
        Row: { id: string; owner_id: string; name: string; destination: string | null; notes: string | null; start_date: string; end_date: string; budget: number | null; base_currency: string; created_at: string; updated_at: string };
        Insert: { id?: string; owner_id: string; name: string; destination?: string | null; notes?: string | null; start_date: string; end_date: string; budget?: number | null; base_currency?: string };
        Update: { name?: string; destination?: string | null; notes?: string | null; start_date?: string; end_date?: string; budget?: number | null; base_currency?: string };
        Relationships: [];
      };
      trip_members: {
        Row: { id: string; trip_id: string; user_id: string | null; display_name: string | null; role: 'owner' | 'member'; created_at: string };
        Insert: { id?: string; trip_id: string; user_id?: string | null; display_name?: string | null; role?: 'owner' | 'member' };
        Update: never;
        Relationships: [];
      };
      bills: {
        Row: { id: string; trip_id: string; creator_id: string; name: string; description: string | null; currency: string; created_at: string; updated_at: string };
        Insert: { id?: string; trip_id: string; creator_id: string; name: string; description?: string | null; currency?: string };
        Update: { name?: string; description?: string | null; currency?: string };
        Relationships: [];
      };
      expenses: {
        Row: { id: string; bill_id: string; trip_id: string; creator_id: string; description: string; original_amount: number; original_currency: string; base_amount: number; exchange_rate: number; payer_member_id: string; split_method: 'equal' | 'custom'; receipt_path: string | null; expense_date: string; created_at: string; updated_at: string };
        Insert: never;
        Update: never;
        Relationships: [];
      };
      expense_splits: {
        Row: { id: string; expense_id: string; participant_member_id: string; base_amount: number; original_amount: number | null; created_at: string };
        Insert: never;
        Update: never;
        Relationships: [];
      };
    };
    Views: Record<string, never>;
    Functions: {
      create_trip_with_members: {
        Args: {
          p_name: string; p_destination: string | null; p_notes: string | null;
          p_start_date: string; p_end_date: string; p_budget: number | null;
          p_member_names: string[]; p_base_currency?: string;
        };
        Returns: string;
      };
      create_expense_with_splits: {
        Args: {
          p_id: string; p_bill_id: string; p_trip_id: string; p_description: string;
          p_original_amount: number; p_original_currency: string; p_base_amount: number;
          p_exchange_rate: number; p_payer_member_id: string; p_expense_date: string;
          p_splits: Json; p_receipt_path?: string | null; p_split_method?: 'equal' | 'custom';
        };
        Returns: string;
      };
    };
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
}

export class SupabaseSetupError extends Error {
  constructor() {
    super('Supabase is not configured. Copy .env.example to .env.local and add your project URL and publishable/anon key.');
    this.name = 'SupabaseSetupError';
  }
}

const url = import.meta.env.VITE_SUPABASE_URL?.trim();
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim() || import.meta.env.VITE_SUPABASE_ANON_KEY?.trim();

export const supabaseConfigured = Boolean(url && publishableKey);

let client: SupabaseClient<Database> | null = null;

/** Return the shared browser client, or a readable setup error when credentials are absent. */
export function getSupabaseClient(): SupabaseClient<Database> {
  if (!url || !publishableKey) throw new SupabaseSetupError();
  client ??= createClient<Database>(url, publishableKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  });
  return client;
}
