-- =====================================================================
--  BATTLESHIPS — accounts + coins (step 1)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again later (it only adds what is missing / updates functions).
-- =====================================================================

-- ---------- player profiles ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default 'Captain',
  coins      integer not null default 0 check (coins >= 0),
  wins       integer not null default 0,
  losses     integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
  for select to authenticated using (id = (select auth.uid()));
-- no insert/update policies: players can't edit their own coins, only the functions below can

-- ---------- one row per player per multiplayer match ----------
create table if not exists public.match_players (
  match_id   text not null,
  player     uuid not null references auth.users(id) on delete cascade,
  opponent   uuid not null,
  started_at timestamptz not null default now(),
  result     text check (result in ('win', 'loss')),
  opp_left   boolean not null default false,
  reward     integer,              -- null = not settled yet
  primary key (match_id, player)
);
alter table public.match_players enable row level security;
-- no policies at all: only the functions below touch this table

-- ---------- rules ----------
create or replace function public.bs_rules() returns json language sql immutable as $$
  select json_build_object('win', 30, 'loss', 10, 'min_seconds', 90)
$$;

create or replace function public.bs_clean_name(n text) returns text language sql immutable as $$
  select coalesce(nullif(left(btrim(regexp_replace(regexp_replace(coalesce(n, ''), '[<>&"''`]', '', 'g'), '\s+', ' ', 'g')), 14), ''), 'Captain')
$$;

-- ---------- my profile (creates it the first time; optionally sets my name) ----------
create or replace function public.my_profile(p_name text default null)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.profiles;
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into profiles (id, name) values (me, bs_clean_name(p_name)) on conflict (id) do nothing;
  if p_name is not null and btrim(p_name) <> '' then
    update profiles set name = bs_clean_name(p_name) where id = me;
  end if;
  select * into r from profiles where id = me;
  return json_build_object('name', r.name, 'coins', r.coins, 'wins', r.wins, 'losses', r.losses);
end $$;

-- ---------- a multiplayer battle started ----------
create or replace function public.start_match(p_match text, p_opponent uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_opponent is null or p_opponent = me or p_match is null or length(p_match) not between 8 and 40 then
    raise exception 'bad match';
  end if;
  insert into profiles (id) values (me) on conflict (id) do nothing;
  insert into match_players (match_id, player, opponent) values (p_match, me, p_opponent)
    on conflict (match_id, player) do nothing;
end $$;

-- internal: pay one player
create or replace function public.bs_pay(p uuid, amount integer, won boolean, counts boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id) values (p) on conflict (id) do nothing;
  update profiles set
    coins  = coins + amount,
    wins   = wins   + case when counts and won     then 1 else 0 end,
    losses = losses + case when counts and not won then 1 else 0 end
  where id = p;
end $$;

-- ---------- a multiplayer battle ended (safe to call again: it just reports the result) ----------
-- Rules:
--   * a LOSS report settles the match at once: loser +10, the other player +30
--   * a WIN report waits for the opponent's loss report
--     (or settles alone when the opponent quit mid-game: winner +30, quitter 0)
--   * both players claim a win -> nobody gets coins
--   * battles shorter than 90 seconds pay nothing
create or replace function public.finish_match(p_match text, p_won boolean, p_opp_left boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  mine match_players; theirs match_players;
  r json := bs_rules();
  win_c int := (r->>'win')::int; loss_c int := (r->>'loss')::int;
  too_short boolean; my_win boolean; pay_me int; pay_them int;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into mine from match_players where match_id = p_match and player = me for update;
  if not found then return json_build_object('status', 'unknown'); end if;

  if mine.reward is null then
    if mine.result is null then
      update match_players set result = case when p_won then 'win' else 'loss' end, opp_left = coalesce(p_opp_left, false)
        where match_id = p_match and player = me
        returning * into mine;
    end if;

    select * into theirs from match_players where match_id = p_match and player = mine.opponent for update;
    if not found or theirs.opponent <> me then
      return json_build_object('status', 'pending');
    end if;

    if theirs.reward is not null then
      -- they were already paid alone (I quit) -> nothing for me
      update match_players set reward = 0 where match_id = p_match and player = me returning * into mine;
    else
      too_short := now() - least(mine.started_at, theirs.started_at) < make_interval(secs => (r->>'min_seconds')::int);
      if mine.result = 'loss' or theirs.result = 'loss' then
        if mine.result = 'loss' and theirs.result = 'loss' then
          -- both say they lost: odd, pay nobody
          update match_players set reward = 0 where match_id = p_match and player in (me, theirs.player);
        else
          my_win   := mine.result is distinct from 'loss';     -- one side admitted the loss; if it wasn't me, I won
          pay_me   := case when too_short then 0 when my_win then win_c else loss_c end;
          pay_them := case when too_short then 0 when my_win then loss_c else win_c end;
          update match_players set reward = pay_me   where match_id = p_match and player = me;
          update match_players set reward = pay_them where match_id = p_match and player = theirs.player;
          perform bs_pay(me, pay_me, my_win, not too_short);
          perform bs_pay(theirs.player, pay_them, not my_win, not too_short);
        end if;
      elsif mine.result = 'win' and theirs.result = 'win' then
        update match_players set reward = 0 where match_id = p_match and player in (me, theirs.player);
      elsif mine.result = 'win' and mine.opp_left and theirs.result is null then
        pay_me := case when too_short then 0 else win_c end;
        update match_players set reward = pay_me where match_id = p_match and player = me;
        update match_players set reward = 0      where match_id = p_match and player = theirs.player;
        perform bs_pay(me, pay_me, true, not too_short);
        perform bs_pay(theirs.player, 0, false, not too_short);
      else
        return json_build_object('status', 'pending');
      end if;
      select * into mine from match_players where match_id = p_match and player = me;
    end if;
  end if;

  return json_build_object('status', 'done', 'reward', mine.reward,
                           'coins', (select coins from profiles where id = me));
end $$;

-- ---------- who may call what ----------
revoke all on function public.bs_pay(uuid, integer, boolean, boolean) from public, anon, authenticated;
revoke all on function public.my_profile(text)                   from public, anon;
revoke all on function public.start_match(text, uuid)            from public, anon;
revoke all on function public.finish_match(text, boolean, boolean) from public, anon;
grant execute on function public.my_profile(text)                    to authenticated;
grant execute on function public.start_match(text, uuid)             to authenticated;
grant execute on function public.finish_match(text, boolean, boolean) to authenticated;
