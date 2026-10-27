# Trip App Implementation Plan

## Purpose and execution rules

Implement the existing Trip App as a working, persistent trip and shared-expense application. This document is an execution plan for Codex; it does not claim that any implementation has already been completed.

- Start by inspecting the repository, its instructions, the current app entry points, and the current UI prototype if one is present (including `trip_app_ui_updated.html`). Identify the framework, routing, styling system, current data flow, and any existing Supabase or localStorage code before editing.
- Preserve the existing visual design, layout, colors, typography, and interaction patterns. Treat the existing prototype as the source of truth for appearance. Translate its design into the existing framework rather than replacing it with a generic redesign. If the prototype is absent, retain the existing app's visual language and record the missing reference in the implementation summary.
- Treat `sources/` as read-only reference material. Do not edit, rename, move, or delete any synced project files.
- Implement the whole connected flow, not disconnected mock screens: a user creates/selects a trip, trip members are available to expense entry, a bill belongs to the selected trip, and expenses/receipts persist and can be revisited.
- Keep secrets out of client code. Use only Supabase's publishable/anon key in a browser client; privileged service-role credentials must only be used in a trusted server environment and are not required for normal client operations.
- Do not replace working behavior with placeholder data. Provide useful loading, empty, success, and error states for each persisted feature.

## Phase 0: Repository discovery and baseline

1. Read all applicable `AGENTS.md` instructions and inspect the entire project tree, excluding generated/dependency directories as appropriate.
2. Locate the current app, prototype, route structure, style tokens, forms, storage helpers, and test/build commands. Identify whether trips, bills, expenses, members, or receipts already exist and how they are currently stored.
3. Trace the existing trip creation button end-to-end. Determine why it currently does not save (for example, missing submit handler, validation, persistence call, schema, or error handling). Document the actual cause found and fix it as part of implementation; do not guess or report an unverified cause.
4. Identify existing localStorage data and its shape. Plan a safe, idempotent migration path if data exists; do not silently discard it.
5. Capture the baseline UI and behavior sufficiently to ensure the implementation retains the design. Do not modify `sources/`.

**Exit criteria:** repository structure, existing design, current save path, current persistence, and migration needs are understood; implementation choices fit the existing stack.

## Phase 1: Supabase setup and data model

### Project connection

