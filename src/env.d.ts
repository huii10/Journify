interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string;
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string;
  readonly VITE_SUPABASE_ANON_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface TripUiRecord {
  id: string;
  name: string;
  start: string;
  end: string;
  notes: string;
  budget: number | null;
  travellers: number;
  members: string[];
  memberRecords: Array<{ id: string; display_name: string | null; user_id: string | null; role: 'owner' | 'member' }>;
  ownerId: string;
}

interface Window {
  journifySetTrips?: (trips: TripUiRecord[]) => void;
  journifyCreateTripRpc?: (input: { name: string; startDate: string; endDate: string; notes: string; budget: number | null; memberNames: string[] }) => Promise<string>;
  journifyReloadTrips?: () => Promise<void>;
  journifyAddTripMember?: (input: { tripId: string; displayName: string }) => Promise<void>;
  journifyRemoveTripMember?: (memberId: string) => Promise<void>;
  journifyUserId?: string;
  journifyDisplayName?: string;
  journifySignedInEmail?: string;
  journifySignOut?: () => Promise<void>;
}
