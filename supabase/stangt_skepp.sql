-- Hundraårsskeppet: stängt skepp. Vuxna släpper in nya spelare, privat bara mellan vänner, blockera, rapportera, filter, vuxenläge.
alter table public.hs_players add column if not exists status text not null default 'ok';
alter table public.hs_players alter column status set default 'pending';
alter table public.hs_players add column if not exists is_admin boolean not null default false;
update public.hs_players set is_admin = true where id = 'f62522f5-9d6d-4f57-89c2-7ad47b33846c';

create table if not exists public.hs_session (auth_uid uuid primary key, player uuid not null references public.hs_players(id) on delete cascade, created_at timestamptz not null default now());
create table if not exists public.hs_friend (a uuid not null references public.hs_players(id) on delete cascade, b uuid not null references public.hs_players(id) on delete cascade, created_at timestamptz not null default now(), primary key (a, b));
create table if not exists public.hs_block (a uuid not null references public.hs_players(id) on delete cascade, b uuid not null references public.hs_players(id) on delete cascade, created_at timestamptz not null default now(), primary key (a, b));
create table if not exists public.hs_report (id bigint generated always as identity primary key, reporter uuid not null references public.hs_players(id) on delete cascade, target uuid references public.hs_players(id) on delete set null, msg_id bigint, body text, reason text, created_at timestamptz not null default now(), handled_at timestamptz, handled_by uuid, outcome text);
alter table public.hs_session enable row level security;
alter table public.hs_friend enable row level security;
alter table public.hs_block enable row level security;
alter table public.hs_report enable row level security;
revoke all on table public.hs_session, public.hs_friend, public.hs_block, public.hs_report from anon, authenticated;

