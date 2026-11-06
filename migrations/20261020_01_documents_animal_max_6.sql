-- =============================================================================
--  Migration 2026-10-20 (1) — Documents de l'animal : 6 fichiers maximum
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261016_02).
--
--  Les documents (facultatifs) se déposent désormais dans le formulaire d'annonce,
--  étape « Documents ». Limite côté serveur : 6 documents par animal.
-- =============================================================================

do $$
begin
  if to_regclass('public.animal_documents') is null then
    raise exception 'Table animal_documents absente : exécutez d''abord la migration 20261016_02_soumission_documents_cin_dates.sql';
  end if;
end $$;

create or replace function public.check_animal_documents_limit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- verrou sur l'annonce : deux dépôts simultanés ne peuvent pas dépasser la limite
  perform 1 from public.animals where id = new.animal_id for update;
  if (select count(*) from public.animal_documents where animal_id = new.animal_id) >= 6 then
    raise exception 'Vous pouvez joindre 6 documents maximum par annonce';
  end if;
  return new;
end $$;
drop trigger if exists animal_documents_limit on public.animal_documents;
create trigger animal_documents_limit before insert on public.animal_documents
  for each row execute function public.check_animal_documents_limit();
