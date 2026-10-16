-- Hundraårsskeppet: the shared ship. All access goes through SECURITY DEFINER functions;
-- the tables have row level security on and no policies, so the anon key cannot read or write them directly.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.hs_players(
  id uuid primary key,
  secret_hash text not null,
  name text not null default '',
  pub jsonb not null default '{}'::jsonb,
  save jsonb,
  created_at timestamptz not null default now(),
  seen_at timestamptz not null default now()
);
create table if not exists public.hs_donations(
  id bigint generated always as identity primary key,
  player uuid not null references public.hs_players(id) on delete cascade,
  project text not null,
  amount numeric not null default 0,
  work numeric not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists hs_donations_project on public.hs_donations(project);
create table if not exists public.hs_votes(
  player uuid primary key references public.hs_players(id) on delete cascade,
  project text not null,
  round int not null default 0
);
create table if not exists public.hs_ship(
  id int primary key,
  state jsonb not null default '{}'::jsonb,
  version int not null default 0
);
insert into public.hs_ship(id,state) values (1,'{}'::jsonb) on conflict (id) do nothing;
alter table public.hs_players enable row level security;
alter table public.hs_donations enable row level security;
alter table public.hs_votes enable row level security;
alter table public.hs_ship enable row level security;

-- one real hour = one ship day; day 0 = 2026-10-15 00:00 UTC
create or replace function public.hs_now() returns double precision language sql stable set search_path = '' as $$ select extract(epoch from now())*1000 $$;
create or replace function public.hs_gt() returns double precision language sql stable set search_path = '' as $$ select (extract(epoch from now())*1000 - 1792022400000)/2500.0 $$;
create or replace function public.hs_cost(p text) returns numeric language sql immutable set search_path = '' as $$
  select case p when 'bastu' then 1500 when 'vaxthus' then 2400 when 'scen' then 3200 else 999999 end $$;

create or replace function public.hs_auth(p_id uuid, p_secret text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_secret is null or not exists(select 1 from hs_players where id = p_id and secret_hash = encode(digest(p_secret,'sha256'),'hex')) then
    raise exception 'auth';
  end if;
end $$;

create or replace function public.hs_register(p_id uuid, p_secret text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_home text;
begin
  if p_secret is null or length(p_secret) < 16 then raise exception 'secret'; end if;
  if exists(select 1 from hs_players where id = p_id) then
    perform hs_auth(p_id, p_secret);
    select pub->>'home' into v_home from hs_players where id = p_id;
    return jsonb_build_object('ok', true, 'home', v_home, 'existing', true);
  end if;
  select c into v_home
    from unnest(array['hytt15','hytt16','hytt17','hytt18','hytt19','hytt20','hytt21','hytt22']) with ordinality as t(c, o)
    order by (select count(*) from hs_players where pub->>'home' = c), o limit 1;
  insert into hs_players(id, secret_hash, name, pub)
    values (p_id, encode(digest(p_secret,'sha256'),'hex'), left(coalesce(p_name,''),18), jsonb_build_object('home', v_home, 'name', left(coalesce(p_name,''),18)));
  return jsonb_build_object('ok', true, 'home', v_home, 'existing', false);
end $$;

create or replace function public.hs_load(p_id uuid, p_secret text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  perform hs_auth(p_id, p_secret);
  select save, pub into r from hs_players where id = p_id;
  return jsonb_build_object('save', r.save, 'pub', r.pub);
end $$;

create or replace function public.hs_save(p_id uuid, p_secret text, p_save jsonb, p_pub jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_home text;
begin
  perform hs_auth(p_id, p_secret);
  if pg_column_size(p_save) > 300000 or pg_column_size(p_pub) > 12000 then raise exception 'size'; end if;
  select pub->>'home' into v_home from hs_players where id = p_id;
  update hs_players
     set save = p_save,
         pub = jsonb_set(coalesce(p_pub,'{}'::jsonb), '{home}', to_jsonb(v_home)),
         name = left(coalesce(p_pub->>'name', name), 18),
         seen_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true, 'now', extract(epoch from now())*1000);
end $$;

create or replace function public.hs_players_list() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'pub', pub, 'seen', extract(epoch from seen_at)*1000) order by created_at), '[]'::jsonb)
    from hs_players where save is not null $$;

create or replace function public.hs_ship_get() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'state', (select state from hs_ship where id = 1),
    'version', (select version from hs_ship where id = 1),
    'now', extract(epoch from now())*1000,
    'gt', hs_gt(),
    'sum', (select coalesce(jsonb_object_agg(project, s), '{}'::jsonb)
              from (select project, sum(amount) + sum(work)*0.8 as s from hs_donations group by project) x),
    'givers', (select coalesce(jsonb_object_agg(project, g), '{}'::jsonb)
              from (select project, jsonb_agg(jsonb_build_object('id', player, 'name', name, 'amount', a, 'work', w) order by a + w*0.8 desc) as g
                      from (select d.project, d.player, p.name, sum(d.amount) as a, sum(d.work) as w
                              from hs_donations d join hs_players p on p.id = d.player
                             group by d.project, d.player, p.name) y
                     group by project) x),
    'votes', (select coalesce(jsonb_object_agg(project, c), '{}'::jsonb)
              from (select v.project, count(*) as c from hs_votes v, hs_ship s
                     where s.id = 1 and v.round = coalesce((s.state->>'round')::int, 0)
                     group by v.project) z)
  ) $$;

