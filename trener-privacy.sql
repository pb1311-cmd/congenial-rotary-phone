-- ============================================================
--  «Круговой тренер» — полная приватность (шаг 2 из 2)
--  Вызовы на дуэль — только по коду. Имя и счёт видят лишь двое участников дуэли.
--  Журнал, программы, веса и замеры — только сам человек.
-- ============================================================

-- Счёт теперь хранится отдельно по каждой дуэли.
-- Старая таблица (с колонкой duels) пересоздаётся только один раз; при повторном запуске данные не трогаются.
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='duel_scores' and column_name='duels') then
    drop table public.duel_scores;
  end if;
end $$;
create table if not exists public.duel_scores (
  duel_id text not null references public.duels(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  workouts int not null default 0 check (workouts >= 0),
  minutes int not null default 0 check (minutes >= 0),
  exercises int not null default 0 check (exercises >= 0),
  updated_at timestamptz not null default now(),
  primary key (duel_id, user_id)
);
alter table public.duel_scores enable row level security;

-- Участник ли текущий человек этой дуэли
create or replace function public.is_duel_member(did text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.duels d where d.id = did and auth.uid() in (d.a, d.b));
$$;
revoke all on function public.is_duel_member(text) from public;
grant execute on function public.is_duel_member(text) to authenticated;

-- Связаны ли двое людей хотя бы одной дуэлью (чтобы видеть имя соперника)
create or replace function public.is_duel_partner(other uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.duels d
                  where (d.a = auth.uid() and (d.b = other or d.invite = other))
                     or (d.b = auth.uid() and d.a = other)
                     or (d.invite = auth.uid() and d.a = other));
$$;
revoke all on function public.is_duel_partner(uuid) from public;
grant execute on function public.is_duel_partner(uuid) to authenticated;

-- Профили: своё имя + имена соперников
drop policy if exists "profiles: read" on public.profiles;
create policy "profiles: read" on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_duel_partner(id));

-- Дуэли: только свои и адресованные вам реваншы; общих открытых вызовов не видно
drop policy if exists "duels: read" on public.duels;
create policy "duels: read" on public.duels for select to authenticated
  using (a = auth.uid() or b = auth.uid() or (b is null and invite = auth.uid()));

-- Код вызова — это id дуэли: 6–12 символов A–Z и 2–9
alter table public.duels drop constraint if exists duels_code_format;
alter table public.duels add constraint duels_code_format check (id ~ '^[A-Z2-9]{6,12}$');

-- Посмотреть вызов по коду перед принятием (имя автора, условия)
create or replace function public.peek_duel(code text)
returns json language plpgsql stable security definer set search_path = public as $$
declare d public.duels; nm text;
begin
  select * into d from public.duels
   where id = upper(trim(code)) and b is null and a <> auth.uid()
     and (invite is null or invite = auth.uid());
  if d.id is null then raise exception 'duel_unavailable'; end if;
  select display_name into nm from public.profiles where id = d.a;
  return json_build_object('id', d.id, 'metric', d.metric, 'days', d.days, 'stake', d.stake, 'name', coalesce(nm, ''));
end;
$$;
revoke all on function public.peek_duel(text) from public;
grant execute on function public.peek_duel(text) to authenticated;

-- Принять вызов по коду (первый принявший становится соперником)
create or replace function public.accept_duel(duel_id text)
returns public.duels language plpgsql security definer set search_path = public as $$
declare
  d public.duels;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  update public.duels
     set b = auth.uid(), start_at = now_ms, end_at = now_ms + days::bigint * 86400000
   where id = upper(trim(duel_id))
     and b is null
     and a <> auth.uid()
     and (invite is null or invite = auth.uid())
  returning * into d;
  if d.id is null then raise exception 'duel_unavailable'; end if;
  return d;
end;
$$;
revoke all on function public.accept_duel(text) from public;
grant execute on function public.accept_duel(text) to authenticated;

-- Счёт: видят оба участника дуэли, пишет только сам человек и только в своих дуэлях
drop policy if exists "duel_scores: read" on public.duel_scores;
create policy "duel_scores: read" on public.duel_scores for select to authenticated using (public.is_duel_member(duel_id));
drop policy if exists "duel_scores: insert own" on public.duel_scores;
create policy "duel_scores: insert own" on public.duel_scores for insert to authenticated
  with check (user_id = auth.uid() and public.is_duel_member(duel_id));
drop policy if exists "duel_scores: update own" on public.duel_scores;
create policy "duel_scores: update own" on public.duel_scores for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.is_duel_member(duel_id));

-- мгновенное обновление
do $$
begin
  begin alter publication supabase_realtime add table public.duels;       exception when others then null; end;
  begin alter publication supabase_realtime add table public.duel_scores; exception when others then null; end;
end $$;
