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
-- =====================================================================
--  BATTLESHIPS — shop (step 2). Safe to run again.
--  Prices live here on the server, so nobody can buy things cheaper by editing the game.
-- =====================================================================

alter table public.profiles add column if not exists equipped jsonb not null default '{}'::jsonb;

create table if not exists public.owned_items (
  player    uuid not null references auth.users(id) on delete cascade,
  item      text not null,
  bought_at timestamptz not null default now(),
  primary key (player, item)
);
alter table public.owned_items enable row level security;
-- no policies: only the functions below touch this table

-- price list (free starter items are not listed: everyone owns them)
create or replace function public.bs_items() returns jsonb language sql immutable as $$
  select '{
    "board.toxic": 150, "board.glacier": 150, "board.midnight": 250, "board.royal": 300, "board.lava": 400, "board.gold": 800,
    "sea.tropical": 120, "sea.arctic": 150, "sea.night": 200, "sea.sunset": 300, "sea.abyss": 400,
    "ship.navy": 100, "ship.desert": 150, "ship.arctic": 150, "ship.crimson": 250, "ship.stealth": 350, "ship.neon": 500, "ship.gold": 1000
  }'::jsonb
$$;
create or replace function public.bs_free_item(p text) returns boolean language sql immutable as $$
  select p in ('board.classic', 'sea.classic', 'ship.steel')
$$;

create or replace function public.bs_profile_json(me uuid) returns json
language plpgsql security definer set search_path = public as $$
declare r public.profiles;
begin
  select * into r from profiles where id = me;
  return json_build_object('name', r.name, 'coins', r.coins, 'wins', r.wins, 'losses', r.losses,
    'equipped', r.equipped,
    'owned', coalesce((select json_agg(item order by item) from owned_items where player = me), '[]'::json));
end $$;

create or replace function public.my_profile(p_name text default null)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into profiles (id, name) values (me, bs_clean_name(p_name)) on conflict (id) do nothing;
  if p_name is not null and btrim(p_name) <> '' then
    update profiles set name = bs_clean_name(p_name) where id = me;
  end if;
  return bs_profile_json(me);
end $$;

create or replace function public.buy_item(p_item text)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); price int; have int;
begin
  if me is null then raise exception 'not signed in'; end if;
  price := (bs_items() ->> p_item)::int;
  if price is null then raise exception 'unknown item'; end if;
  insert into profiles (id) values (me) on conflict (id) do nothing;
  select coins into have from profiles where id = me for update;
  if exists (select 1 from owned_items where player = me and item = p_item) then return bs_profile_json(me); end if;
  if have < price then raise exception 'not enough coins'; end if;
  update profiles set coins = coins - price where id = me;
  insert into owned_items (player, item) values (me, p_item);
  return bs_profile_json(me);
end $$;

create or replace function public.equip_item(p_item text)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); slot text := split_part(coalesce(p_item, ''), '.', 1);
begin
  if me is null then raise exception 'not signed in'; end if;
  if slot not in ('board', 'sea', 'ship') then raise exception 'unknown item'; end if;
  if not bs_free_item(p_item) and not exists (select 1 from owned_items where player = me and item = p_item) then
    raise exception 'not owned';
  end if;
  insert into profiles (id) values (me) on conflict (id) do nothing;
  update profiles set equipped = equipped || jsonb_build_object(slot, p_item) where id = me;
  return bs_profile_json(me);
end $$;

revoke all on function public.bs_profile_json(uuid) from public, anon, authenticated;
revoke all on function public.my_profile(text)      from public, anon;
revoke all on function public.buy_item(text)        from public, anon;
revoke all on function public.equip_item(text)      from public, anon;
grant execute on function public.my_profile(text)   to authenticated;
grant execute on function public.buy_item(text)     to authenticated;
grant execute on function public.equip_item(text)   to authenticated;
