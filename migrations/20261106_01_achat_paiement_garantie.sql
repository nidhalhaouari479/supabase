-- =============================================================================
--  Migration 2026-11-06 (1) — Achat d'un animal : virement, validation admin, garantie
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261020_01).
--
--  Aucun contact direct entre acheteur et vendeur : tout passe par Bakma.
--    1. L'acheteur vire le prix sur le compte Bakma et envoie le reçu  → paiement_a_verifier
--    2. L'admin vérifie le reçu : valide (animal « vendue »)            → garantie (8 jours)
--                                 ou refuse                              → paiement_refuse
--    3. Pendant la garantie, l'acheteur peut signaler un problème       → litige
--    4. Après la garantie (ou litige tranché), l'admin verse au vendeur → versee
--       ou rembourse l'acheteur                                         → remboursee
--
--  - purchases          : les achats (reçu dans le bucket privé vet-documents, <acheteur>/receipts/…)
--  - payout_accounts    : RIB du vendeur pour recevoir le paiement (lui-même + admin)
--  - settings.payment   : compte Bakma affiché à l'acheteur + durée de garantie (jours)
--  - start_conversation : bloque le contact direct sur les annonces « vente »
-- =============================================================================

-- 1. Types
do $$ begin
  create type public.purchase_status as enum (
    'paiement_a_verifier', 'paiement_refuse', 'annulee', 'garantie', 'litige', 'versee', 'remboursee'
  );
exception when duplicate_object then null; end $$;

-- 2. Tables
-- Achats (vente d'un animal via Bakma, paiement par virement conservé pendant la garantie)
create sequence if not exists public.purchase_ref_seq;
create table if not exists public.purchases (
  id                uuid primary key default gen_random_uuid(),
  ref               text unique not null
                    default ('ACH-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.purchase_ref_seq')::text, 5, '0')),
  animal_id         uuid not null references public.animals(id) on delete restrict,
  buyer_id          uuid not null references public.profiles(id) on delete restrict,
  seller_id         uuid not null references public.profiles(id) on delete restrict,
  amount            numeric(10,2) not null check (amount > 0),
  status            public.purchase_status not null default 'paiement_a_verifier',
  receipt_path      text not null,     -- reçu de virement (bucket privé vet-documents, <buyer_id>/receipts/…)
  receipt_name      text,
  buyer_note        text,
  hold_days         int not null default 8,   -- durée de garantie figée à la création
  verified_at       timestamptz,       -- paiement validé par l'admin (début de la garantie)
  verified_by       uuid references public.profiles(id),
  release_at        timestamptz,       -- fin de la garantie : versement possible au vendeur
  refusal_reason    text,
  dispute_reason    text,
  disputed_at       timestamptz,
  paid_out_at       timestamptz,
  paid_out_by       uuid references public.profiles(id),
  payout_reference  text,              -- référence du virement au vendeur
  refunded_at       timestamptz,
  refund_reference  text,
  admin_note        text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists purchases_status_idx on public.purchases(status);
create index if not exists purchases_buyer_idx  on public.purchases(buyer_id);
create index if not exists purchases_seller_idx on public.purchases(seller_id);
-- Un seul achat actif par animal (empêche deux paiements simultanés)
create unique index if not exists purchases_one_active_per_animal on public.purchases(animal_id)
  where status in ('paiement_a_verifier', 'garantie', 'litige', 'versee');

-- RIB du vendeur pour recevoir le paiement (visible par lui-même et les admins)
create table if not exists public.payout_accounts (
  profile_id      uuid primary key references public.profiles(id) on delete cascade,
  account_holder  text not null,
  bank_name       text,
  rib             text not null check (rib ~ '^[0-9]{20}$'),   -- RIB tunisien : 20 chiffres
  updated_at      timestamptz not null default now()
);

drop trigger if exists purchases_touch on public.purchases;
create trigger purchases_touch before update on public.purchases for each row execute function public.touch_updated_at();
drop trigger if exists payout_accounts_touch on public.payout_accounts;
create trigger payout_accounts_touch before update on public.payout_accounts for each row execute function public.touch_updated_at();

-- 3. Fonctions
-- Le propriétaire ne peut pas forcer le statut d'une annonce (sauf brouillon / adoptée / vendue),
-- ni le changer du tout pendant un achat Bakma.
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
    new.published_at := old.published_at;
    new.views_count  := old.views_count;
  end if;
  return new;
