# Desklight — a helpdesk app on React + Supabase

A minimal but complete support-ticket system: customers file tickets, agents
and admins work them from shared queues, and every access rule is enforced
by Postgres row-level security (RLS) rather than app code — so the rules
hold even if you build another client later.

## Stack

- **Frontend:** React 18 + Vite, plain CSS (no framework), realtime updates
  via Supabase's Postgres change subscriptions.
- **Backend:** Supabase — Postgres, Auth, and RLS. No separate API server;
  the browser talks to Supabase directly using the anon key, and RLS is
  what keeps that safe.

## Data model

- `profiles` — one row per auth user, holding `role` (`customer`, `agent`,
  `admin`). Created automatically by a trigger on `auth.users` insert.
- `tickets` — subject, description, `status`, `priority`, `customer_id`,
  `assigned_agent_id`.
- `ticket_comments` — thread on a ticket, with an `is_internal` flag for
  agent-only notes that customers never see.

## Access rules (enforced in Postgres, see `supabase/schema.sql`)

| Who | Tickets | Comments |
|---|---|---|
| Customer | read/create/update **their own** tickets only | read/write non-internal comments on their own tickets only |
| Agent | read/update **all** tickets | read/write all comments, including internal notes |
| Admin | everything, plus delete and role management | everything |

Two `security definer` helper functions (`is_agent_or_admin()`,
`is_admin()`) are used inside the policies instead of subqueries on
`profiles` directly, to avoid RLS recursion issues.

## Setup

### 1. Create a Supabase project

Create a project at [supabase.com](https://supabase.com), then open the SQL
editor and run the full contents of `supabase/schema.sql`. This creates the
tables, the `handle_new_user` trigger, and every RLS policy in one shot.

### 2. Create your first admin

Sign up through the app once (this creates a `profiles` row with the
default `customer` role), then in the SQL editor run:

```sql
update public.profiles set role = 'admin' where email = 'you@example.com';
```

From there, an admin can promote others to `agent` by updating their row
the same way (or you can build a small admin screen — the RLS policy for
it is already in place: `profiles: admins manage all`).

### 3. Configure the frontend

```bash
cp .env.example .env
# fill in VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY from
# Project Settings → API in the Supabase dashboard
npm install
npm run dev
```

The app runs at `http://localhost:5173`.

### 4. Email confirmation (optional but recommended)

By default Supabase requires email confirmation before sign-in. For local
testing you can turn this off under Authentication → Providers → Email →
"Confirm email", or keep it on and use the confirmation link Supabase
emails out.

## Project layout

```
supabase/schema.sql        tables, trigger, RLS policies
src/lib/supabaseClient.js  Supabase client singleton
src/lib/AuthContext.jsx    session + profile/role, sign in/up/out
src/components/
  AuthScreen.jsx           sign in / sign up
  Rail.jsx                 left nav, role-aware queues
  TicketList.jsx           dense ticket list ("ledger")
  NewTicketForm.jsx        customer: file a new ticket
  TicketDetail.jsx         case file: thread, status/priority/assignment
src/App.jsx                wires queues to Supabase queries per role
```

## Extending it

- **Attachments:** add a `ticket_attachments` table pointing at Supabase
  Storage objects, with an RLS policy mirroring `ticket_comments`.
- **Email notifications:** a Postgres trigger on `ticket_comments` insert
  can call a Supabase Edge Function to send mail.
- **SLA timers / auto-escalation:** a scheduled Edge Function (pg_cron) that
  bumps `priority` or pings agents when a ticket sits in `open` too long.
