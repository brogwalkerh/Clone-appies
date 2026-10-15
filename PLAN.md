# Roommate Hub — Plan

A private web app for two roommates: shared schedule, reminders, notes, the Airbnb
calendar, bills, and files. It opens in any browser and installs to a phone's home
screen like an app.

Status: **plan only, awaiting approval.** No code has been written yet.

---

## 1. Architecture

```
 Phone / laptop browser (installable PWA)
        │  loads static HTML/JS/CSS
        ▼
 GitHub Pages ── built and deployed by GitHub Actions on every push
        │
        │  HTTPS (supabase-js client)
        ▼
 Supabase (free tier)
   ├─ Auth ............ email + password, only 2 allowlisted emails can sign up
   ├─ Postgres ........ all data; Row-Level Security on every table
   ├─ Realtime ........ roommate's changes appear instantly, no refresh
   ├─ Storage ......... private bucket for files and receipts
   └─ Edge Function ... "sync-calendars": fetches Airbnb / iCal feeds
        ▲                 every 30 min (pg_cron) and on a "Refresh" button
        │
 Airbnb listing "Export calendar" .ics link (+ optional Google/iCloud iCal links)
```

Why this shape: GitHub Pages only hosts static files, so it can't store shared data
by itself. Supabase supplies the database, logins, file storage and a small server
function. The browser can't fetch Airbnb's calendar directly (blocked by
cross-origin rules), which is why the sync runs server-side.

## 2. Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | TypeScript | Static types, classes, interfaces, generics; designed by C#'s creator, so it reads like C#/Java |
| UI | React + Vite | Vite is the build tool (like MSBuild/Gradle) |
| Styling | Tailwind CSS | Mobile-first, light/dark mode |
| Calendar UI | FullCalendar (MIT plugins) | Month / week / agenda views |
| Data | supabase-js + TanStack Query | Caching, loading states, realtime invalidation |
| Phone install | vite-plugin-pwa | "Add to Home Screen", offline shell |
| Tests | Vitest (unit), Playwright (end-to-end) | |
| CI/CD | GitHub Actions → GitHub Pages | Lint, typecheck, test, build, deploy |

## 3. Features (v1 scope)

**Home dashboard**: today's events for both of you, next Airbnb check-in/check-out,
reminders due, bills due, and the current "who owes whom" balance.

**Schedule**: month/week/agenda views, one color per person plus "household"
events. Read-only overlays for Airbnb bookings and, optionally, each person's
personal Google/Outlook/iCloud calendar through its private iCal link.

**Airbnb calendar**: paste the listing's *Export calendar* link into Settings
(more than one listing is supported). Stays show as "Guest stay" blocks with
check-in/out days. Limitation: Airbnb's feed has dates, a reservation code and
the last 4 digits of the guest's phone number only, with no guest names. Airbnb
updates the feed every few hours on its side.

**Reminders**: title, notes, due date/time, assigned to me / roommate / both,
repeats (none, daily, weekly, monthly; for chores like "trash goes out Tuesday"),
done-by tracking, overdue highlighting. Alerts show in-app, plus browser
notifications while the app is open. Phone push notifications: see open questions.

**Notes**: Markdown notes with checklists (grocery list), pinning, search, live
updates. Two people editing the same note at once is handled with last-save-wins
plus a "roommate just edited this" warning. Full Google-Docs-style co-editing is
out of scope.

**Bills**: add an expense (who paid, amount, split equal / exact amounts /
percent), recurring monthly bills (rent, internet, utilities) created
automatically, due dates and "mark paid", running balance ("Sam owes you $42.10"),
"settle up" payments, history, and a receipt attachment. Money is stored as integer
cents, never floating point, the way you'd use `decimal`/`BigDecimal`.

**Files**: upload, download and preview images and PDFs, folders, drag-and-drop
on desktop, camera upload on phone. Free tier allows up to 50 MB per file.

**Settings**: display name and color per person, calendar feed links, theme.

## 4. Data model (Postgres)

```
profiles        (id = auth user, display_name, color)
allowed_emails  (email)                          -- signup allowlist
events          (id, title, starts_at, ends_at, all_day, owner_id|null=household,
                 location, notes, created_by)
calendar_feeds  (id, name, kind 'airbnb'|'ical', url, color, owner_id, last_synced_at, last_error)
feed_events     (feed_id, uid, starts_at, ends_at, all_day, summary, details)
reminders       (id, title, notes, due_at, assignee 'a'|'b'|'both', repeat_rule,
                 completed_at, completed_by, created_by)
notes           (id, title, body_md, pinned, updated_at, updated_by)
bills           (id, title, amount_cents, paid_by, incurred_on, due_on, category,
                 split_type, recurring_template_id, receipt_path, notes)
bill_shares     (bill_id, user_id, share_cents)  -- shares always sum to amount_cents
settlements     (id, from_user, to_user, amount_cents, paid_on, note)
files           (id, storage_path, name, folder, size_bytes, mime, uploaded_by)
```

## 5. Security and privacy

- Only the two allowlisted emails can create accounts. A database trigger rejects
  every other signup.
- Row-Level Security on every table and on the storage bucket: no data is visible
  without a member login.