-- who is this device (anonymous sign-in) playing as, and may it see the ship
create or replace function public.hs_bind(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin
if auth.uid() is not null then insert into hs_session (auth_uid, player) values (auth.uid(), p_id) on conflict (auth_uid) do update set player = excluded.player where hs_session.player is distinct from excluded.player; end if;
end $$;
create or replace function public.hs_rt_ok() returns boolean language sql stable security definer set search_path = public as $$
select exists (select 1 from hs_session s join hs_players p on p.id = s.player where s.auth_uid = auth.uid() and p.status = 'ok') $$;

-- hs_auth0: right secret; hs_auth: right secret and let in (every game function uses hs_auth)
create or replace function public.hs_auth0(p_id uuid, p_secret text) returns void language plpgsql security definer set search_path = public, extensions as $$
begin
if p_secret is null or not exists (select 1 from hs_players where id = p_id and secret_hash = encode(digest(p_secret, 'sha256'), 'hex')) then raise exception 'auth'; end if;
perform hs_bind(p_id);
end $$;
create or replace function public.hs_auth(p_id uuid, p_secret text) returns void language plpgsql security definer set search_path = public, extensions as $$
declare st text;
begin
perform hs_auth0(p_id, p_secret);
select status into st from hs_players where id = p_id;
if st is distinct from 'ok' then raise exception '%', coalesce(st, 'auth'); end if;
end $$;
create or replace function public.hs_admin(p_id uuid, p_secret text) returns void language plpgsql security definer set search_path = public as $$
begin
perform hs_auth(p_id, p_secret);
if not exists (select 1 from hs_players where id = p_id and is_admin) then raise exception 'admin'; end if;
end $$;

-- links, e-mail, phone numbers and other apps are removed; rude words become stars
create or replace function public.hs_filter(t text) returns text language plpgsql immutable set search_path = '' as $$
declare b text := coalesce(t, '');
begin
b := regexp_replace(b, '(https?://|www\.)\S+', '[länk borttagen]', 'gi');
b := regexp_replace(b, '\S+@\S+\.[a-z]{2,}', '[adress borttagen]', 'gi');
b := regexp_replace(b, '[a-z0-9-]+\.(com|se|nu|net|org|io|gg|me|app|tv|ly|link|xyz|co)([^a-zåäö]|$)\S*', '[länk borttagen] ', 'gi');
b := regexp_replace(b, '\+?[0-9][0-9 .-]{5,}[0-9]', '[nummer borttaget]', 'g');
b := regexp_replace(b, '(^|[^a-zåäö])(snap|snapchat|insta|instagram|ig|tiktok|tik tok|discord|whatsapp|whats app|kik|telegram|messenger|skype|wickr)([^a-zåäö].*|$)', '\1[kontaktuppgift borttagen]', 'gi');
b := regexp_replace(b, '(^|[^a-zåäö])(jävl|fitt|kuk|knull|neger|negr|efterbliv|mongo|luder|slampa|bög|idiot|äckel|tjockis|blatte|svartskall|hora|horun|cpunge|cp-skad|fetto|fettsvin|retard)[a-zåäö]*', '\1✱✱✱', 'gi');
b := regexp_replace(b, '(^|[^a-zåäö])(cp|fan|helvete|skit)([^a-zåäö]|$)', '\1✱✱✱\3', 'gi');
return b;
end $$;
create or replace function public.hs_clean(t text) returns text language sql immutable set search_path = '' as $$
select left(btrim(regexp_replace(regexp_replace(public.hs_filter(coalesce(t, '')), '[[:cntrl:]\u200b-\u200f\u202a-\u202e\u2066-\u2069]', ' ', 'g'), '\s+', ' ', 'g')), 200) $$;

-- boarding: new players wait until an adult lets them in
create or replace function public.hs_register(p_id uuid, p_secret text, p_name text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_home text; v_st text; v_nm text := left(public.hs_clean(p_name), 18);
begin
if p_secret is null or length(p_secret) < 16 then raise exception 'secret'; end if;
if exists (select 1 from hs_players where id = p_id) then
perform hs_auth0(p_id, p_secret);
select pub->>'home', status into v_home, v_st from hs_players where id = p_id;
return jsonb_build_object('ok', true, 'home', v_home, 'existing', true, 'status', v_st, 'closed', true);
end if;
if (select count(*) from hs_players where status = 'pending' and created_at > now() - interval '1 hour') >= 20 then raise exception 'busy'; end if;
if v_nm = '' then v_nm := 'Ny spelare'; end if;
select c into v_home from unnest(array['hytt15','hytt16','hytt17','hytt18','hytt19','hytt20','hytt21','hytt22']) with ordinality as t(c, o) order by (select count(*) from hs_players where pub->>'home' = c and status <> 'blocked'), o limit 1;
insert into hs_players (id, secret_hash, name, pub, status) values (p_id, encode(digest(p_secret, 'sha256'), 'hex'), v_nm, jsonb_build_object('home', v_home, 'name', v_nm), 'pending');
perform hs_bind(p_id);
return jsonb_build_object('ok', true, 'home', v_home, 'existing', false, 'status', 'pending', 'closed', true);
end $$;
create or replace function public.hs_status(p_id uuid, p_secret text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
perform hs_auth0(p_id, p_secret);
select name, status, is_admin, save is not null as has_save into r from hs_players where id = p_id;
return jsonb_build_object('status', r.status, 'admin', r.is_admin, 'name', r.name, 'saved', r.has_save, 'closed', true);
end $$;
create or replace function public.hs_load(p_id uuid, p_secret text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
perform hs_auth0(p_id, p_secret);
select save, pub, status, is_admin into r from hs_players where id = p_id;
return jsonb_build_object('save', r.save, 'pub', r.pub, 'status', r.status, 'admin', r.is_admin, 'closed', true);
end $$;
create or replace function public.hs_save(p_id uuid, p_secret text, p_save jsonb, p_pub jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_home text; v_nm text;
begin
perform hs_auth0(p_id, p_secret);
if pg_column_size(p_save) > 300000 or pg_column_size(p_pub) > 12000 then raise exception 'size'; end if;
select pub->>'home', name into v_home, v_nm from hs_players where id = p_id;
update hs_players set save = p_save, pub = jsonb_set(jsonb_set(coalesce(p_pub, '{}'::jsonb), '{home}', to_jsonb(v_home)), '{name}', to_jsonb(v_nm)), seen_at = now() where id = p_id;
return jsonb_build_object('ok', true, 'now', hs_now());
end $$;

-- what strangers and waiting players can see: nothing
create or replace function public.hs_players_list() returns jsonb language sql security definer set search_path = public as $$
select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'pub', pub, 'seen', extract(epoch from seen_at) * 1000) order by created_at), '[]'::jsonb) from hs_players where save is not null and status = 'ok' and hs_rt_ok() $$;
create or replace function public.hs_ship_get() returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
if not hs_rt_ok() then return jsonb_build_object('state', '{}'::jsonb, 'version', 0, 'now', hs_now(), 'gt', hs_gt(), 'sum', '{}'::jsonb, 'givers', '{}'::jsonb, 'votes', '{}'::jsonb, 'closed', true); end if;
r := jsonb_build_object('state', (select state from hs_ship where id = 1), 'version', (select version from hs_ship where id = 1), 'now', hs_now(), 'gt', hs_gt());
r := r || jsonb_build_object('sum', (select coalesce(jsonb_object_agg(project, s), '{}'::jsonb) from (select project, sum(amount) + sum(work) * 0.8 as s from hs_donations group by project) x));
r := r || jsonb_build_object('givers', (select coalesce(jsonb_object_agg(project, g), '{}'::jsonb) from (select project, jsonb_agg(jsonb_build_object('id', player, 'name', name, 'amount', a, 'work', w) order by a + w * 0.8 desc) as g from (select d.project, d.player, p.name, sum(d.amount) as a, sum(d.work) as w from hs_donations d join hs_players p on p.id = d.player group by d.project, d.player, p.name) y group by project) x));
r := r || jsonb_build_object('votes', (select coalesce(jsonb_object_agg(project, c), '{}'::jsonb) from (select v.project, count(*) as c from hs_votes v, hs_ship s where s.id = 1 and v.round = coalesce((s.state->>'round')::int, 0) group by v.project) z));
return r;
end $$;

-- chat: filtered, 30 days, private only between friends, nothing from people you blocked
create or replace function public.hs_chat_send2(p_id uuid, p_secret text, p_body text, p_to uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_b text; r record; nm text;
begin
perform hs_auth(p_id, p_secret);
if p_to is not null then
if p_to = p_id or not exists (select 1 from hs_players where id = p_to and status = 'ok') then raise exception 'to'; end if;
if exists (select 1 from hs_block where (a = p_id and b = p_to) or (a = p_to and b = p_id)) then raise exception 'blocked_pair'; end if;
if not (exists (select 1 from hs_friend where a = p_id and b = p_to) and exists (select 1 from hs_friend where a = p_to and b = p_id)) then raise exception 'notfriend'; end if;
end if;
v_b := public.hs_clean(p_body);
if v_b = '' then raise exception 'empty'; end if;
if (select count(*) from hs_chat where player = p_id and created_at > now() - interval '10 seconds') >= 6 then raise exception 'rate'; end if;
select name into nm from hs_players where id = p_id;
insert into hs_chat (player, body, to_player) values (p_id, v_b, p_to) returning id, created_at into r;
delete from hs_chat where created_at < now() - interval '30 days';
return jsonb_build_object('id', r.id, 'u', p_id, 'n', nm, 'b', v_b, 't', r.created_at, 'to', p_to);
end $$;
create or replace function public.hs_chat_send(p_id uuid, p_secret text, p_body text) returns jsonb language sql security definer set search_path = public as $$
select public.hs_chat_send2(p_id, p_secret, p_body, null) $$;
create or replace function public.hs_chat_feed(p_id uuid, p_secret text, p_after bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_auth(p_id, p_secret);
return (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at, 'to', x.to_player) order by x.id), '[]'::jsonb) from (select c.id, c.player, p.name, c.body, c.created_at, c.to_player from hs_chat c join hs_players p on p.id = c.player where c.id > coalesce(p_after, 0) and c.created_at > now() - interval '30 days' and (c.to_player is null or c.to_player = p_id or c.player = p_id) and not exists (select 1 from hs_block k where k.a = p_id and k.b = c.player) order by c.id desc limit 100) x);
end $$;
create or replace function public.hs_chat_since(p_after bigint) returns jsonb language sql security definer set search_path = public as $$
select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at) order by x.id), '[]'::jsonb) from (select c.id, c.player, p.name, c.body, c.created_at from hs_chat c join hs_players p on p.id = c.player where hs_rt_ok() and c.to_player is null and c.id > coalesce(p_after, 0) and c.created_at > now() - interval '30 days' order by c.id desc limit 50) x $$;

