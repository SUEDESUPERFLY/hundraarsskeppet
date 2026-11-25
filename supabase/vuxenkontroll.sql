-- Vuxenkontroll av sociala funktioner (Google Plays Familjer-policy). Körd i Supabase 2026-11-25.
-- Varje figur har en chattnivå:
--   all     = allmänna chatten och privata meddelanden med vänner
--   friends = bara privata meddelanden med vänner
--   off     = ingen fritext alls (färdiga fraser, vinkningar och vänskap fungerar som vanligt)
-- Nivån sätts av vuxna i vuxenläget, eller på barnets enhet bakom en föräldra-PIN.
-- Fritext går alltid via databasen (realtidskanalen skickar bara "titta efter nytt"), så spärrarna här räcker.

alter table public.hs_players add column if not exists social text not null default 'all';
alter table public.hs_players drop constraint if exists hs_players_social_chk;
alter table public.hs_players add constraint hs_players_social_chk check (social in ('all', 'friends', 'off'));
alter table public.hs_players add column if not exists parent_pin text;
alter table public.hs_players add column if not exists pin_fail int not null default 0;
alter table public.hs_players add column if not exists pin_until timestamptz;

-- skicka: nivån styr vad avsändaren får skriva, och ingen kan skriva privat till någon med chatten av
create or replace function public.hs_chat_send2(p_id uuid, p_secret text, p_body text, p_to uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_b text; r record; nm text; v_soc text;
begin
perform hs_auth(p_id, p_secret);
select social into v_soc from hs_players where id = p_id;
if v_soc = 'off' then raise exception 'social_off'; end if;
if p_to is null and v_soc <> 'all' then raise exception 'social_public'; end if;
if p_to is not null then
if p_to = p_id or not exists (select 1 from hs_players where id = p_to and status = 'ok') then raise exception 'to'; end if;
if exists (select 1 from hs_block where (a = p_id and b = p_to) or (a = p_to and b = p_id)) then raise exception 'blocked_pair'; end if;
if not (exists (select 1 from hs_friend where a = p_id and b = p_to) and exists (select 1 from hs_friend where a = p_to and b = p_id)) then raise exception 'notfriend'; end if;
if (select social from hs_players where id = p_to) = 'off' then raise exception 'to_off'; end if;
end if;
v_b := public.hs_clean(p_body);
if v_b = '' then raise exception 'empty'; end if;
if (select count(*) from hs_chat where player = p_id and created_at > now() - interval '10 seconds') >= 6 then raise exception 'rate'; end if;
select name into nm from hs_players where id = p_id;
insert into hs_chat (player, body, to_player) values (p_id, v_b, p_to) returning id, created_at into r;
delete from hs_chat where created_at < now() - interval '30 days';
return jsonb_build_object('id', r.id, 'u', p_id, 'n', nm, 'b', v_b, 't', r.created_at, 'to', p_to);
end $$;

-- läsa: chatten av = inget, bara vänner = bara privata samtal
create or replace function public.hs_chat_feed(p_id uuid, p_secret text, p_after bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_soc text;
begin
perform hs_auth(p_id, p_secret);
select social into v_soc from hs_players where id = p_id;
if v_soc = 'off' then return '[]'::jsonb; end if;
return (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at, 'to', x.to_player) order by x.id), '[]'::jsonb) from (select c.id, c.player, p.name, c.body, c.created_at, c.to_player from hs_chat c join hs_players p on p.id = c.player where c.id > coalesce(p_after, 0) and c.created_at > now() - interval '30 days' and (c.to_player is null or c.to_player = p_id or c.player = p_id) and (v_soc = 'all' or c.to_player is not null) and not exists (select 1 from hs_block k where k.a = p_id and k.b = c.player) order by c.id desc limit 100) x);
end $$;

create or replace function public.hs_chat_since(p_after bigint) returns jsonb
language sql security definer set search_path = public as $$
select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at) order by x.id), '[]'::jsonb) from (select c.id, c.player, p.name, c.body, c.created_at from hs_chat c join hs_players p on p.id = c.player where hs_rt_ok() and exists (select 1 from hs_session s join hs_players q on q.id = s.player where s.auth_uid = auth.uid() and q.social = 'all') and c.to_player is null and c.id > coalesce(p_after, 0) and c.created_at > now() - interval '30 days' order by c.id desc limit 50) x $$;

