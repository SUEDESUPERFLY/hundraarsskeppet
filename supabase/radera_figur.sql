-- Radera min figur (Google Plays krav på att konton ska kunna raderas). Körd i Supabase 2026-11-25.
-- Allt som hör till figuren försvinner via ON DELETE CASCADE; gåvor stannar i de gemensamma projekten men utan namn.
alter table public.hs_donations alter column player drop not null;
alter table public.hs_donations drop constraint if exists hs_donations_player_fkey;
alter table public.hs_donations add constraint hs_donations_player_fkey foreign key (player) references public.hs_players(id) on delete set null;

create or replace function public.hs_delete_me(p_id uuid, p_secret text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform hs_auth0(p_id, p_secret);   -- rätt hemlighet räcker: även en väntande eller avstängd figur får raderas
  delete from hs_players where id = p_id;
end $$;
revoke all on function public.hs_delete_me(uuid, text) from public;
grant execute on function public.hs_delete_me(uuid, text) to anon, authenticated;
