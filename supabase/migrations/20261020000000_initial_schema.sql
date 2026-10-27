-- Journify private trip and shared-expense schema.
-- Safe to re-run in a development project. All data tables are protected by RLS.

create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Traveller' check (char_length(display_name) between 1 and 80),
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (char_length(trim(name)) between 1 and 160),
  destination text,
  notes text,
  start_date date not null,
  end_date date not null,
  base_currency text not null default 'MYR' check (base_currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trips_valid_date_range check (end_date >= start_date)
);

create table if not exists public.trip_members (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  constraint trip_members_trip_user_unique unique (trip_id, user_id),
  constraint trip_members_id_trip_unique unique (id, trip_id)
);

create table if not exists public.bills (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  creator_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (char_length(trim(name)) between 1 and 160),
  description text,
  currency text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bills_id_trip_unique unique (id, trip_id)
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null,
  trip_id uuid not null,
  creator_id uuid not null references auth.users(id) on delete restrict,
  description text not null check (char_length(trim(description)) between 1 and 240),
  original_amount numeric(14,2) not null check (original_amount > 0),
  original_currency text not null check (original_currency ~ '^[A-Z]{3}$'),
  base_amount numeric(14,2) not null check (base_amount > 0),
  exchange_rate numeric(20,10) not null check (exchange_rate > 0),
  payer_member_id uuid not null,
  split_method text not null default 'equal' check (split_method in ('equal', 'custom')),
  receipt_path text,
  expense_date date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expenses_bill_trip_fk foreign key (bill_id, trip_id)
    references public.bills(id, trip_id) on delete cascade,
  constraint expenses_payer_trip_fk foreign key (payer_member_id, trip_id)
    references public.trip_members(id, trip_id) on delete restrict
);

create table if not exists public.expense_splits (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expenses(id) on delete cascade,
  participant_member_id uuid not null references public.trip_members(id) on delete restrict,
  base_amount numeric(14,2) not null check (base_amount >= 0),
  original_amount numeric(14,2) check (original_amount is null or original_amount >= 0),
  created_at timestamptz not null default now(),
  constraint expense_splits_expense_participant_unique unique (expense_id, participant_member_id)
);

create index if not exists trips_owner_idx on public.trips(owner_id);
create index if not exists trip_members_user_trip_idx on public.trip_members(user_id, trip_id);
create index if not exists bills_trip_created_idx on public.bills(trip_id, created_at desc);
create index if not exists expenses_bill_date_idx on public.expenses(bill_id, expense_date desc, created_at desc);
create index if not exists expenses_trip_idx on public.expenses(trip_id);
create index if not exists expense_splits_participant_idx on public.expense_splits(participant_member_id);

-- Membership lookup runs with a pinned search_path and is not exposed through the Data API.
create or replace function private.is_trip_member(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.trip_members tm
    where tm.trip_id = p_trip_id and tm.user_id = (select auth.uid())
  );
$$;

create or replace function private.is_trip_owner(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.trips t
    where t.id = p_trip_id and t.owner_id = (select auth.uid())
  );
$$;

create or replace function private.is_trip_member_folder(p_trip_folder text)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_trip_folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return private.is_trip_member(p_trip_folder::uuid);
end;
$$;

revoke all on function private.is_trip_member(uuid) from public, anon;
revoke all on function private.is_trip_owner(uuid) from public, anon;
revoke all on function private.is_trip_member_folder(text) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_trip_member(uuid) to authenticated;
grant execute on function private.is_trip_owner(uuid) to authenticated;
grant execute on function private.is_trip_member_folder(text) to authenticated;

create or replace function private.create_trip_owner_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.trip_members (trip_id, user_id, role)
  values (new.id, new.owner_id, 'owner');
  return new;
end;
$$;

drop trigger if exists trips_create_owner_membership on public.trips;
create trigger trips_create_owner_membership
after insert on public.trips
for each row execute function private.create_trip_owner_membership();

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles
for each row execute function private.set_updated_at();
drop trigger if exists trips_set_updated_at on public.trips;
create trigger trips_set_updated_at before update on public.trips
for each row execute function private.set_updated_at();
drop trigger if exists bills_set_updated_at on public.bills;
create trigger bills_set_updated_at before update on public.bills
for each row execute function private.set_updated_at();
drop trigger if exists expenses_set_updated_at on public.expenses;
create trigger expenses_set_updated_at before update on public.expenses
for each row execute function private.set_updated_at();

-- Profile creation is tied to Auth; no client-supplied owner ID is trusted.
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Traveller')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute function private.handle_new_auth_user();

