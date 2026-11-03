-- ============================================================
--  «Круговой тренер» — база данных для входа, синхронизации и дуэлей
--  Вставьте весь текст в Supabase → SQL Editor → New query → Run.
--  Скрипт можно запускать повторно: он ничего не удалит из данных.
-- ============================================================

-- Профиль: имя, которое видят соперники в дуэлях
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 40),
  updated_at timestamptz not null default now()
);

-- Программы и замеры тела (по одной строке на человека)
create table if not exists public.user_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  programs jsonb not null default '[]'::jsonb,
  body jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

-- Журнал тренировок (одна строка — одна тренировка)
create table if not exists public.workouts (
  user_id uuid not null references auth.users(id) on delete cascade,
  at bigint not null,
  data jsonb not null,
  primary key (user_id, at)
);

-- Дуэли
create table if not exists public.duels (
  id text primary key check (char_length(id) <= 64),
  a uuid not null references auth.users(id) on delete cascade,
  b uuid references auth.users(id) on delete cascade,
  invite uuid references auth.users(id) on delete cascade,
  metric text not null check (metric in ('workouts','minutes','exercises')),
  days int not null check (days in (3,7,14)),
  stake text not null default '' check (char_length(stake) <= 80),
  created_at bigint not null,
  start_at bigint,
  end_at bigint
);

-- Счёт в дуэлях (видят все участники, пишет только сам человек)
create table if not exists public.duel_scores (
  user_id uuid primary key references auth.users(id) on delete cascade,
  duels jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.profiles    enable row level security;
alter table public.user_data   enable row level security;
alter table public.workouts    enable row level security;
alter table public.duels       enable row level security;
alter table public.duel_scores enable row level security;

-- ---------- правила доступа ----------
drop policy if exists "profiles: read" on public.profiles;
create policy "profiles: read" on public.profiles for select to authenticated using (true);
drop policy if exists "profiles: insert own" on public.profiles;
create policy "profiles: insert own" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- свои программы, замеры и журнал видит и меняет только сам человек
drop policy if exists "user_data: own" on public.user_data;
create policy "user_data: own" on public.user_data for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "workouts: own" on public.workouts;
create policy "workouts: own" on public.workouts for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- дуэли: свои + открытые вызовы (общие или адресованные вам)
drop policy if exists "duels: read" on public.duels;
create policy "duels: read" on public.duels for select to authenticated
  using (a = auth.uid() or b = auth.uid() or (b is null and (invite is null or invite = auth.uid())));
drop policy if exists "duels: create own" on public.duels;
create policy "duels: create own" on public.duels for insert to authenticated
  with check (a = auth.uid() and b is null and start_at is null and end_at is null);
drop policy if exists "duels: cancel own open" on public.duels;
create policy "duels: cancel own open" on public.duels for delete to authenticated using (a = auth.uid() and b is null);

-- принять вызов можно только через эту функцию: первый принявший становится соперником
create or replace function public.accept_duel(duel_id text)
returns public.duels
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.duels;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  update public.duels
     set b = auth.uid(), start_at = now_ms, end_at = now_ms + days::bigint * 86400000
   where id = duel_id
     and b is null
     and a <> auth.uid()
     and (invite is null or invite = auth.uid())
  returning * into d;
  if d.id is null then
    raise exception 'duel_unavailable';
  end if;
  return d;
end;
$$;
revoke all on function public.accept_duel(text) from public;
grant execute on function public.accept_duel(text) to authenticated;

drop policy if exists "duel_scores: read" on public.duel_scores;
create policy "duel_scores: read" on public.duel_scores for select to authenticated using (true);
drop policy if exists "duel_scores: insert own" on public.duel_scores;
create policy "duel_scores: insert own" on public.duel_scores for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "duel_scores: update own" on public.duel_scores;
create policy "duel_scores: update own" on public.duel_scores for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- мгновенное обновление счёта и вызовов у соперника
do $$
begin
  begin alter publication supabase_realtime add table public.duels;       exception when others then null; end;
  begin alter publication supabase_realtime add table public.duel_scores; exception when others then null; end;
end $$;