-- the ship's state machine: vote → build → inauguration → open → next vote
create or replace function public.hs_tick() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s jsonb; gt double precision := hs_gt(); cur text; fund numeric; ch boolean := false;
  rem text[]; win text; t0 double precision; rnd int;
begin
  select state into s from hs_ship where id = 1 for update;
  rnd := coalesce((s->>'round')::int, 0);
  rem := array(select p from unnest(array['bastu','vaxthus','scen']) p where not (coalesce(s->'open','{}'::jsonb) ? p));
  if s ? 'inaug' and gt >= (s->'inaug'->>'t1')::double precision then
    s := jsonb_set(s, '{open}', coalesce(s->'open','{}'::jsonb) || jsonb_build_object(s->'inaug'->>'p', gt));
    s := s - 'inaug' - 'voteUntil';
    rnd := rnd + 1; s := jsonb_set(s, '{round}', to_jsonb(rnd)); ch := true;
    rem := array(select p from unnest(array['bastu','vaxthus','scen']) p where not (coalesce(s->'open','{}'::jsonb) ? p));
  end if;
  cur := s->>'cur';
  if cur is not null then
    select coalesce(sum(amount) + sum(work)*0.8, 0) into fund from hs_donations where project = cur;
    fund := fund + greatest(0, gt - coalesce((s->>'startT')::double precision, gt)) * 0.25;
    if fund >= hs_cost(cur) then
      t0 := floor(gt/1440)*1440 + 17*60;
      if t0 < gt + 150 then t0 := t0 + 1440; end if;
      s := jsonb_set(s, '{inaug}', jsonb_build_object('p', cur, 't0', t0, 't1', t0 + 120));
      s := jsonb_set(s, '{done}', coalesce(s->'done','{}'::jsonb) || jsonb_build_object(cur, gt));
      s := s - 'cur' - 'startT'; ch := true;
    end if;
  elsif not (s ? 'inaug') and coalesce(array_length(rem, 1), 0) > 0 then
    if not (s ? 'voteUntil') then
      s := jsonb_set(s, '{voteUntil}', to_jsonb(gt + 720)); ch := true;
    elsif gt >= (s->>'voteUntil')::double precision then
      select v.project into win from hs_votes v
       where v.round = rnd and v.project = any(rem)
       group by v.project
       order by count(*) desc, array_position(array['bastu','vaxthus','scen'], v.project) limit 1;
      if win is null then win := rem[1]; end if;
      s := jsonb_set(s, '{cur}', to_jsonb(win));
      s := jsonb_set(s, '{startT}', to_jsonb(gt));
      s := s - 'voteUntil'; ch := true;
    end if;
  end if;
  if ch then update hs_ship set state = s, version = version + 1 where id = 1; end if;
  return hs_ship_get();
end $$;