insert into public.profiles (id, display_name)
select
  u.id,
  coalesce(nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''), 'Traveller')
from auth.users u
on conflict (id) do nothing;

alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.trip_members enable row level security;
alter table public.bills enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_splits enable row level security;

revoke all on public.profiles, public.trips, public.trip_members, public.bills,
  public.expenses, public.expense_splits from anon;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.trips to authenticated;
grant select, insert, delete on public.trip_members to authenticated;
grant select, insert, update, delete on public.bills to authenticated;
grant select on public.expenses, public.expense_splits to authenticated;

drop policy if exists profiles_read_authorized on public.profiles;
create policy profiles_read_authorized on public.profiles
for select to authenticated
using (
  id = (select auth.uid())
  or exists (
    select 1 from public.trip_members mine
    join public.trip_members theirs on theirs.trip_id = mine.trip_id
    where mine.user_id = (select auth.uid()) and theirs.user_id = profiles.id
  )
);
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

drop policy if exists trips_read_member on public.trips;
create policy trips_read_member on public.trips
for select to authenticated using ((select private.is_trip_member(id)));
drop policy if exists trips_create_self on public.trips;
create policy trips_create_self on public.trips
for insert to authenticated with check (owner_id = (select auth.uid()));
drop policy if exists trips_update_member on public.trips;
create policy trips_update_member on public.trips
for update to authenticated
using ((select private.is_trip_member(id)))
with check ((select private.is_trip_member(id)) and owner_id = (select auth.uid()));
drop policy if exists trips_delete_owner on public.trips;
create policy trips_delete_owner on public.trips
for delete to authenticated using ((select private.is_trip_owner(id)));

drop policy if exists trip_members_read_member on public.trip_members;
create policy trip_members_read_member on public.trip_members
for select to authenticated using ((select private.is_trip_member(trip_id)));
drop policy if exists trip_members_add_member_by_owner on public.trip_members;
create policy trip_members_add_member_by_owner on public.trip_members
for insert to authenticated
with check (
  role = 'member'
  and user_id <> (select auth.uid())
  and (select private.is_trip_owner(trip_id))
);
drop policy if exists trip_members_remove_by_owner on public.trip_members;
create policy trip_members_remove_by_owner on public.trip_members
for delete to authenticated
using ((select private.is_trip_owner(trip_id)) and role <> 'owner');

drop policy if exists bills_read_member on public.bills;
create policy bills_read_member on public.bills
for select to authenticated using ((select private.is_trip_member(trip_id)));
drop policy if exists bills_create_member on public.bills;
create policy bills_create_member on public.bills
for insert to authenticated
with check (creator_id = (select auth.uid()) and (select private.is_trip_member(trip_id)));
drop policy if exists bills_update_member on public.bills;
create policy bills_update_member on public.bills
for update to authenticated
using ((select private.is_trip_member(trip_id)))
with check (creator_id = (select auth.uid()) and (select private.is_trip_member(trip_id)));
drop policy if exists bills_delete_member on public.bills;
create policy bills_delete_member on public.bills
for delete to authenticated using ((select private.is_trip_member(trip_id)));

drop policy if exists expenses_read_member on public.expenses;
create policy expenses_read_member on public.expenses
for select to authenticated using ((select private.is_trip_member(trip_id)));
-- Writes are only allowed through create_expense_with_splits(), which validates the
-- bill, payer, participants, exact allocation total, and caller membership atomically.
revoke insert, update, delete on public.expenses from anon, authenticated;

drop policy if exists expense_splits_read_member on public.expense_splits;
create policy expense_splits_read_member on public.expense_splits
for select to authenticated using (
  exists (
    select 1 from public.expenses e
    where e.id = expense_splits.expense_id
      and (select private.is_trip_member(e.trip_id))
  )
);
revoke insert, update, delete on public.expense_splits from anon, authenticated;

