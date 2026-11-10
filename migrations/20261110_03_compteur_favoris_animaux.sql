-- =============================================================================
-- Compteur de favoris par animal (affiché sur les cartes)
-- animals.favorites_count est tenu à jour par un trigger sur public.favorites
-- et ne peut pas être modifié par le propriétaire.
-- =============================================================================

alter table public.animals add column if not exists favorites_count int not null default 0;

-- Le propriétaire ne peut pas modifier les compteurs (vues, favoris)
create or replace function public.protect_animal_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin()
     and new.status is distinct from old.status
     and current_setting('bakma.workflow', true) is distinct from 'on'
     and exists (select 1 from public.purchases where animal_id = old.id
                 and status in ('paiement_a_verifier', 'garantie', 'litige', 'versee')) then
    raise exception 'Un achat est en cours pour cet animal : son statut est géré par Bakma';
  end if;
  if auth.uid() is not null and not public.is_admin()
     and new.status is distinct from old.status
     and not (old.status = 'publiee' and new.status in ('adoptee', 'vendue'))
     and not (old.status in ('adoptee', 'vendue') and new.status = 'publiee')
     and current_setting('bakma.workflow', true) is distinct from 'on' then
    new.status := old.status;
  end if;
  if auth.uid() is not null and not public.is_admin()
     and current_setting('bakma.workflow', true) is distinct from 'on' then
    new.published_at    := old.published_at;
    new.views_count     := old.views_count;
    new.favorites_count := old.favorites_count;
  end if;
  return new;
end $$;

-- Mise à jour du compteur à chaque ajout / retrait d'un favori
create or replace function public.animal_favorites_refresh()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_animal uuid := coalesce(new.animal_id, old.animal_id);
  v_prev   text := current_setting('bakma.workflow', true);
begin
  perform set_config('bakma.workflow', 'on', true);
  update public.animals
     set favorites_count = (select count(*) from public.favorites where animal_id = v_animal)
   where id = v_animal;
  perform set_config('bakma.workflow', coalesce(v_prev, ''), true);
  return null;
end $$;
drop trigger if exists favorites_refresh_count on public.favorites;
create trigger favorites_refresh_count after insert or delete on public.favorites
  for each row execute function public.animal_favorites_refresh();

-- Reprise des favoris existants
update public.animals a
   set favorites_count = (select count(*) from public.favorites f where f.animal_id = a.id)
 where favorites_count is distinct from (select count(*) from public.favorites f where f.animal_id = a.id);
