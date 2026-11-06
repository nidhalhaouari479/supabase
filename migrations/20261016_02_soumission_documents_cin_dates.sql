-- =============================================================================
--  Migration 2026-10-16 (2) — Soumission d'une annonce : documents, CIN, 3 dates
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261016_01).
--
--  - animal_documents : documents facultatifs du propriétaire sur l'animal
--  - owner_identities : n° + photo de la CIN (obligatoires pour soumettre)
--  - consultations.proposed_slots : 3 dates proposées par le propriétaire
--  - submit_animal(p_animal_id, p_slots) : exige téléphone + CIN + 3 dates futures
--  - claim_consultation : le vétérinaire accepte en choisissant une des 3 dates
-- =============================================================================

-- 1. Tables
-- Créneaux proposés par le propriétaire à la soumission (3 dates) ; le vétérinaire en choisit un pour accepter.
alter table public.consultations add column if not exists proposed_slots timestamptz[] not null default '{}';

-- Documents fournis par le propriétaire sur l'animal (carnet de santé, pedigree…), facultatifs.
-- Fichiers dans le bucket privé « vet-documents » (chemin <owner_id>/animal-docs/…).
create table if not exists public.animal_documents (
  id          uuid primary key default gen_random_uuid(),
  animal_id   uuid not null references public.animals(id) on delete cascade,
  owner_id    uuid not null references public.profiles(id) on delete cascade,
  title       text not null,
  file_path   text not null,
  file_name   text,
  created_at  timestamptz not null default now()
);
create index if not exists animal_documents_animal_idx on public.animal_documents(animal_id);

-- Pièce d'identité du propriétaire (CIN), obligatoire pour soumettre une annonce.
-- Visible uniquement par l'intéressé et les admins. Photo dans « vet-documents » (<owner_id>/cin/…).
create table if not exists public.owner_identities (
  profile_id      uuid primary key references public.profiles(id) on delete cascade,
  cin_number      text not null,
  cin_photo_path  text not null,
  updated_at      timestamptz not null default now()
);

