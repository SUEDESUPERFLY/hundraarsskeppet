alter table public.hs_chat add column if not exists to_player uuid references public.hs_players(id) on delete cascade;
create index if not exists hs_chat_to on public.hs_chat (to_player, id);

create or replace function public.hs_chat_since(p_after bigint) returns jsonb
language sql security definer set search_path = public as $$
select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at) order by x.id), '[]'::jsonb) from (select c.id, c.player, p.name, c.body, c.created_at from hs_chat c join hs_players p on p.id = c.player where c.to_player is null and c.id > coalesce(p_after, 0) and c.created_at > now() - interval '3 days' order by c.id desc limit 50) x $$;

create or replace function public.hs_chat_send2(p_id uuid, p_secret text, p_body text, p_to uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b text; r record; nm text;
begin
perform hs_auth(p_id, p_secret);
if p_to is not null and (p_to = p_id or not exists (select 1 from hs_players where id = p_to)) then raise exception 'to'; end if;
b := left(btrim(regexp_replace(regexp_replace(coalesce(p_body, ''), '[[:cntrl:]\u200b-\u200f\u202a-\u202e\u2066-\u2069]', ' ', 'g'), '\s+', ' ', 'g')), 200);
if b = '' then raise exception 'empty'; end if;
if (select count(*) from hs_chat where player = p_id and created_at > now() - interval '10 seconds') >= 6 then raise exception 'rate'; end if;
select name into nm from hs_players where id = p_id;
insert into hs_chat (player, body, to_player) values (p_id, b, p_to) returning id, created_at into r;
delete from hs_chat where created_at < now() - interval '3 days';
return jsonb_build_object('id', r.id, 'u', p_id, 'n', nm, 'b', b, 't', r.created_at, 'to', p_to);
end $$;

create or replace function public.hs_chat_feed(p_id uuid, p_secret text, p_after bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
perform hs_auth(p_id, p_secret);
return (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at, 'to', x.to_player) order by x.id), '[]'::jsonb) from (select c.id, c.player, p.name, c.body, c.created_at, c.to_player from hs_chat c join hs_players p on p.id = c.player where c.id > coalesce(p_after, 0) and c.created_at > now() - interval '3 days' and (c.to_player is null or c.to_player = p_id or c.player = p_id) order by c.id desc limit 100) x);
end $$;

grant execute on function public.hs_chat_send2(uuid, text, text, uuid), public.hs_chat_feed(uuid, text, bigint) to anon, authenticated;
-- slut