-- friends: both have to say yes; blocking ends the friendship and stops private messages
create or replace function public.hs_friends(p_id uuid, p_secret text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb;
begin
perform hs_auth(p_id, p_secret);
r := jsonb_build_object('friends', (select coalesce(jsonb_agg(f.b), '[]'::jsonb) from hs_friend f where f.a = p_id and exists (select 1 from hs_friend g where g.a = f.b and g.b = p_id)));
r := r || jsonb_build_object('out', (select coalesce(jsonb_agg(f.b), '[]'::jsonb) from hs_friend f where f.a = p_id and not exists (select 1 from hs_friend g where g.a = f.b and g.b = p_id)));
r := r || jsonb_build_object('in', (select coalesce(jsonb_agg(jsonb_build_object('id', f.a, 'n', p.name)), '[]'::jsonb) from hs_friend f join hs_players p on p.id = f.a where f.b = p_id and p.status = 'ok' and not exists (select 1 from hs_friend g where g.a = p_id and g.b = f.a) and not exists (select 1 from hs_block k where k.a = p_id and k.b = f.a)));
r := r || jsonb_build_object('blocked', (select coalesce(jsonb_agg(k.b), '[]'::jsonb) from hs_block k where k.a = p_id), 'admin', (select is_admin from hs_players where id = p_id));
return r;
end $$;
create or replace function public.hs_friend_set(p_id uuid, p_secret text, p_to uuid, p_on boolean) returns text language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_auth(p_id, p_secret);
if not p_on then delete from hs_friend where (a = p_id and b = p_to) or (a = p_to and b = p_id); return 'none'; end if;
if p_to = p_id or not exists (select 1 from hs_players where id = p_to and status = 'ok') then raise exception 'to'; end if;
if exists (select 1 from hs_block where (a = p_id and b = p_to) or (a = p_to and b = p_id)) then raise exception 'blocked_pair'; end if;
if (select count(*) from hs_friend where a = p_id and created_at > now() - interval '1 hour') >= 20 then raise exception 'rate'; end if;
insert into hs_friend (a, b) values (p_id, p_to) on conflict do nothing;
return case when exists (select 1 from hs_friend where a = p_to and b = p_id) then 'friends' else 'requested' end;
end $$;
create or replace function public.hs_block_set(p_id uuid, p_secret text, p_to uuid, p_on boolean) returns text language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_auth(p_id, p_secret);
if p_to = p_id then raise exception 'to'; end if;
if p_on then insert into hs_block (a, b) values (p_id, p_to) on conflict do nothing; delete from hs_friend where (a = p_id and b = p_to) or (a = p_to and b = p_id); return 'blocked'; end if;
delete from hs_block where a = p_id and b = p_to; return 'none';
end $$;

-- reports: kept until an adult has looked, and the reporter hears back
create or replace function public.hs_report_add(p_id uuid, p_secret text, p_target uuid, p_msg bigint, p_reason text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_b text;
begin
perform hs_auth(p_id, p_secret);
if (select count(*) from hs_report where reporter = p_id and created_at > now() - interval '1 hour') >= 15 then raise exception 'rate'; end if;
if p_msg is not null then select body into v_b from hs_chat where id = p_msg and player = p_target and (to_player is null or to_player = p_id); end if;
insert into hs_report (reporter, target, msg_id, body, reason) values (p_id, p_target, p_msg, v_b, left(coalesce(p_reason, ''), 120));
return 'ok';
end $$;
create or replace function public.hs_my_reports(p_id uuid, p_secret text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_auth(p_id, p_secret);
return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'n', coalesce(p.name, '?'), 'outcome', r.outcome, 'done', r.handled_at) order by r.id), '[]'::jsonb) from hs_report r left join hs_players p on p.id = r.target where r.reporter = p_id and r.handled_at > now() - interval '14 days');
end $$;

