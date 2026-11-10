-- =============================================================================
--  Migration 2026-11-07 (2) — Achat : titulaire et numéro du compte émetteur
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261107_01).
--
--  Avec le reçu, l'acheteur saisit obligatoirement le nom du titulaire du compte
--  qui a fait le virement et le numéro de ce compte (RIB). L'admin s'en sert pour
--  rapprocher le virement reçu et, si besoin, rembourser.
--
--  - purchases.payer_name / payer_account : nouvelles colonnes
--  - create_purchase                      : 2 paramètres obligatoires en plus
-- =============================================================================

-- 1. Colonnes
alter table public.purchases add column if not exists payer_name    text;
alter table public.purchases add column if not exists payer_account text;

-- 2. create_purchase : l'ancienne signature (4 paramètres) est remplacée
drop function if exists public.create_purchase(uuid, text, text, text);

create or replace function public.create_purchase(
  p_animal_id uuid, p_receipt_path text, p_payer_name text, p_payer_account text,
  p_receipt_name text default null, p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_animal public.animals;
  v_hold int;
  v_id uuid;
  v_account text := regexp_replace(coalesce(p_payer_account, ''), '\D', '', 'g');
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  select * into v_animal from public.animals where id = p_animal_id for update;
  if v_animal.id is null then raise exception 'Annonce introuvable'; end if;
  if v_animal.listing_type <> 'vente' or coalesce(v_animal.price, 0) <= 0 then
    raise exception 'Cet animal n''est pas à vendre';
  end if;
  if v_animal.status <> 'publiee' then raise exception 'Cet animal n''est plus disponible'; end if;
  if v_animal.owner_id = auth.uid() then raise exception 'Vous ne pouvez pas acheter votre propre animal'; end if;
  if coalesce(trim(p_receipt_path), '') = '' or split_part(p_receipt_path, '/', 1) <> auth.uid()::text then
    raise exception 'Le reçu de virement est obligatoire';
  end if;
  if length(trim(coalesce(p_payer_name, ''))) < 3 then
    raise exception 'Indiquez le nom du titulaire du compte qui a fait le virement';
  end if;
  if length(v_account) not between 8 and 24 then
    raise exception 'Le numéro de compte (RIB) doit contenir entre 8 et 24 chiffres';
  end if;
  if exists (select 1 from public.purchases where animal_id = p_animal_id
             and status in ('paiement_a_verifier', 'garantie', 'litige', 'versee')) then
    raise exception 'Un autre acheteur a déjà envoyé un paiement pour cet animal';
  end if;

  select greatest(coalesce((value->>'hold_days')::int, 8), 1) into v_hold from public.settings where key = 'payment';

  insert into public.purchases (animal_id, buyer_id, seller_id, amount, receipt_path, receipt_name, buyer_note, hold_days, payer_name, payer_account)
  values (p_animal_id, auth.uid(), v_animal.owner_id, v_animal.price, p_receipt_path, p_receipt_name,
          nullif(trim(p_note), ''), coalesce(v_hold, 8), trim(p_payer_name), v_account)
  returning id into v_id;

  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_recu', p_animal_id, auth.uid(), 'Reçu de virement envoyé');

  perform public.notify(v_animal.owner_id, 'achat', 'Demande d''achat reçue',
    'Un acheteur a payé ' || v_animal.name || ' : Bakma vérifie le virement.', '/espace/achats?onglet=ventes');
  insert into public.notifications (user_id, type, title, body, link)
  select id, 'achat', 'Reçu de virement à vérifier',
         v_animal.name || ' : ' || to_char(v_animal.price, 'FM999G999D00') || ' TND.', '/achats/' || v_id
  from public.profiles where role = 'admin' and status = 'actif';

  return v_id;
end $$;

grant execute on function public.create_purchase(uuid, text, text, text, text, text) to authenticated;