create or replace function public.hs_vote(p_id uuid, p_secret text, p_project text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s jsonb; rnd int; gt double precision := hs_gt();
begin
  perform hs_auth(p_id, p_secret);
  select state into s from hs_ship where id = 1 for update;
  if s ? 'cur' or s ? 'inaug' then return hs_ship_get(); end if;
  if p_project not in ('bastu','vaxthus','scen') or (coalesce(s->'open','{}'::jsonb) ? p_project) then raise exception 'project'; end if;
  rnd := coalesce((s->>'round')::int, 0);
  insert into hs_votes(player, project, round) values (p_id, p_project, rnd)
    on conflict (player) do update set project = excluded.project, round = excluded.round;
  -- the first vote gives everyone else one ship hour (two and a half minutes) to vote too
  if not (s ? 'voteUntil') or (s->>'voteUntil')::double precision > gt + 60 then
    update hs_ship set state = jsonb_set(s, '{voteUntil}', to_jsonb(gt + 60)), version = version + 1 where id = 1;
  end if;
  return hs_tick();
end $$;

create or replace function public.hs_donate(p_id uuid, p_secret text, p_project text, p_amount numeric, p_work numeric) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s jsonb;
begin
  perform hs_auth(p_id, p_secret);
  select state into s from hs_ship where id = 1;
  if (s->>'cur') is distinct from p_project then raise exception 'not_current'; end if;
  if p_amount < 0 or p_amount > 100000 or p_work < 0 or p_work > 600 then raise exception 'range'; end if;
  insert into hs_donations(player, project, amount, work) values (p_id, p_project, p_amount, p_work);
  return hs_tick();
end $$;

create or replace function public.hs_cut(p_id uuid, p_secret text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s jsonb; gt double precision := hs_gt(); nm text; p text; rnd int;
begin
  perform hs_auth(p_id, p_secret);
  select state into s from hs_ship where id = 1 for update;
  if not (s ? 'inaug') or gt < (s->'inaug'->>'t0')::double precision or gt >= (s->'inaug'->>'t1')::double precision then
    return jsonb_build_object('ok', false, 'ship', hs_ship_get());
  end if;
  select name into nm from hs_players where id = p_id;
  p := s->'inaug'->>'p'; rnd := coalesce((s->>'round')::int, 0);
  s := jsonb_set(s, '{open}', coalesce(s->'open','{}'::jsonb) || jsonb_build_object(p, gt));
  s := jsonb_set(s, '{cut}', coalesce(s->'cut','{}'::jsonb) || jsonb_build_object(p, jsonb_build_object('id', p_id, 'name', nm)));
  s := s - 'inaug'; s := jsonb_set(s, '{round}', to_jsonb(rnd + 1));
  update hs_ship set state = s, version = version + 1 where id = 1;
  return jsonb_build_object('ok', true, 'ship', hs_ship_get());
end $$;

revoke all on function public.hs_auth(uuid, text) from public, anon, authenticated;
grant execute on function public.hs_now(), public.hs_register(uuid,text,text), public.hs_load(uuid,text), public.hs_save(uuid,text,jsonb,jsonb),
  public.hs_players_list(), public.hs_ship_get(), public.hs_tick(), public.hs_vote(uuid,text,text), public.hs_donate(uuid,text,text,numeric,numeric),
  public.hs_cut(uuid,text) to anon, authenticated;

-- RLS already hides every row; also drop the default table grants so the API roles cannot touch the tables at all
revoke all on table public.hs_players, public.hs_donations, public.hs_votes, public.hs_ship from anon, authenticated;

-- chat: free text goes through the server, so a message always carries its real sender; kept for three days
create table if not exists public.hs_chat(
  id bigint generated always as identity primary key,
  player uuid not null references public.hs_players(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists hs_chat_created on public.hs_chat(created_at);
create index if not exists hs_chat_player on public.hs_chat(player, created_at);
alter table public.hs_chat enable row level security;
revoke all on table public.hs_chat from anon, authenticated;

create or replace function public.hs_chat_send(p_id uuid, p_secret text, p_body text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b text; r record; nm text;
begin
  perform hs_auth(p_id, p_secret);
  b := btrim(regexp_replace(regexp_replace(coalesce(p_body, ''), '[[:cntrl:]​-‏‪-‮⁦-⁩]', ' ', 'g'), '\s+', ' ', 'g'));
  b := left(b, 200);
  if b = '' then raise exception 'empty'; end if;
  if (select count(*) from hs_chat where player = p_id and created_at > now() - interval '10 seconds') >= 6 then raise exception 'rate'; end if;
  select name into nm from hs_players where id = p_id;
  insert into hs_chat(player, body) values (p_id, b) returning id, created_at into r;
  delete from hs_chat where created_at < now() - interval '3 days';
  return jsonb_build_object('id', r.id, 'u', p_id, 'n', nm, 'b', b, 't', r.created_at);
end $$;

create or replace function public.hs_chat_since(p_after bigint) returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at) order by x.id), '[]'::jsonb)
    from (select c.id, c.player, p.name, c.body, c.created_at
            from hs_chat c join hs_players p on p.id = c.player
           where c.id > coalesce(p_after, 0) and c.created_at > now() - interval '3 days'
           order by c.id desc limit 50) x $$;

grant execute on function public.hs_chat_send(uuid,text,text), public.hs_chat_since(bigint) to anon, authenticated;
