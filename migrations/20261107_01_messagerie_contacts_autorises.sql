-- =============================================================================
--  Migration 2026-11-07 (1) — Messagerie : contacts autorisés
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261106_01).
--
--  Un client (particulier) ne peut plus écrire à un autre client. Il peut écrire :
--    - à tous les administrateurs ;
--    - aux vétérinaires attribués (consultations.vet_id) à un animal qu'il a publié.
--  Les administrateurs peuvent écrire à tout le monde ; les vétérinaires aux
--  administrateurs, aux autres vétérinaires et aux propriétaires de leurs animaux.
--
--  - can_contact(p_other)   : règle unique, utilisée par start_conversation ET messages_insert
--                             (les anciennes conversations client ↔ client passent en lecture seule)
--  - start_conversation     : applique can_contact
--  - list_contacts()        : personnes que l'utilisateur connecté peut contacter (page Messages)
--  - conversations_insert   : supprimée, la création passe uniquement par start_conversation
-- =============================================================================

-- 1. Règle de contact
create or replace function public.can_contact(p_other uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with me as (select role from public.profiles where id = auth.uid() and status = 'actif'),
       other as (select role from public.profiles where id = p_other and status = 'actif')
  select auth.uid() is not null and p_other is not null and p_other <> auth.uid()
     and exists (select 1 from me) and exists (select 1 from other)
     and (
       -- Administrateur : écrit à tout le monde / joignable par tout le monde
       (select role from me) = 'admin'
       or (select role from other) = 'admin'
       -- Vétérinaires entre eux
       or ((select role from me) = 'veterinaire' and (select role from other) = 'veterinaire')
       -- Vétérinaire ↔ propriétaire d'un animal qui lui est attribué
       or exists (
         select 1 from public.consultations c join public.animals a on a.id = c.animal_id
         where (c.vet_id = auth.uid() and a.owner_id = p_other)
            or (c.vet_id = p_other and a.owner_id = auth.uid())
       )
     )
$$;

-- 2. Démarrer (ou retrouver) une conversation
create or replace function public.start_conversation(p_other uuid, p_animal_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if p_other = auth.uid() then raise exception 'Impossible de vous écrire à vous-même'; end if;
  if not public.can_contact(p_other) then
    raise exception 'Vous pouvez uniquement contacter l''équipe Bakma et les vétérinaires qui suivent vos animaux.';
  end if;
  select id into v_id from public.conversations
   where least(participant_a, participant_b) = least(auth.uid(), p_other)
     and greatest(participant_a, participant_b) = greatest(auth.uid(), p_other)
     and coalesce(animal_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_animal_id, '00000000-0000-0000-0000-000000000000'::uuid);
  if v_id is null then
    insert into public.conversations (animal_id, participant_a, participant_b)
    values (p_animal_id, auth.uid(), p_other) returning id into v_id;
  end if;
  return v_id;
end $$;

-- 3. Liste des contacts possibles (admins + vétérinaires de mes animaux, ou propriétaires pour un vétérinaire)
create or replace function public.list_contacts()
returns table (id uuid, full_name text, avatar_url text, role public.user_role, animal_id uuid, animal_name text)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, p.avatar_url, p.role, null::uuid, null::text
    from public.profiles p
   where p.role = 'admin' and p.status = 'actif' and p.id <> auth.uid()
  union all
  select distinct on (p.id, a.id) p.id, p.full_name, p.avatar_url, p.role, a.id, a.name
    from public.consultations c
    join public.animals a on a.id = c.animal_id
    join public.profiles p on p.id = case when a.owner_id = auth.uid() then c.vet_id else a.owner_id end
   where (a.owner_id = auth.uid() or c.vet_id = auth.uid())
     and c.vet_id is not null and p.id <> auth.uid() and p.status = 'actif'
$$;

grant execute on function public.can_contact(uuid) to authenticated;
grant execute on function public.list_contacts() to authenticated;

-- 4. Policies
drop policy if exists conversations_insert on public.conversations;

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert with check (
  sender_id = auth.uid() and exists (
    select 1 from public.conversations c
    where c.id = conversation_id and auth.uid() in (c.participant_a, c.participant_b)
      and public.can_contact(case when c.participant_a = auth.uid() then c.participant_b else c.participant_a end))
);