- Files live in a private bucket and open only through short-lived signed URLs.
- The Airbnb/iCal links are stored in the database behind RLS, **never in the
  repo**. They contain a secret token.
- The repo is public (that's what makes GitHub Pages free), so it holds **no
  personal data or secrets**. The Supabase key in the frontend is the publishable
  key, which is designed to be public; RLS is what protects the data. The two
  allowlisted emails are added straight to the database, not in a committed file.

## 6. Hosting and cost: $0/month

- **GitHub Pages**: free for public repos.
- **Supabase free plan**: the "Desky" org is on the free plan with 1 of its 2 free
  project slots used, so a new project `roommate-hub` costs nothing. Limits: 500 MB
  database, about 1 GB file storage (confirm at setup), 5 GB transfer per month.
- **Caveat**: free Supabase projects pause after 7 days with no use. Data is kept
  and one click restores it. A daily GitHub Actions "keep-alive" ping prevents
  the pause. Upgrade path if you outgrow it: Supabase Pro, $25/month.

## 7. Build phases and model assignment

The main session (Claude Opus 5.5) runs the project and does the foundation work.
Well-specified feature modules go to parallel subagents, each in its own git
worktree and confined to `src/features/<module>/`, so they can't collide.

| # | Task | Model | Why this model |
|---|---|---|---|
| 0 | Plan and architecture (this doc) | Opus 5.5 | Done |
| 1 | Supabase project, schema migrations, RLS, storage policies, signup allowlist | Opus 5.5 | Security-critical foundation that everything else builds on |
| 2 | App shell: Vite/React/TS scaffold, login, layout/nav, PWA, shared hooks, design tokens | Opus 5.5 | Sets the patterns the parallel workers copy |
| 3a | Schedule module (calendar views, event CRUD) | Sonnet 5.5 | Well-specified CRUD + UI; fast and half Opus's price |
| 3b | Reminders module | Sonnet 5.5 | Same |
| 3c | Notes module | Sonnet 5.5 | Same |
| 3d | Files module | Sonnet 5.5 | Same |
| 3e | Bills and balances module | Opus 5.5 | Money math: splits, rounding to the cent, balances |
| 4 | `sync-calendars` Edge Function + pg_cron schedule | Opus 5.5 | Server-side, handles secrets, iCal edge cases (time zones, all-day dates) |
| 5 | Home dashboard + integrating all modules | Opus 5.5 | Cross-module wiring |
| 6 | Unit + end-to-end tests; phone/desktop screenshot QA and fixes | Sonnet 5.5 | Mechanical, high-volume, well-defined |
| 7 | README, user guide (incl. how to find the Airbnb export link), demo seed data | Haiku 5.5 | Simple writing from given facts; very cheap |
| 8 | Full code review of the diff | Opus 5.5 | Broad correctness pass |
| 9 | Security review: RLS, storage, auth, Edge Function | Fable 5.1 | Most capable model, for the highest-stakes check; small input keeps the cost low |
| 10 | Deploy workflow, keep-alive job, go-live checks | Opus 5.5 | Touches GitHub settings and production config |

Relative API price per million tokens (input/output): Fable 5.1 $10/$50,
Opus 5.5 $4/$20, Sonnet 5.5 $2/$10, Haiku 5.5 $0.10/$0.50. Fable is used once,
where depth matters and the volume is small. Haiku is kept to low-risk text work,
because a subtle bug in feature code costs more to fix than the model saves.

## 8. Steps only you can do (~10 minutes total)

1. GitHub: Settings → Pages → Source: **GitHub Actions** (one click).
2. Supabase dashboard: Authentication → URL Configuration → set the Site URL to
   the app's address, so signup confirmation emails link back correctly.
3. Give me the two email addresses for the allowlist, before go-live.
4. After launch, paste the Airbnb *Export calendar* link into the app's Settings
   (Airbnb → Calendar → Availability → Connect calendars → Export calendar).
5. Each of you: open the URL on your phone → Share → **Add to Home Screen**.

## 9. Open questions

1. **Where it lives.** Recommended: a new public repo `brogwalkerh/roommate-hub`,
   served at `https://brogwalkerh.github.io/roommate-hub/`. `Clone-appies` keeps one
   app per branch on an otherwise empty `main`, and a repo gets only one Pages
   site. Alternative: a branch in `Clone-appies`, served at
   `https://brogwalkerh.github.io/Clone-appies/`. That needs a Pages setting so it
   can deploy from a non-default branch.
2. **Airbnb.** Do you host the listing, so you can get its export link? One listing
   or several?
3. **Phone push notifications for reminders.** In v1 (one extra phase; on iPhone it
   only works once the app is added to the Home Screen) or later?
4. **Emails.** Should your login be brogwalkerh@gmail.com? What's your roommate's
   email? This can wait until go-live.

## 10. Later ideas (not in v1)

- Snap a photo of a bill and have Claude Haiku 5.5 fill in the amount and due date.
  Needs an Anthropic API key; costs pennies a month at this volume.
- Venmo/Zelle "pay now" links on balances.
- Chore rotation (auto-alternating assignee).
- Two-way Google Calendar sync. v1 imports read-only.