-- 2. Fonctions
-- Documents du propriétaire visibles par : le propriétaire, les admins, le vétérinaire attribué
-- et les vétérinaires validés tant que la consultation n'est pas attribuée.
create or replace function public.can_see_animal_documents(p_animal_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or public.owns_animal(p_animal_id) or exists (
    select 1 from public.consultations c
    where c.animal_id = p_animal_id
      and (c.vet_id = auth.uid() or (c.vet_id is null and public.is_vet()))
  )
$$;

-- Propriétaire : soumettre une annonce pour vérification
-- Prérequis : téléphone + CIN (numéro et photo) renseignés, et 3 dates proposées pour la consultation.
drop function if exists public.submit_animal(uuid);
create or replace function public.submit_animal(p_animal_id uuid, p_slots timestamptz[] default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_animal public.animals;
  v_request_id uuid;
begin
  select * into v_animal from public.animals where id = p_animal_id;
  if v_animal.id is null then raise exception 'Annonce introuvable'; end if;
  if v_animal.owner_id <> auth.uid() then raise exception 'Accès refusé'; end if;
  if v_animal.status not in ('brouillon', 'refusee', 'annulee') then
    raise exception 'Cette annonce est déjà en cours de traitement';
  end if;
  -- Contrôles minimum côté serveur
  if coalesce(trim(v_animal.name), '') = '' then raise exception 'Le nom de l''animal est obligatoire'; end if;
  if v_animal.category_id is null then raise exception 'La catégorie est obligatoire'; end if;
  if v_animal.sex is null then raise exception 'Le sexe est obligatoire'; end if;
  if coalesce(trim(v_animal.city), '') = '' then raise exception 'La ville est obligatoire'; end if;
  if v_animal.listing_type = 'vente' and coalesce(v_animal.price, 0) <= 0 then
    raise exception 'Le prix de vente doit être supérieur à 0';
  end if;
  if not exists (select 1 from public.animal_photos where animal_id = p_animal_id) then
    raise exception 'Ajoutez au moins une photo';
  end if;
  -- Coordonnées du propriétaire
  if coalesce(trim((select phone from public.profile_contacts where id = v_animal.owner_id)), '') = '' then
    raise exception 'Le numéro de téléphone est obligatoire';
  end if;
  if not exists (
    select 1 from public.owner_identities
    where profile_id = v_animal.owner_id and trim(cin_number) <> '' and trim(cin_photo_path) <> ''
  ) then
    raise exception 'Le numéro et la photo de la carte d''identité (CIN) sont obligatoires';
  end if;
  -- 3 dates distinctes et futures pour la consultation vétérinaire
  if p_slots is null or cardinality(p_slots) <> 3
     or (select count(distinct x) from unnest(p_slots) x) <> 3 then
    raise exception 'Proposez 3 dates différentes pour la consultation vétérinaire';
  end if;
  if exists (select 1 from unnest(p_slots) x where x <= now()) then
    raise exception 'Les dates proposées doivent être dans le futur';
  end if;

  perform set_config('bakma.workflow', 'on', true);
  update public.animals set status = 'en_verification' where id = p_animal_id;

  insert into public.publication_requests (animal_id, owner_id, step)
  values (p_animal_id, v_animal.owner_id, 'verification_veterinaire')
  returning id into v_request_id;

  insert into public.consultations (request_id, animal_id, proposed_slots)
  values (v_request_id, p_animal_id, (select array_agg(x order by x) from unnest(p_slots) x));

  insert into public.activity_log (type, request_id, animal_id, actor_id, message)
  values ('nouvelle_demande', v_request_id, p_animal_id, auth.uid(), 'Nouvelle demande');

  -- Notifier tous les vétérinaires validés
  insert into public.notifications (user_id, type, title, body, link)
  select v.profile_id, 'demande', 'Nouvelle demande de consultation',
         'Un nouvel animal (' || v_animal.name || ') attend une vérification.', '/demandes'
  from public.veterinarians v join public.profiles p on p.id = v.profile_id
  where v.is_verified and p.status = 'actif';

  return v_request_id;
end $$;

-- Vétérinaire : prendre en charge une consultation (optionnellement avec un RDV)
create or replace function public.claim_consultation(p_consultation_id uuid, p_scheduled_at timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_c public.consultations; v_owner uuid; v_name text;
begin
  if not public.is_vet() then raise exception 'Réservé aux vétérinaires validés'; end if;
  select * into v_c from public.consultations where id = p_consultation_id for update;
  if v_c.id is null then raise exception 'Consultation introuvable'; end if;
  if v_c.vet_id is not null and v_c.vet_id <> auth.uid() then raise exception 'Déjà prise en charge par un autre vétérinaire'; end if;
  if v_c.status not in ('nouvelle', 'en_cours', 'a_revoir') then raise exception 'Consultation clôturée'; end if;
  -- Accepter = choisir une des dates proposées par le propriétaire
  if cardinality(v_c.proposed_slots) > 0 and v_c.status = 'nouvelle'
     and (p_scheduled_at is null or not (p_scheduled_at = any (v_c.proposed_slots))) then
    raise exception 'Choisissez une des 3 dates proposées par le propriétaire';
  end if;

  update public.consultations
     set vet_id = auth.uid(), status = 'en_cours', scheduled_at = coalesce(p_scheduled_at, scheduled_at)
   where id = p_consultation_id;

  select a.owner_id, a.name into v_owner, v_name from public.animals a where a.id = v_c.animal_id;
  insert into public.activity_log (type, request_id, animal_id, actor_id, message)
  values ('consultation_prise', v_c.request_id, v_c.animal_id, auth.uid(), 'Consultation prise en charge');
  perform public.notify(v_owner, 'consultation', 'Consultation planifiée',
    'Un vétérinaire a pris en charge ' || v_name ||
    case when p_scheduled_at is not null then ' — RDV le ' || to_char(p_scheduled_at at time zone 'Africa/Tunis', 'DD/MM/YYYY à HH24:MI') else '' end || '.',
    '/espace/annonces/' || v_c.animal_id);
end $$;

-- Admin : attribuer une consultation à un vétérinaire
create or replace function public.assign_vet(p_consultation_id uuid, p_vet_id uuid, p_scheduled_at timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_c public.consultations;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_c from public.consultations where id = p_consultation_id;
  if v_c.id is null then raise exception 'Consultation introuvable'; end if;
  update public.consultations set vet_id = p_vet_id, scheduled_at = coalesce(p_scheduled_at, scheduled_at),
         status = case when status = 'nouvelle' then 'nouvelle' else status end
   where id = p_consultation_id;
  perform public.notify(p_vet_id, 'demande', 'Consultation attribuée',
    'Une consultation vous a été attribuée : choisissez une des dates proposées pour l''accepter.', '/demandes/' || p_consultation_id);
end $$;

grant execute on function public.submit_animal(uuid, timestamptz[]) to authenticated;

-- 3. Sécurité (RLS)
alter table public.animal_documents enable row level security;
alter table public.owner_identities enable row level security;
drop policy if exists animal_docs_select on public.animal_documents;
drop policy if exists animal_docs_insert on public.animal_documents;
drop policy if exists animal_docs_delete on public.animal_documents;
drop policy if exists animal_docs_admin on public.animal_documents;
drop policy if exists identities_own on public.owner_identities;
drop policy if exists identities_admin on public.owner_identities;
-- DOCUMENTS DU PROPRIÉTAIRE (facultatifs, déposés à la soumission)
create policy animal_docs_select on public.animal_documents for select using (public.can_see_animal_documents(animal_id));
-- le fichier doit être dans le dossier du déposant (sinon on pourrait exposer le fichier d'un autre)
create policy animal_docs_insert on public.animal_documents for insert
  with check (owner_id = auth.uid() and public.owns_animal(animal_id) and split_part(file_path, '/', 1) = auth.uid()::text);
create policy animal_docs_delete on public.animal_documents for delete using (owner_id = auth.uid());
create policy animal_docs_admin on public.animal_documents for all using (public.is_admin()) with check (public.is_admin());

-- PIÈCE D'IDENTITÉ (CIN) : l'intéressé et les admins uniquement
create policy identities_own on public.owner_identities for all using (profile_id = auth.uid())
  with check (profile_id = auth.uid() and split_part(cin_photo_path, '/', 1) = auth.uid()::text);
create policy identities_admin on public.owner_identities for all using (public.is_admin()) with check (public.is_admin());

-- 4. Stockage : lecture des documents privés
-- Documents privés : le déposant (dont sa CIN), les admins, le propriétaire de l'animal (rapports véto)
-- et les vétérinaires concernés (documents fournis par le propriétaire).
drop policy if exists "bakma vet documents read" on storage.objects;
create policy "bakma vet documents read" on storage.objects for select to authenticated
  using (
    bucket_id = 'vet-documents' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.is_admin()
      or exists (
        select 1 from public.consultation_documents d
        join public.consultations c on c.id = d.consultation_id
        join public.animals a on a.id = c.animal_id
        where d.file_path = storage.objects.name and a.owner_id = auth.uid()
      )
      or exists (
        select 1 from public.animal_documents ad
        where ad.file_path = storage.objects.name and public.can_see_animal_documents(ad.animal_id)
      )
    )
  );
