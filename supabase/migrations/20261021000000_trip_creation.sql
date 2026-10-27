-- Phase 2: trip budget and named non-auth participants used by the existing UI.
-- Compatible with projects that already applied the initial Phase 1 migration.

alter table public.trips
  add column if not exists budget numeric(14,2);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'trips_budget_nonnegative' and conrelid = 'public.trips'::regclass
  ) then
    alter table public.trips add constraint trips_budget_nonnegative
      check (budget is null or budget >= 0);
  end if;
end;
$$;

alter table public.trip_members add column if not exists display_name text;
alter table public.trip_members alter column user_id drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'trip_members_display_name_length' and conrelid = 'public.trip_members'::regclass
  ) then
    alter table public.trip_members add constraint trip_members_display_name_length
      check (display_name is null or char_length(trim(display_name)) between 1 and 80);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'trip_members_identity' and conrelid = 'public.trip_members'::regclass
  ) then
    alter table public.trip_members add constraint trip_members_identity
      check (user_id is not null or display_name is not null);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'trip_members_owner_has_user' and conrelid = 'public.trip_members'::regclass
  ) then
    alter table public.trip_members add constraint trip_members_owner_has_user
      check (role <> 'owner' or user_id is not null);
  end if;
end;
$$;

create unique index if not exists trip_members_named_name_unique
  on public.trip_members(trip_id, lower(trim(display_name)))
  where user_id is null and display_name is not null;

create or replace function private.create_trip_owner_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.trip_members (trip_id, user_id, display_name, role)
  values (
    new.id,
    new.owner_id,
    (select p.display_name from public.profiles p where p.id = new.owner_id),
    'owner'
  );
  return new;
end;
$$;

create or replace function public.create_trip_with_members(
  p_name text,
  p_destination text,
  p_notes text,
  p_start_date date,
  p_end_date date,
  p_budget numeric,
  p_member_names text[],
  p_base_currency text default 'MYR'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip_id uuid;
  v_owner_name text;
  v_member_name text;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;
  if p_name is null or char_length(trim(p_name)) not between 1 and 160 then
    raise exception 'Trip name must contain 1 to 160 characters' using errcode = '23514';
  end if;
  if p_end_date < p_start_date then
    raise exception 'End date cannot be before the start date' using errcode = '23514';
  end if;
  if p_budget is not null and p_budget < 0 then
    raise exception 'Budget cannot be negative' using errcode = '23514';
  end if;
  if coalesce(cardinality(p_member_names), 0) > 29 then
    raise exception 'A trip can have up to 30 members, including the owner' using errcode = '23514';
  end if;

  select p.display_name into v_owner_name
  from public.profiles p where p.id = (select auth.uid());

  insert into public.trips (
    owner_id, name, destination, notes, start_date, end_date, budget, base_currency
  ) values (
    (select auth.uid()), trim(p_name), nullif(trim(p_destination), ''), nullif(trim(p_notes), ''),
    p_start_date, p_end_date, p_budget, coalesce(p_base_currency, 'MYR')
  ) returning id into v_trip_id;

  for v_member_name in
    select distinct on (lower(trim(m.name))) trim(m.name)
    from unnest(coalesce(p_member_names, array[]::text[])) as m(name)
    where trim(m.name) <> ''
    order by lower(trim(m.name)), trim(m.name)
  loop
    if lower(v_member_name) not in (lower(coalesce(v_owner_name, '')), 'you') then
      insert into public.trip_members (trip_id, user_id, display_name, role)
      values (v_trip_id, null, v_member_name, 'member');
    end if;
  end loop;

  return v_trip_id;
end;
$$;

revoke all on function public.create_trip_with_members(text, text, text, date, date, numeric, text[], text) from public, anon;
grant execute on function public.create_trip_with_members(text, text, text, date, date, numeric, text[], text) to authenticated;

drop policy if exists trip_members_add_member_by_owner on public.trip_members;
create policy trip_members_add_member_by_owner on public.trip_members
for insert to authenticated
with check (
  role = 'member'
  and (user_id is null or user_id <> (select auth.uid()))
  and (select private.is_trip_owner(trip_id))
);
