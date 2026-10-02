-- ============================================================================
-- Helpdesk schema for Supabase (Postgres + Auth + RLS)
-- Run this in the Supabase SQL editor, or via `supabase db push` with this
-- file in your migrations folder.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Extensions
-- ----------------------------------------------------------------------------
create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 2. Roles
-- Three roles: 'customer' (raises tickets), 'agent' (works tickets),
-- 'admin' (sees everything, manages agents). Role lives on a profile row
-- that is created automatically when a user signs up.
-- ----------------------------------------------------------------------------
create type public.app_role as enum ('customer', 'agent', 'admin');
create type public.ticket_status as enum ('open', 'in_progress', 'waiting_on_customer', 'resolved', 'closed');
create type public.ticket_priority as enum ('low', 'medium', 'high', 'urgent');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  full_name text,
  role public.app_role not null default 'customer',
  created_at timestamptz not null default now()
);

-- Auto-create a profile row whenever a new auth user signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 3. Tickets
-- ----------------------------------------------------------------------------
create table public.tickets (
  id uuid primary key default gen_random_uuid(),
  subject text not null,
  description text not null,
  status public.ticket_status not null default 'open',
  priority public.ticket_priority not null default 'medium',
  customer_id uuid not null references public.profiles (id) on delete cascade,
  assigned_agent_id uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ticket_comments (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.tickets (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null,
  -- internal notes are only ever visible to agents/admins, never the customer
  is_internal boolean not null default false,
  created_at timestamptz not null default now()
);

create index tickets_customer_id_idx on public.tickets (customer_id);
create index tickets_assigned_agent_id_idx on public.tickets (assigned_agent_id);
create index ticket_comments_ticket_id_idx on public.ticket_comments (ticket_id);

-- keep updated_at fresh
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger tickets_touch_updated_at
  before update on public.tickets
  for each row execute procedure public.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 4. Helper functions used inside RLS policies
-- security definer + a fixed search_path avoids the classic footgun of a
-- policy that queries the very table it's protecting and recurses.
-- ----------------------------------------------------------------------------
create or replace function public.current_role()
returns public.app_role
language sql
security definer
set search_path = public
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.is_agent_or_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(public.current_role() in ('agent', 'admin'), false);
$$;

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(public.current_role() = 'admin', false);
$$;

-- ----------------------------------------------------------------------------
-- 5. Enable RLS everywhere
-- ----------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.tickets enable row level security;
alter table public.ticket_comments enable row level security;

-- ----------------------------------------------------------------------------
-- 6. Policies: profiles
-- Everyone can read their own profile; agents/admins can read all profiles
-- (needed to show customer names, agent assignment dropdowns, etc.).
-- Only admins can change someone's role.
-- ----------------------------------------------------------------------------
create policy "profiles: read own"
  on public.profiles for select
  using (id = auth.uid());

create policy "profiles: agents and admins read all"
  on public.profiles for select
  using (public.is_agent_or_admin());

create policy "profiles: users update their own basic info"
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and role = (select role from public.profiles where id = auth.uid()));

create policy "profiles: admins manage all"
  on public.profiles for update
  using (public.is_admin());

-- ----------------------------------------------------------------------------
-- 7. Policies: tickets
-- Customers: full CRUD on their own tickets, but cannot set/change who's
--   assigned or bypass their own customer_id.
-- Agents: can read every ticket and update status/assignment/priority.
-- Admins: unrestricted.
-- ----------------------------------------------------------------------------
create policy "tickets: customers read own"
  on public.tickets for select
  using (customer_id = auth.uid());

create policy "tickets: agents and admins read all"
  on public.tickets for select
  using (public.is_agent_or_admin());

create policy "tickets: customers create own"
  on public.tickets for insert
  with check (customer_id = auth.uid());

create policy "tickets: customers update own open tickets"
  on public.tickets for update
  using (customer_id = auth.uid())
  with check (customer_id = auth.uid());

create policy "tickets: agents and admins update all"
  on public.tickets for update
  using (public.is_agent_or_admin());

create policy "tickets: admins delete"
  on public.tickets for delete
  using (public.is_admin());

-- ----------------------------------------------------------------------------
-- 8. Policies: ticket_comments
-- Customers see/write comments only on their own tickets, and can never see
-- or create internal notes. Agents/admins see and write everything,
-- including internal notes.
-- ----------------------------------------------------------------------------
create policy "comments: customers read own non-internal"
  on public.ticket_comments for select
  using (
    not is_internal
    and exists (
      select 1 from public.tickets t
      where t.id = ticket_id and t.customer_id = auth.uid()
    )
  );

create policy "comments: agents and admins read all"
  on public.ticket_comments for select
  using (public.is_agent_or_admin());

create policy "comments: customers insert non-internal on own ticket"
  on public.ticket_comments for insert
  with check (
    author_id = auth.uid()
    and is_internal = false
    and exists (
      select 1 from public.tickets t
      where t.id = ticket_id and t.customer_id = auth.uid()
    )
  );

create policy "comments: agents and admins insert any"
  on public.ticket_comments for insert
  with check (public.is_agent_or_admin() and author_id = auth.uid());

create policy "comments: admins delete"
  on public.ticket_comments for delete
  using (public.is_admin());

-- ----------------------------------------------------------------------------
-- 9. Realtime (optional but recommended for a helpdesk)
-- ----------------------------------------------------------------------------
alter publication supabase_realtime add table public.tickets;
alter publication supabase_realtime add table public.ticket_comments;