-- nivån följer med när spelet laddar, frågar om status och hämtar vänner (så en ändring märks inom en minut)
create or replace function public.hs_load(p_id uuid, p_secret text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
perform hs_auth0(p_id, p_secret);
select save, pub, status, is_admin, social, parent_pin is not null as pin into r from hs_players where id = p_id;
return jsonb_build_object('save', r.save, 'pub', r.pub, 'status', r.status, 'admin', r.is_admin, 'closed', true, 'social', r.social, 'pin', r.pin);
end $$;

create or replace function public.hs_status(p_id uuid, p_secret text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
perform hs_auth0(p_id, p_secret);
select name, status, is_admin, save is not null as has_save, social, parent_pin is not null as pin into r from hs_players where id = p_id;
return jsonb_build_object('status', r.status, 'admin', r.is_admin, 'name', r.name, 'saved', r.has_save, 'closed', true, 'social', r.social, 'pin', r.pin);
end $$;

create or replace function public.hs_friends(p_id uuid, p_secret text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb;
begin
perform hs_auth(p_id, p_secret);
r := jsonb_build_object('friends', (select coalesce(jsonb_agg(f.b), '[]'::jsonb) from hs_friend f where f.a = p_id and exists (select 1 from hs_friend g where g.a = f.b and g.b = p_id)));
r := r || jsonb_build_object('out', (select coalesce(jsonb_agg(f.b), '[]'::jsonb) from hs_friend f where f.a = p_id and not exists (select 1 from hs_friend g where g.a = f.b and g.b = p_id)));
r := r || jsonb_build_object('in', (select coalesce(jsonb_agg(jsonb_build_object('id', f.a, 'n', p.name)), '[]'::jsonb) from hs_friend f join hs_players p on p.id = f.a where f.b = p_id and p.status = 'ok' and not exists (select 1 from hs_friend g where g.a = p_id and g.b = f.a) and not exists (select 1 from hs_block k where k.a = p_id and k.b = f.a)));
r := r || jsonb_build_object('blocked', (select coalesce(jsonb_agg(k.b), '[]'::jsonb) from hs_block k where k.a = p_id), 'admin', (select is_admin from hs_players where id = p_id));
r := r || (select jsonb_build_object('social', social, 'pin', parent_pin is not null) from hs_players where id = p_id);
return r;
end $$;

create or replace function public.hs_admin_overview(p_id uuid, p_secret text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb;
begin
perform hs_admin(p_id, p_secret);
r := jsonb_build_object('pending', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'n', name, 't', created_at) order by created_at), '[]'::jsonb) from hs_players where status = 'pending'));
r := r || jsonb_build_object('reports', (select coalesce(jsonb_agg(jsonb_build_object('id', r2.id, 'from', coalesce(a.name, '?'), 'target', r2.target, 'n', coalesce(b.name, '?'), 'body', r2.body, 'msg', r2.msg_id, 'reason', r2.reason, 't', r2.created_at) order by r2.id), '[]'::jsonb) from hs_report r2 left join hs_players a on a.id = r2.reporter left join hs_players b on b.id = r2.target where r2.handled_at is null));
r := r || jsonb_build_object('players', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'n', name, 'status', status, 'admin', is_admin, 'seen', seen_at, 't', created_at, 'social', social, 'pin', parent_pin is not null) order by created_at), '[]'::jsonb) from hs_players));
return r;
end $$;

-- vuxna på skeppet: sätt nivån för en spelare, och nollställ föräldra-PIN om den glömts bort
create or replace function public.hs_admin_social(p_id uuid, p_secret text, p_target uuid, p_social text, p_clear_pin boolean) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_admin(p_id, p_secret);
if p_social is not null then
  if p_social not in ('all', 'friends', 'off') then raise exception 'social'; end if;
  update hs_players set social = p_social where id = p_target;
end if;
if coalesce(p_clear_pin, false) then update hs_players set parent_pin = null, pin_fail = 0, pin_until = null where id = p_target; end if;
return 'ok';
end $$;

-- förälder på barnets enhet: första gången väljs en PIN, sedan krävs den för att ändra.
-- Fel PIN räknas (svaret är ett vanligt svar, inte ett fel, så att räknaren sparas). Fem fel = vänta 15 minuter.
create or replace function public.hs_parent_set(p_id uuid, p_secret text, p_pin text, p_social text, p_new_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
perform hs_auth0(p_id, p_secret);
select parent_pin, pin_fail, pin_until into r from hs_players where id = p_id for update;
if r.pin_until is not null and r.pin_until > now() then return jsonb_build_object('ok', false, 'err', 'pin_wait'); end if;
if r.parent_pin is null then
  if p_new_pin is null or p_new_pin = '' then return jsonb_build_object('ok', false, 'err', 'pin_new'); end if;
elsif p_pin is null or r.parent_pin <> encode(digest(p_id::text || ':' || p_pin, 'sha256'), 'hex') then
  if r.pin_fail + 1 >= 5 then
    update hs_players set pin_fail = 0, pin_until = now() + interval '15 minutes' where id = p_id;
    return jsonb_build_object('ok', false, 'err', 'pin_wait');
  end if;
  update hs_players set pin_fail = r.pin_fail + 1 where id = p_id;
  return jsonb_build_object('ok', false, 'err', 'pin', 'left', 4 - r.pin_fail);
end if;
if p_new_pin is not null and p_new_pin <> '' and p_new_pin !~ '^[0-9]{4,8}$' then return jsonb_build_object('ok', false, 'err', 'pin_format'); end if;
if p_social is not null and p_social not in ('all', 'friends', 'off') then return jsonb_build_object('ok', false, 'err', 'social'); end if;
update hs_players set pin_fail = 0, pin_until = null, social = coalesce(p_social, social),
  parent_pin = case when p_new_pin is null then parent_pin when p_new_pin = '' then null else encode(digest(p_id::text || ':' || p_new_pin, 'sha256'), 'hex') end
  where id = p_id;
return (select jsonb_build_object('ok', true, 'social', social, 'pin', parent_pin is not null) from hs_players where id = p_id);
end $$;

revoke all on function public.hs_admin_social(uuid, text, uuid, text, boolean), public.hs_parent_set(uuid, text, text, text, text) from public;
grant execute on function public.hs_admin_social(uuid, text, uuid, text, boolean), public.hs_parent_set(uuid, text, text, text, text) to anon, authenticated;
