create table if not exists public.hs_chat (id bigint generated always as identity primary key, player uuid not null references public.hs_players(id) on delete cascade, body text not null, created_at timestamptz not null default now());
create index if not exists hs_chat_created on public.hs_chat (created_at);
create index if not exists hs_chat_player on public.hs_chat (player, created_at);
alter table public.hs_chat enable row level security;
revoke all on table public.hs_chat from anon, authenticated;

create or replace function public.hs_chat_send(p_id uuid, p_secret text, p_body text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare b text; r record; nm text;
begin
perform hs_auth(p_id, p_secret);
b := left(btrim(regexp_replace(regexp_replace(coalesce(p_body, ''), '[[:cntrl:]\u200b-\u200f\u202a-\u202e\u2066-\u2069]', ' ', 'g'), '\s+', ' ', 'g')), 200);
if b = '' then raise exception 'empty'; end if;
if (select count(*) from hs_chat where player = p_id and created_at > now() - interval '10 seconds') >= 6 then raise exception 'rate'; end if;
select name into nm from hs_players where id = p_id;
insert into hs_chat (player, body) values (p_id, b) returning id, created_at into r;
delete from hs_chat where created_at < now() - interval '3 days';
return jsonb_build_object('id', r.id, 'u', p_id, 'n', nm, 'b', b, 't', r.created_at);
end $$;

create or replace function public.hs_chat_since(p_after bigint) returns jsonb
language sql security definer set search_path = public as $$
select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'u', x.player, 'n', x.name, 'b', x.body, 't', x.created_at) order by x.id), '[]'::jsonb) from (select c.id, c.player, p.name, c.body, c.created_at from hs_chat c join hs_players p on p.id = c.player where c.id > coalesce(p_after, 0) and c.created_at > now() - interval '3 days' order by c.id desc limit 50) x $$;

grant execute on function public.hs_chat_send(uuid, text, text), public.hs_chat_since(bigint) to anon, authenticated;
-- slut