- Create/configure a Supabase project through the Supabase dashboard (or use the project's already configured instance). Record the project URL and browser-safe publishable/anon key in the framework's documented environment variables (for example, `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` or the equivalent for the detected framework).
- Add a single typed/configured Supabase client module and use it from data-access modules. Validate missing configuration at startup and show a clear setup error instead of crashing or pretending data was saved.
- Add a `.env.example` containing variable names and safe placeholders only. Ensure real `.env` files and service-role keys are ignored by version control.
- Provide SQL migrations (or the repository's established schema migration format) for the schema, indexes, constraints, policies, and Storage bucket policies below. Document how to apply them and how to configure local development.
- Use Supabase Auth if authentication exists or is part of the app. Tie records to `auth.uid()`; do not rely on a client-supplied owner ID. If the current prototype has no auth, implement a minimal sign-in/sign-up flow before enabling private persistent trip data, or clearly follow the repository's existing trusted identity mechanism. Never make private trip/expense data world-readable as a shortcut.

### Proposed relational schema

Adapt names and types to project conventions, preserving the following relationships and integrity rules.

1. **profiles**: `id uuid primary key references auth.users(id) on delete cascade`, display name, optional avatar path, timestamps. Users may read/update their own profile; expose only the limited profile fields needed to display trip members to authorized trip participants.
2. **trips**: UUID primary key, `owner_id` referencing `auth.users`, required name, optional destination/notes, `start_date date not null`, `end_date date not null`, optional base currency (default `MYR`), timestamps. Add a database check that `end_date >= start_date`.
3. **trip_members**: UUID primary key, `trip_id` foreign key with cascade delete, `user_id` foreign key, role (owner/member), optional display name for invited/non-authenticated participants only if the product genuinely supports them, creation timestamp. Unique `(trip_id, user_id)`; index both lookup directions. Ensure one owner membership for each trip, through a safe transaction/trigger or an explicit atomic creation operation.
4. **bills**: UUID primary key, `trip_id` foreign key with cascade delete, creator ID, title/name, optional description, currency code, timestamps. A bill is always associated with a trip; the create-bill form receives the selected trip and displays it clearly.
5. **expenses**: UUID primary key, `bill_id` foreign key with cascade delete, `trip_id` foreign key where useful for policy/indexing (ensure it matches the bill's trip through a trigger/composite constraint or omit redundant storage), creator ID, description, original amount as fixed-precision decimal/numeric, original currency, converted amount in the bill/trip base currency, exchange rate used, payer member/user reference, split method, split count and/or participant splits, optional receipt object path, expense date, timestamps. Store monetary values without floating-point rounding; validate positive amounts, valid currency codes, and consistent relationships.
6. **expense_splits**: UUID primary key, expense foreign key with cascade delete, participant reference (trip member/user or supported participant record), exact allocated amount in base currency, optional original-currency share, timestamps. Enforce uniqueness per expense/participant and reconcile allocations to the expense total using transactional application logic and suitable database constraints/triggers.

Use database-generated UUIDs and timestamps. Add indexes for common access paths (trip owner/member, bills by trip, expenses by bill/date, splits by expense/participant). Define deletion behavior intentionally and make it consistent with the UI's confirmation behavior.

### Row Level Security and storage security

- Enable RLS on every user-facing table. No table or bucket containing trip data or receipts may be accessible to anonymous users by default.
- Authorize trip reads and updates only for trip members. Authorize trip creation for an authenticated user and create owner membership atomically. Restrict destructive trip operations to the owner (or explicitly defined admin role).
- Authorize member management to the trip owner or a specifically permitted role. Users may not add themselves to arbitrary trips or change their own role to owner.
- Authorize bill reads/writes only when the caller is a member of the bill's associated trip. Validate that an expense and its payer/split participants belong to the same trip as the bill.
- Authorize expense and split reads/writes only through the parent bill/trip membership. Prevent a caller from assigning an expense to another user's trip by changing foreign keys.
- Scope receipt storage object paths by trip and bill/expense, and verify membership in Storage policies for upload, read, update, and delete. Use private buckets and short-lived signed URLs for viewing/downloading. Validate type and size in the client and server/storage policy where possible; never trust a client filename or MIME type alone.
- Avoid broad `USING (true)` / `WITH CHECK (true)` policies. Include policy tests or a documented manual matrix proving a non-member cannot read or mutate another trip, bill, expense, split, or receipt.

**Exit criteria:** migrations are repeatable, constraints reject invalid dates and cross-trip relationships, and RLS/storage access follows authenticated membership.

## Phase 2: Trip creation, calendar dates, and members

- Retain the existing trip form's design. Make start and end date fields open a calendar/date picker; show dates to users in `DD/MM/YYYY` format. Use a real date input/calendar component appropriate to the existing UI rather than requiring users to type an ISO date.
- Parse and format dates without timezone drift. Persist calendar dates as SQL `date` values in `YYYY-MM-DD` form at the API boundary, not as locale-shifted timestamps.
- Enforce `end date >= start date` in the UI and database. The end-date calendar must not allow selecting a day before the chosen start date. If a changed start date makes the current end date invalid, clear it or show a clear validation message and require a valid replacement. Do not submit an invalid trip.
- On submit, validate required fields, disable duplicate submits, call the persistence layer, handle Supabase errors visibly, and only show success/navigate after the database confirms the save. Ensure the save action is actually wired to the form submit event.
- After successful creation, persist the owner as a trip member and route to/open the created trip. On reload, retrieve the trip from Supabase rather than depending on in-memory state.
- Provide member selection/management using authorized profiles or supported invite records. The member list shown in the trip is the source for payer selection and expense split participants. Explain empty member state and prevent invalid member references.

## Phase 3: Trip home and navigation

- Build the trip home as a card-based view that matches the current design. Each trip card should show the trip's key summary (name/destination, date range, and useful member/count context supported by the design), be keyboard/touch accessible, and open that trip.
- Load only trips the current user is authorized to see. Include initial loading, refresh/retry on failure, a useful empty state with a create-trip action, and a clear state for no network/session.
- Implement the app's four-button navigation in the established visual style. Each button must have a clear label/icon, working destination/action, selected state, keyboard focus, and accessible name. Keep navigation consistent across trip home, trip details, bills, and expenses. Do not invent destinations that conflict with the prototype; map the four buttons to the existing intended sections discovered in Phase 0.
- Make active trip context explicit wherever trip-specific bills or expenses are shown.

## Phase 4: Bills and per-bill expense history

- The bill landing screen is a list/grid of bill cards for the selected trip, styled consistently with trip cards. Each bill card opens that bill's own expense history.
- Provide a create-bill action/form. The user must select or enter a bill name and the currently selected trip must be linked automatically (or selected explicitly if entry begins outside a trip). Persist the `trip_id`; never create an unlinked bill.
- Show bill creation progress, validation, success, and recoverable errors. Re-fetch/refresh the persisted bill list after success.
- Each bill detail page shows its own expense history in date order, with relevant payer, amount/currency, description, and receipt indicator. Keep expenses scoped to that bill and selected trip. Provide an empty state with an add-expense action and loading/error/retry states.

## Phase 5: Split-expense modal, currency, payer, and receipts

- Add/edit expense through a modal that follows the existing design, works with keyboard and screen readers, traps/restores focus appropriately, and is usable on mobile. Preserve entered values on recoverable save errors.
- Include description, amount, expense currency, date, payer, split participant/count controls, and receipt attachment. Validate required values and positive amounts before saving.
- Currency conversion: support the trip/bill base currency (default `MYR`) and preserve both the entered original amount/currency and the converted base amount/rate used. Make the converted MYR amount editable as requested. Clearly label original and converted amounts so edits are understandable. If using a live rate source, handle unavailable/stale rates and record the rate/source timestamp; do not silently claim a live conversion. If no rate service exists, allow an explicit user-entered rate or converted MYR amount and label it accordingly. Never overwrite the original amount when the converted amount is edited.
- Split count control: provide a spinner/stepper and allow direct typing in the same control. Clamp or validate to a sensible positive integer and ensure the value cannot be less than 1 or greater than the number of eligible participants when that value represents participant count. Handle blank/in-progress typing without resetting the field on every keystroke.
- Payer dropdown: populate from the selected trip's actual members, display their readable names, store the correct member/user reference, and show a useful empty/error state if members cannot be loaded. Do not hard-code a payer.
- Define equal split behavior and rounding explicitly. For equal splits, calculate in integer minor units where possible, allocate rounding remainder deterministically, and ensure all split shares sum exactly to the expense total. Allow selection of participants consistent with the current prototype/product requirements.
- Receipt: support image/file selection and mobile camera capture where the browser supports it (for example `accept` plus `capture` as a hint; retain gallery/file selection). Upload to a private Supabase Storage bucket under a trip-scoped path. Save the object path on the expense only after upload succeeds, and clean up an orphaned uploaded object if the database save fails. Show preview/progress, allow removal/replacement, enforce allowed formats and a documented size limit, and use authorized signed URLs to view receipts later.
- Save expense and splits transactionally (via a database RPC/server action if necessary); avoid a partial state where an expense exists without its intended splits. Keep receipt upload failure distinct from expense save failure and provide a retry path.

## Phase 6: Persistence, loading, errors, and localStorage migration

- Replace feature-critical localStorage persistence with Supabase-backed repository/data services. Keep localStorage only for non-sensitive preferences or a temporary offline draft cache when appropriate; never treat it as the authoritative database.
- Inventory old localStorage keys and payload shapes. Implement an explicit, idempotent migration flow for existing trips/bills/expenses: validate and normalize records, preserve IDs or map relationships consistently, associate records with the authenticated owner, report skipped/invalid items, and mark migration complete only after confirmed writes. Do not silently upload unowned data to a shared account. Give the user a clear migration prompt if ownership cannot be inferred safely.
- For all data screens, show loading indicators/skeletons, empty states, actionable errors with retry, and success feedback. Distinguish no data from failed fetch and unauthenticated state. Do not clear existing state on transient errors or show false success.
- Refresh or invalidate related views after writes; handle duplicate submits, stale selection, and session expiration. Use optimistic UI only if rollback on server failure is implemented.
- If offline behavior exists, queue only safe, well-defined changes and reconcile conflicts; otherwise communicate that connection is required to save.

## Phase 7: Responsive Safari and PWA behavior

- Check the existing layout at phone, tablet, and desktop widths; preserve its appearance while preventing overflow and ensuring controls have usable touch targets.
- Verify current Safari/iOS behavior for date selection, file/camera selection, focus/modal behavior, and Supabase session persistence. Provide graceful fallbacks when a browser capability is unavailable.
- Configure PWA metadata and assets consistent with the existing brand (manifest, app name, icons, theme color, viewport, and safe-area insets). Add service worker/offline caching only for safe static assets; do not cache private API responses, signed receipt URLs, or auth material in shared caches.
- Provide concise, in-app instructions for adding the app to the iOS home screen through Safari's Share menu. Do not imply that a web app can programmatically open the Add to Home Screen dialog.
- Ensure install/opened-from-home-screen navigation and authentication behavior are coherent, including return to the selected trip after refresh where safe.

## Phase 8: Testing and verification

Use the repository's existing test tooling and add targeted coverage for the implemented behavior. Do not claim checks passed unless they were actually run. At minimum verify:

1. Date picker displays `DD/MM/YYYY`; start/end round-trip correctly across time zones; end before start is blocked in UI and rejected by database; same-day trips are valid.
2. Trip create button submits once, shows server errors, persists, and the new trip appears after reload. Owner membership is created consistently.
3. A user sees their member trips; a non-member cannot read or modify trips, bills, expenses, splits, or receipt objects (RLS and Storage policy checks).
4. Trip cards open the right trip; all four nav controls work; bill cards show only selected-trip bills; create bill links the selected trip; each bill shows only its own expense history.
5. Payer dropdown contains trip members; split spinner and typed input stay in sync; equal split rounding reconciles exactly; edits to MYR conversion preserve original amount/currency and stored rate.
6. Receipt upload from file selection works; camera capture is offered where supported; private receipt viewing requires authorization; upload/database failure paths do not leave misleading or orphaned data.
7. Loading, empty, error/retry, unauthenticated, duplicate-submit, and migration states render correctly.
8. Layout is usable at representative mobile and desktop sizes and in Safari/iOS; PWA metadata and Add to Home Screen guidance are present.
9. Existing data migration is idempotent and reports invalid/unowned data without deleting source localStorage before successful confirmation.

Run the repository's lint/typecheck/build and applicable unit/integration/e2e tests when available. For Supabase integration, verify migrations on a development/local project and test RLS as at least two distinct users. Never use production credentials or destructive production data for test runs.

## Implementation phases and acceptance checklist

Implementation is complete only when all applicable items below are met and the final summary distinguishes completed work from anything blocked by missing credentials or external setup.

- [ ] Existing app/prototype was inspected and its design retained; `sources/` remains unchanged.
- [ ] Actual failure behind the original trip-save button was identified and fixed; saving has a verified persistent success/error path.
- [ ] Supabase client setup and environment documentation are present; no secret key is exposed.
- [ ] Schema migrations, foreign keys, constraints, indexes, and secure RLS/Storage policies are provided and applied/tested in a non-production environment.
- [ ] Calendar date selection uses `DD/MM/YYYY` display and both UI and database enforce `end_date >= start_date`.
- [ ] Trip member data is persisted and drives payer/split selection.
- [ ] Card-based trip home, four working navigation buttons, bill-card landing, selected-trip-linked bill creation, and per-bill expense history work end-to-end.
- [ ] Expense modal supports original currency plus editable converted MYR, typeable/spinner split count, trip-member payer dropdown, reconciled split amounts, and receipt upload/camera fallback.
- [ ] Supabase Storage receipts are private, scoped, and available only to authorized trip members.
- [ ] Persistent loading, empty, error, retry, and success states are implemented across the flows.
- [ ] localStorage migration is safe, explicit, and idempotent where legacy data exists.
- [ ] Responsive Safari/PWA behavior and Add to Home Screen guidance are verified.
- [ ] Relevant checks have been run and their actual results are reported.

## Final implementation report expected from Codex

After executing this plan, report the files changed, the verified cause of the original save failure, Supabase setup steps still requiring the project owner (such as credentials or dashboard configuration), migrations/policies added, tests/checks actually run and their results, and any known limitations. Do not state that database integration, security, or tests are complete unless verified.
