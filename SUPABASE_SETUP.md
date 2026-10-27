# Supabase setup

The app currently has no configured Supabase project. The migration and browser client are prepared, but no project URL or publishable/anon key was present in the workspace, so the SQL has not been applied or tested against a live/local database.

## Configure a development project

1. Create or select a **development** Supabase project.
2. Copy `.env.example` to `.env.local` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` from the project's Connect/API settings. A legacy anon key is also accepted as `VITE_SUPABASE_ANON_KEY`; never put a secret/service-role key in a `VITE_` variable.
3. Install dependencies with `npm install` when network access is available.
4. Apply every SQL file under `supabase/migrations/` in timestamp order (initial schema, then trip-creation changes) in the Supabase Dashboard SQL editor.
5. Configure Google Auth in Supabase and Google Cloud: create a Google OAuth client, add the Supabase Auth callback URL shown in the provider settings as an authorized redirect URI in Google Cloud, and enter the client ID and secret in Supabase. In Supabase Auth URL Configuration, set the Site URL and allow the local app URL (for Vite, `http://localhost:5173`) plus the deployed app URL. The app starts Google OAuth with `prompt=select_account` so Google displays its account chooser. Private trip data has no anonymous access; users must be authenticated.
6. Deploy only after checking the RLS and Storage policies with at least two separate test accounts.

Run the app locally with `npm run dev` after installing packages and adding `.env.local`.

`index.html` is the Journify app entry point. `trip_app_ui_updated.html` is retained as its visual reference. Trip creation requires a signed-in Auth user and calls the migration's `create_trip_with_members` RPC; the form does not report success until the RPC returns a saved trip ID. Existing browser data under the former `roamlyTrips`, `roamlyBills`, and `roamlyExpenses` keys is copied into the corresponding `journify*` keys without deleting the originals. A notice appears while browser data remains unmigrated to Supabase. That migration is a later project phase.

The migration creates a private `trip-receipts` bucket with a 10 MiB limit. Object paths must be `<trip UUID>/<expense UUID>/<filename>`. Use signed URLs for receipt display; do not make the bucket public.

## Schema and authorization notes

- Creating a trip inserts its owner membership in the same database transaction through a trigger.
- Only the trip owner can add or remove participant records. Named participants without an Auth account can appear in payer/split lists, but a name alone never grants app access. Adding an authenticated member requires the owner's account UUID; a public profile directory or email invitation service is not enabled.
- Bills are scoped to a trip. Expense plus split rows can only be written atomically through `create_expense_with_splits`, which validates caller membership, bill/trip pairing, payer and participant membership, and exact allocation totals.
- Expense and split tables are read-only to browser table writes. Receipt objects are private and protected by membership in the trip UUID in the first path segment.
- Deleting a trip cascades to its bills, expenses, and splits. Deleting an Auth user who owns trips is restricted until those trips are explicitly deleted or transferred.

## Manual access-check matrix

Run these checks after applying the migration with two users, A and B:

| Action | User A (trip owner/member) | User B (not a member) |
| --- | --- | --- |
| Read trip, members, bills, expenses, splits | Allowed for A's trip | No rows / denied |
| Create trip as self | Allowed; owner membership appears | Allowed for B's own trip |
| Add/remove a member | Owner can add/remove a different user | Denied |
| Create bill in trip | Allowed | Denied |
| Insert expense/split directly via table API | Denied; use the RPC | Denied |
| Create expense through RPC with valid members | Allowed | Denied |
| Upload/read/update/delete receipt under trip UUID | Allowed | Denied |

No result in this matrix has been claimed as verified until the migration is applied and the checks are run.
