import type { User } from '@supabase/supabase-js';
import { getSupabaseClient, supabaseConfigured } from './lib/supabase';

const gate = document.getElementById('auth-gate')!;
const shell = document.getElementById('app-shell')!;
const nav = document.getElementById('app-nav')!;
const form = document.getElementById('auth-form') as HTMLFormElement;
const message = document.getElementById('auth-message')!;
const setup = document.getElementById('auth-setup')!;
const submit = document.getElementById('auth-submit') as HTMLButtonElement;
const retry = document.createElement('button');
retry.className = 'auth-switch';
retry.type = 'button';
retry.textContent = 'Retry loading trips';
retry.hidden = true;
form.after(retry);

let supabase: ReturnType<typeof getSupabaseClient> | null = null;
let currentUser: User | null = null;
let activeUserId: string | null = null;
let loadVersion = 0;

function setMessage(text: string, success = false): void {
  message.textContent = text;
  message.classList.toggle('success', success);
}

function showSignedOut(): void {
  activeUserId = null;
  currentUser = null;
  window.journifyUserId = undefined;
  gate.hidden = false;
  shell.hidden = true;
  nav.hidden = true;
  retry.hidden = true;
  setMessage('');
}

function showProfile(displayName: string, email: string): void {
  const profileCard = document.querySelector('.profile-card');
  if (!profileCard) return;
  const avatar = profileCard.querySelector('.avatar');
  const name = profileCard.querySelector('h3');
  const subtitle = profileCard.querySelector('p');
  if (avatar) avatar.textContent = displayName.split(/\s+/).slice(0, 2).map(part => part[0]).join('').toUpperCase();
  if (name) name.textContent = displayName;
  if (subtitle) subtitle.textContent = email;

  if (!document.getElementById('sign-out-button')) {
    const signOut = document.createElement('button');
    signOut.id = 'sign-out-button';
    signOut.className = 'btn light';
    signOut.type = 'button';
    signOut.textContent = 'Sign out';
    signOut.addEventListener('click', async () => {
      if (!supabase) return;
      const { error } = await supabase.auth.signOut();
      if (error) setMessage(error.message);
    });
    profileCard.after(signOut);
  }
}

function readableError(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'object' && error !== null && 'message' in error) {
    const candidate = (error as { message?: unknown }).message;
    if (typeof candidate === 'string' && candidate) return candidate;
  }
  return 'Could not load your trips. Check your connection and try again.';
}

async function activateUser(user: User): Promise<void> {
  if (activeUserId === user.id && !shell.hidden) return;
  const version = ++loadVersion;
  currentUser = user;
  setMessage('Loading your trips…', true);
  retry.hidden = true;
  try {
    if (!supabase) throw new Error('Supabase is not configured. Add the development project URL and publishable key.');
    const [{ data: profile, error: profileError }, { data: tripRows, error: tripsError }] = await Promise.all([
      supabase.from('profiles').select('display_name').eq('id', user.id).maybeSingle(),
      supabase.from('trips').select('id,owner_id,name,destination,notes,start_date,end_date,budget').order('start_date', { ascending: true }),
    ]);
    if (profileError) throw profileError;
    if (tripsError) throw tripsError;

    const ids = (tripRows ?? []).map(trip => trip.id);
    let memberRows: Array<{ id: string; trip_id: string; user_id: string | null; display_name: string | null; role: 'owner' | 'member' }> = [];
    if (ids.length) {
      const { data, error } = await supabase.from('trip_members')
        .select('id,trip_id,user_id,display_name,role').in('trip_id', ids);
      if (error) throw error;
      memberRows = data ?? [];
    }

    const profileIds = [...new Set(memberRows.map(member => member.user_id).filter((id): id is string => Boolean(id)))];
    const memberNamesByUser = new Map<string, string>();
    if (profileIds.length) {
      const { data, error } = await supabase.from('profiles').select('id,display_name').in('id', profileIds);
      if (error) throw error;
      for (const memberProfile of data ?? []) memberNamesByUser.set(memberProfile.id, memberProfile.display_name);
    }

    if (version !== loadVersion) return;
    const displayName = profile?.display_name?.trim() || user.user_metadata.display_name?.trim() || 'Traveller';
    window.journifyUserId = user.id;
    window.journifyDisplayName = displayName;
    window.journifySignedInEmail = user.email ?? '';
    showProfile(displayName, user.email ?? '');
    const mapped = (tripRows ?? []).map(trip => {
      const records = memberRows.filter(member => member.trip_id === trip.id)
        .map(member => ({ ...member, display_name: member.display_name || (member.user_id ? memberNamesByUser.get(member.user_id) ?? null : null) }))
        .sort((a, b) => a.role === 'owner' ? -1 : b.role === 'owner' ? 1 : (a.display_name ?? '').localeCompare(b.display_name ?? ''));
      return {
        id: trip.id,
        ownerId: trip.owner_id,
        name: trip.destination || trip.name,
        start: trip.start_date,
        end: trip.end_date,
        notes: trip.notes ?? '',
        budget: trip.budget === null ? null : Number(trip.budget),
        travellers: Math.max(1, records.length),
        members: records.map(member => member.display_name || (member.role === 'owner' ? displayName : 'Traveller')),
        memberRecords: records,
      };
    });
    window.journifySetTrips?.(mapped);
    activeUserId = user.id;
    gate.hidden = true;
    shell.hidden = false;
    nav.hidden = false;
    setMessage('');
  } catch (error) {
    if (version !== loadVersion) return;
    gate.hidden = false;
    shell.hidden = true;
    nav.hidden = true;
    retry.hidden = false;
    setMessage(readableError(error));
  }
}