create or replace function public.create_expense_with_splits(
  p_id uuid,
  p_bill_id uuid,
  p_trip_id uuid,
  p_description text,
  p_original_amount numeric,
  p_original_currency text,
  p_base_amount numeric,
  p_exchange_rate numeric,
  p_payer_member_id uuid,
  p_expense_date date,
  p_splits jsonb,
  p_receipt_path text default null,
  p_split_method text default 'equal'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total numeric(14,2);
  v_count integer;
  v_participant uuid;
  v_share numeric(14,2);
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;
  if not private.is_trip_member(p_trip_id) then
    raise exception 'Trip membership is required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.bills b where b.id = p_bill_id and b.trip_id = p_trip_id) then
    raise exception 'Bill does not belong to the selected trip' using errcode = '23503';
  end if;
  if not exists (
    select 1 from public.trip_members tm
    where tm.id = p_payer_member_id and tm.trip_id = p_trip_id
  ) then
    raise exception 'Payer must be a member of the selected trip' using errcode = '23503';
  end if;
  if p_original_amount <= 0 or p_base_amount <= 0 or p_exchange_rate <= 0 then
    raise exception 'Amounts and exchange rate must be positive' using errcode = '23514';
  end if;
  if p_original_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter code' using errcode = '23514';
  end if;
  if p_split_method not in ('equal', 'custom') then
    raise exception 'Unsupported split method' using errcode = '23514';
  end if;
  if p_splits is null or jsonb_typeof(p_splits) <> 'array' or jsonb_array_length(p_splits) = 0 then
    raise exception 'At least one participant split is required' using errcode = '23514';
  end if;
  if p_receipt_path is not null and p_receipt_path !~ ('^' || p_trip_id::text || '/' || p_id::text || '/[^/]+$') then
    raise exception 'Receipt path must be scoped to this trip and expense' using errcode = '23514';
  end if;

  select count(*), coalesce(sum((s.value ->> 'base_amount')::numeric), 0)
    into v_count, v_total
  from jsonb_array_elements(p_splits) s(value);
  if v_total <> round(p_base_amount, 2) then
    raise exception 'Split allocations must equal the base amount' using errcode = '23514';
  end if;

  insert into public.expenses (
    id, bill_id, trip_id, creator_id, description, original_amount,
    original_currency, base_amount, exchange_rate, payer_member_id,
    split_method, receipt_path, expense_date
  ) values (
    p_id, p_bill_id, p_trip_id, (select auth.uid()), trim(p_description),
    p_original_amount, p_original_currency, round(p_base_amount, 2), p_exchange_rate,
    p_payer_member_id, p_split_method, p_receipt_path, p_expense_date
  );

  for v_participant, v_share in
    select (s.value ->> 'participant_member_id')::uuid,
           (s.value ->> 'base_amount')::numeric(14,2)
    from jsonb_array_elements(p_splits) s(value)
  loop
    if not exists (
      select 1 from public.trip_members tm
      where tm.id = v_participant and tm.trip_id = p_trip_id
    ) then
      raise exception 'Every split participant must belong to the selected trip' using errcode = '23503';
    end if;
    insert into public.expense_splits (expense_id, participant_member_id, base_amount)
    values (p_id, v_participant, v_share);
  end loop;

  if v_count <> (select count(distinct (s.value ->> 'participant_member_id')) from jsonb_array_elements(p_splits) s(value)) then
    raise exception 'Each participant may appear only once' using errcode = '23514';
  end if;
  return p_id;
end;
$$;

revoke all on function public.create_expense_with_splits(uuid, uuid, uuid, text, numeric, text, numeric, numeric, uuid, date, jsonb, text, text) from public, anon;
grant execute on function public.create_expense_with_splits(uuid, uuid, uuid, text, numeric, text, numeric, numeric, uuid, date, jsonb, text, text) to authenticated;

-- Private receipt bucket; object paths are <trip UUID>/<expense UUID>/<safe filename>.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('trip-receipts', 'trip-receipts', false, 10485760, array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists trip_receipts_read_member on storage.objects;
create policy trip_receipts_read_member on storage.objects
for select to authenticated
using (
  bucket_id = 'trip-receipts'
  and (select private.is_trip_member_folder((storage.foldername(name))[1]))
);
drop policy if exists trip_receipts_upload_member on storage.objects;
create policy trip_receipts_upload_member on storage.objects
for insert to authenticated
with check (
  bucket_id = 'trip-receipts'
  and (select private.is_trip_member_folder((storage.foldername(name))[1]))
);
drop policy if exists trip_receipts_update_member on storage.objects;
create policy trip_receipts_update_member on storage.objects
for update to authenticated
using (
  bucket_id = 'trip-receipts'
  and (select private.is_trip_member_folder((storage.foldername(name))[1]))
)
with check (
  bucket_id = 'trip-receipts'
  and (select private.is_trip_member_folder((storage.foldername(name))[1]))
);
drop policy if exists trip_receipts_delete_member on storage.objects;
create policy trip_receipts_delete_member on storage.objects
for delete to authenticated
using (
  bucket_id = 'trip-receipts'
  and (select private.is_trip_member_folder((storage.foldername(name))[1]))
);