-- verktyg för vuxna
create or replace function public.hs_admin_overview(p_id uuid, p_secret text) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb;
begin
perform hs_admin(p_id, p_secret);
r := jsonb_build_object('pending', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'n', name, 't', created_at) order by created_at), '[]'::jsonb) from hs_players where status = 'pending'));
r := r || jsonb_build_object('reports', (select coalesce(jsonb_agg(jsonb_build_object('id', r2.id, 'from', coalesce(a.name, '?'), 'target', r2.target, 'n', coalesce(b.name, '?'), 'body', r2.body, 'msg', r2.msg_id, 'reason', r2.reason, 't', r2.created_at) order by r2.id), '[]'::jsonb) from hs_report r2 left join hs_players a on a.id = r2.reporter left join hs_players b on b.id = r2.target where r2.handled_at is null));
r := r || jsonb_build_object('players', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'n', name, 'status', status, 'admin', is_admin, 'seen', seen_at, 't', created_at) order by created_at), '[]'::jsonb) from hs_players));
return r;
end $$;
create or replace function public.hs_admin_player(p_id uuid, p_secret text, p_target uuid, p_status text, p_admin boolean, p_name text) returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_nm text;
begin
perform hs_admin(p_id, p_secret);
if p_target = p_id and (p_status is not null or p_admin is not null) then raise exception 'self'; end if;
if p_status is not null then if p_status not in ('ok', 'blocked', 'pending') then raise exception 'status'; end if; update hs_players set status = p_status where id = p_target; end if;
if p_admin is not null then update hs_players set is_admin = p_admin where id = p_target; end if;
if p_name is not null then v_nm := left(public.hs_clean(p_name), 18); if v_nm = '' then raise exception 'name'; end if; update hs_players set name = v_nm, pub = jsonb_set(pub, '{name}', to_jsonb(v_nm)) where id = p_target; end if;
return 'ok';
end $$;
create or replace function public.hs_admin_report(p_id uuid, p_secret text, p_report bigint, p_outcome text) returns text language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_admin(p_id, p_secret);
update hs_report set handled_at = now(), handled_by = p_id, outcome = left(coalesce(p_outcome, ''), 200) where id = p_report;
return 'ok';
end $$;
create or replace function public.hs_admin_chatlog(p_id uuid, p_secret text, p_before bigint) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_admin(p_id, p_secret);
return (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.fn, 'to', x.to_player, 'tn', x.tn, 'b', x.body, 't', x.created_at) order by x.id), '[]'::jsonb) from (select c.id, c.player, a.name as fn, c.to_player, b.name as tn, c.body, c.created_at from hs_chat c join hs_players a on a.id = c.player left join hs_players b on b.id = c.to_player where p_before is null or c.id < p_before order by c.id desc limit 200) x);
end $$;
create or replace function public.hs_admin_delete_msg(p_id uuid, p_secret text, p_msg bigint) returns text language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_admin(p_id, p_secret);
delete from hs_chat where id = p_msg;
return 'ok';
end $$;