if (!supabaseConfigured) {
  form.hidden = true;
  setup.hidden = false;
  setup.innerHTML = 'Supabase is not configured for this copy of the app. Copy <code>.env.example</code> to <code>.env.local</code>, add your development project URL and publishable/anon key, and apply the database migration. See <a href="/SUPABASE_SETUP.md">setup instructions</a>.';
} else {
  supabase = getSupabaseClient();

  window.journifyReloadTrips = async () => {
    if (!currentUser) throw new Error('Sign in again to load trips.');
    activeUserId = null;
    await activateUser(currentUser);
    if (activeUserId !== currentUser.id) throw new Error('Trip refresh failed. Please retry.');
  };

  window.journifyCreateTripRpc = async input => {
    if (!currentUser) throw new Error('Sign in to create a trip.');
    const { data, error } = await supabase!.rpc('create_trip_with_members', {
      p_name: input.name,
      p_destination: input.name,
      p_notes: input.notes || null,
      p_start_date: input.startDate,
      p_end_date: input.endDate,
      p_budget: input.budget,
      p_member_names: input.memberNames,
      p_base_currency: 'MYR',
    });
    if (error) throw error;
    if (!data) throw new Error('The database did not return the saved trip.');
    return data;
  };

  window.journifyAddTripMember = async ({ tripId, displayName }) => {
    const { error } = await supabase!.from('trip_members').insert({
      trip_id: tripId, user_id: null, display_name: displayName, role: 'member',
    });
    if (error) throw error;
  };

  window.journifyRemoveTripMember = async memberId => {
    const { error } = await supabase!.from('trip_members').delete().eq('id', memberId);
    if (error) throw error;
  };

  window.journifySignOut = async () => { await supabase!.auth.signOut(); };

  retry.addEventListener('click', () => { if (currentUser) void activateUser(currentUser); });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    submit.disabled = true;
    submit.innerHTML = 'Connecting to Google…';
    setMessage('');
    try {
      const { error } = await supabase!.auth.signInWithOAuth({
        provider: 'google',
        options: {
          redirectTo: window.location.origin,
          queryParams: { prompt: 'select_account' },
        },
      });
      if (error) throw error;
    } catch (error) {
      setMessage(readableError(error));
    } finally {
      submit.disabled = false;
      submit.innerHTML = '<svg class="google-mark" viewBox="0 0 48 48" aria-hidden="true"><path fill="#4285F4" d="M43.6 24.5c0-1.4-.1-2.8-.4-4.1H24v7.8h11a9.4 9.4 0 0 1-4.1 6.2v5.1h6.6c3.9-3.6 6.1-8.8 6.1-15z"/><path fill="#34A853" d="M24 44c5.5 0 10.1-1.8 13.5-4.9l-6.6-5.1c-1.8 1.2-4.1 2-6.9 2-5.3 0-9.8-3.6-11.4-8.4H5.8v5.3A20 20 0 0 0 24 44z"/><path fill="#FBBC05" d="M12.6 27.6a12 12 0 0 1 0-7.2v-5.3H5.8a20 20 0 0 0 0 17.8l6.8-5.3z"/><path fill="#EA4335" d="M24 12c3 0 5.7 1 7.8 3.1l5.8-5.8C34.1 6 29.5 4 24 4A20 20 0 0 0 5.8 15.1l6.8 5.3C14.2 15.6 18.7 12 24 12z"/></svg>Continue with Google';
    }
  });

  supabase.auth.onAuthStateChange((event, session) => {
    if (event === 'SIGNED_OUT') showSignedOut();
    else if (session && (event === 'INITIAL_SESSION' || event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED' || event === 'USER_UPDATED')) {
      queueMicrotask(() => { void activateUser(session.user); });
    }
  });

  void supabase.auth.getSession().then(({ data, error }) => {
    if (error) setMessage(error.message);
    else if (data.session) void activateUser(data.session.user);
  });
}