end $$;

-- Démarrer (ou retrouver) une conversation avec un autre utilisateur.
-- Ventes : aucun contact direct entre acheteur et vendeur (tout passe par Bakma).
-- Les admins et vétérinaires restent joignables / peuvent écrire.
create or replace function public.start_conversation(p_other uuid, p_animal_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if p_other = auth.uid() then raise exception 'Impossible de vous écrire à vous-même'; end if;
  if not public.is_admin() and not public.is_vet()
     and not exists (select 1 from public.profiles where id = p_other and role in ('admin', 'veterinaire')) then
    if p_animal_id is not null
       and exists (select 1 from public.animals where id = p_animal_id and listing_type = 'vente') then
      raise exception 'Les ventes passent par Bakma : pas de contact direct avec le vendeur. Utilisez le bouton « Acheter ».';
    end if;
    if exists (select 1 from public.purchases
               where (buyer_id = auth.uid() and seller_id = p_other) or (seller_id = auth.uid() and buyer_id = p_other)) then
      raise exception 'Pas de contact direct entre acheteur et vendeur : contactez le support Bakma.';
    end if;
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

-- Indicateur public : un paiement est-il en cours de vérification pour cet animal ?
create or replace function public.is_animal_reserved(p_animal_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.purchases where animal_id = p_animal_id and status = 'paiement_a_verifier')
$$;

-- Acheteur : acheter un animal en envoyant le reçu de virement
create or replace function public.create_purchase(
  p_animal_id uuid, p_receipt_path text, p_receipt_name text default null, p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_animal public.animals;
  v_hold int;
  v_id uuid;
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
  if exists (select 1 from public.purchases where animal_id = p_animal_id
             and status in ('paiement_a_verifier', 'garantie', 'litige', 'versee')) then
    raise exception 'Un autre acheteur a déjà envoyé un paiement pour cet animal';
  end if;

  select greatest(coalesce((value->>'hold_days')::int, 8), 1) into v_hold from public.settings where key = 'payment';

  insert into public.purchases (animal_id, buyer_id, seller_id, amount, receipt_path, receipt_name, buyer_note, hold_days)
  values (p_animal_id, auth.uid(), v_animal.owner_id, v_animal.price, p_receipt_path, p_receipt_name,
          nullif(trim(p_note), ''), coalesce(v_hold, 8))
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

-- Acheteur : annuler tant que le paiement n'est pas vérifié
create or replace function public.cancel_purchase(p_purchase_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.purchases;
begin
  select * into v_p from public.purchases where id = p_purchase_id for update;
  if v_p.id is null then raise exception 'Achat introuvable'; end if;
  if v_p.buyer_id <> auth.uid() and not public.is_admin() then raise exception 'Accès refusé'; end if;
  if v_p.status <> 'paiement_a_verifier' then raise exception 'Cet achat ne peut plus être annulé'; end if;
  update public.purchases set status = 'annulee' where id = p_purchase_id;
  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_annule', v_p.animal_id, auth.uid(), 'Achat annulé par l''acheteur');
end $$;

-- Admin : valider le virement → l'animal est vendu, la garantie commence
create or replace function public.verify_purchase_payment(p_purchase_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.purchases; v_name text; v_release timestamptz;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_p from public.purchases where id = p_purchase_id for update;
  if v_p.id is null then raise exception 'Achat introuvable'; end if;
  if v_p.status <> 'paiement_a_verifier' then raise exception 'Paiement déjà traité'; end if;

  v_release := now() + make_interval(days => v_p.hold_days);
  update public.purchases
     set status = 'garantie', verified_at = now(), verified_by = auth.uid(), release_at = v_release,
         admin_note = coalesce(nullif(trim(p_note), ''), admin_note)
   where id = p_purchase_id;

  perform set_config('bakma.workflow', 'on', true);
  update public.animals set status = 'vendue' where id = v_p.animal_id returning name into v_name;

  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_valide', v_p.animal_id, auth.uid(), 'Paiement validé — garantie de ' || v_p.hold_days || ' jours');
  perform public.notify(v_p.buyer_id, 'achat', 'Paiement validé ✅',
    'Votre paiement pour ' || v_name || ' est confirmé. Bakma vous contacte pour organiser la remise. '
    || 'Garantie : vous pouvez signaler un problème jusqu''au '
    || to_char(v_release at time zone 'Africa/Tunis', 'DD/MM/YYYY') || '.', '/espace/achats');
  perform public.notify(v_p.seller_id, 'achat', v_name || ' est vendu 🎉',
    'Paiement reçu par Bakma. Il vous sera versé après la garantie de ' || v_p.hold_days || ' jours (à partir du '
    || to_char(v_release at time zone 'Africa/Tunis', 'DD/MM/YYYY') || '). Pensez à renseigner votre RIB.',
    '/espace/achats?onglet=ventes');
end $$;

-- Admin : refuser le reçu (virement non reçu, montant incorrect…)
create or replace function public.reject_purchase_payment(p_purchase_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.purchases; v_name text;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Le motif est obligatoire'; end if;
  select * into v_p from public.purchases where id = p_purchase_id for update;
  if v_p.id is null then raise exception 'Achat introuvable'; end if;
  if v_p.status <> 'paiement_a_verifier' then raise exception 'Paiement déjà traité'; end if;

  update public.purchases set status = 'paiement_refuse', refusal_reason = trim(p_reason) where id = p_purchase_id;
  select name into v_name from public.animals where id = v_p.animal_id;
  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_refuse', v_p.animal_id, auth.uid(), 'Reçu de virement refusé');
  perform public.notify(v_p.buyer_id, 'achat', 'Paiement non validé', v_name || ' : ' || trim(p_reason), '/espace/achats');
  perform public.notify(v_p.seller_id, 'achat', 'Achat non abouti',
    'Le paiement pour ' || v_name || ' n''a pas été validé : votre annonce reste en ligne.', '/espace/achats?onglet=ventes');
end $$;

-- Acheteur : signaler un problème pendant la garantie (bloque le versement au vendeur)
create or replace function public.open_purchase_dispute(p_purchase_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.purchases; v_name text;
begin
  select * into v_p from public.purchases where id = p_purchase_id for update;
  if v_p.id is null then raise exception 'Achat introuvable'; end if;
  if v_p.buyer_id <> auth.uid() then raise exception 'Accès refusé'; end if;
  if v_p.status <> 'garantie' then raise exception 'Aucune garantie en cours pour cet achat'; end if;
  if now() >= v_p.release_at then raise exception 'La période de garantie est terminée'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Décrivez le problème rencontré'; end if;

  update public.purchases set status = 'litige', dispute_reason = trim(p_reason), disputed_at = now() where id = p_purchase_id;
  select name into v_name from public.animals where id = v_p.animal_id;
  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_litige', v_p.animal_id, auth.uid(), 'Problème signalé pendant la garantie');
  insert into public.notifications (user_id, type, title, body, link)
  select id, 'achat', 'Litige sur un achat', v_name || ' : ' || left(trim(p_reason), 200), '/achats/' || p_purchase_id
  from public.profiles where role = 'admin' and status = 'actif';
  perform public.notify(v_p.seller_id, 'achat', 'Versement suspendu',
    'L''acheteur de ' || v_name || ' a signalé un problème : Bakma examine la situation.', '/espace/achats?onglet=ventes');
end $$;

-- Admin : verser le paiement au vendeur (après la garantie, ou litige tranché en sa faveur)
create or replace function public.release_purchase_payout(p_purchase_id uuid, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.purchases; v_name text;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_p from public.purchases where id = p_purchase_id for update;
  if v_p.id is null then raise exception 'Achat introuvable'; end if;
  if v_p.status = 'garantie' and now() < v_p.release_at then
    raise exception 'Garantie en cours : versement possible à partir du %',
      to_char(v_p.release_at at time zone 'Africa/Tunis', 'DD/MM/YYYY à HH24:MI');
  end if;
  if v_p.status not in ('garantie', 'litige') then raise exception 'Cet achat ne peut pas être versé'; end if;

  update public.purchases
     set status = 'versee', paid_out_at = now(), paid_out_by = auth.uid(), payout_reference = nullif(trim(p_reference), '')
   where id = p_purchase_id;
  select name into v_name from public.animals where id = v_p.animal_id;
  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_verse', v_p.animal_id, auth.uid(), 'Paiement versé au vendeur');
  perform public.notify(v_p.seller_id, 'achat', 'Paiement versé 💸',
    to_char(v_p.amount, 'FM999G999D00') || ' TND pour ' || v_name || ' ont été virés sur votre compte.', '/espace/achats?onglet=ventes');
  if v_p.status = 'litige' then
    perform public.notify(v_p.buyer_id, 'achat', 'Litige clôturé',
      'Après examen, Bakma a clôturé le litige sur ' || v_name || '.', '/espace/achats');
  end if;
end $$;

-- Admin : rembourser l'acheteur (litige ou vente annulée pendant la garantie)
create or replace function public.refund_purchase(p_purchase_id uuid, p_reference text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.purchases; v_name text;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_p from public.purchases where id = p_purchase_id for update;
  if v_p.id is null then raise exception 'Achat introuvable'; end if;
  if v_p.status not in ('garantie', 'litige') then raise exception 'Cet achat ne peut pas être remboursé'; end if;

  update public.purchases
     set status = 'remboursee', refunded_at = now(), refund_reference = nullif(trim(p_reference), ''),
         admin_note = coalesce(nullif(trim(p_note), ''), admin_note)
   where id = p_purchase_id;
  select name into v_name from public.animals where id = v_p.animal_id;
  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_rembourse', v_p.animal_id, auth.uid(), 'Acheteur remboursé');
  perform public.notify(v_p.buyer_id, 'achat', 'Remboursement effectué',
    to_char(v_p.amount, 'FM999G999D00') || ' TND pour ' || v_name || ' vous ont été remboursés.', '/espace/achats');
  perform public.notify(v_p.seller_id, 'achat', 'Vente annulée',
    'La vente de ' || v_name || ' a été annulée et l''acheteur remboursé.'
    || coalesce(' Motif : ' || nullif(trim(p_note), ''), ''), '/espace/achats?onglet=ventes');
end $$;

-- Vendeur : ses ventes, sans aucune information sur l'acheteur
create or replace function public.my_sales()
returns table (
  id uuid, ref text, animal_id uuid, animal_name text, animal_cover text, amount numeric,
  status public.purchase_status, hold_days int, created_at timestamptz, verified_at timestamptz,
  release_at timestamptz, paid_out_at timestamptz, payout_reference text
) language sql stable security definer set search_path = public as $$
  select p.id, p.ref, p.animal_id, a.name, a.cover_url, p.amount, p.status, p.hold_days, p.created_at,
         p.verified_at, p.release_at, p.paid_out_at, p.payout_reference
  from public.purchases p join public.animals a on a.id = p.animal_id
  where p.seller_id = auth.uid() and p.status not in ('annulee')
  order by p.created_at desc
$$;

grant execute on function public.is_animal_reserved(uuid) to anon, authenticated;
grant execute on function public.create_purchase(uuid, text, text, text) to authenticated;
grant execute on function public.cancel_purchase(uuid) to authenticated;
grant execute on function public.verify_purchase_payment(uuid, text) to authenticated;
grant execute on function public.reject_purchase_payment(uuid, text) to authenticated;
grant execute on function public.open_purchase_dispute(uuid, text) to authenticated;
grant execute on function public.release_purchase_payout(uuid, text) to authenticated;
grant execute on function public.refund_purchase(uuid, text, text) to authenticated;
grant execute on function public.my_sales() to authenticated;

-- 4. Sécurité (RLS)
alter table public.purchases       enable row level security;
alter table public.payout_accounts enable row level security;
drop policy if exists purchases_buyer on public.purchases;
drop policy if exists purchases_admin on public.purchases;
drop policy if exists payout_own on public.payout_accounts;
drop policy if exists payout_admin on public.payout_accounts;
-- ACHATS : l'acheteur lit les siens (écritures via RPC) ; le vendeur passe par my_sales() ; l'admin voit tout
create policy purchases_buyer on public.purchases for select using (buyer_id = auth.uid());
create policy purchases_admin on public.purchases for all using (public.is_admin()) with check (public.is_admin());
-- RIB DU VENDEUR : l'intéressé et les admins
create policy payout_own on public.payout_accounts for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy payout_admin on public.payout_accounts for all using (public.is_admin()) with check (public.is_admin());

-- 5. Paramètres : compte Bakma qui reçoit les virements + durée de garantie
insert into public.settings (key, value) values
  ('payment', '{"bank_name": "", "account_holder": "Bakma Store", "rib": "", "hold_days": 8}')
on conflict (key) do nothing;