-- the live channel: only devices playing as a let-in player can join, listen or send
drop policy if exists hs_rt_read on realtime.messages;
drop policy if exists hs_rt_write on realtime.messages;
create policy hs_rt_read on realtime.messages for select to authenticated using ((select realtime.topic()) = 'hs-ship-p' and (select public.hs_rt_ok()));
create policy hs_rt_write on realtime.messages for insert to authenticated with check ((select realtime.topic()) = 'hs-ship-p' and (select public.hs_rt_ok()));

revoke all on function public.hs_bind(uuid), public.hs_auth0(uuid, text), public.hs_auth(uuid, text), public.hs_admin(uuid, text) from public, anon, authenticated;
grant execute on function public.hs_rt_ok() to authenticated;
grant execute on function public.hs_status(uuid, text), public.hs_friends(uuid, text), public.hs_friend_set(uuid, text, uuid, boolean), public.hs_block_set(uuid, text, uuid, boolean), public.hs_report_add(uuid, text, uuid, bigint, text), public.hs_my_reports(uuid, text) to anon, authenticated;
grant execute on function public.hs_admin_overview(uuid, text), public.hs_admin_player(uuid, text, uuid, text, boolean, text), public.hs_admin_report(uuid, text, bigint, text), public.hs_admin_chatlog(uuid, text, bigint), public.hs_admin_delete_msg(uuid, text, bigint) to anon, authenticated;
-- slut
