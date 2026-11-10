-- =============================================================================
-- Boutique : codes promo (réduction en % sur les produits)
--  • code unique (majuscules), pourcentage 1–100
--  • max_uses_per_user : nombre d'utilisations par client (null = illimité)
--  • max_users         : nombre maximum de clients différents (null = illimité)
--  • starts_at / ends_at : période de validité (ends_at null = sans fin)
--  • product_ids       : produits concernés (null ou vide = tous les produits)
-- Une utilisation = une commande non annulée portant le code (une commande
-- annulée rend donc l'utilisation). La réduction ne porte pas sur la livraison.
-- =============================================================================

create table if not exists public.promo_codes (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null check (code ~ '^[A-Z0-9_-]{3,30}$'),
  description        text check (char_length(description) <= 200),
  percent            numeric(5,2) not null check (percent > 0 and percent <= 100),
  max_uses_per_user  int check (max_uses_per_user is null or max_uses_per_user > 0),
  max_users          int check (max_users is null or max_users > 0),
  starts_at          timestamptz not null default now(),
  ends_at            timestamptz,
  product_ids        uuid[],
  is_active          boolean not null default true,
  created_by         uuid references public.profiles(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint promo_codes_dates check (ends_at is null or ends_at > starts_at)
);
create unique index if not exists promo_codes_code_key on public.promo_codes (code);

drop trigger if exists promo_codes_touch on public.promo_codes;
create trigger promo_codes_touch before update on public.promo_codes for each row execute function public.touch_updated_at();

alter table public.orders add column if not exists promo_code_id uuid references public.promo_codes(id) on delete set null;
alter table public.orders add column if not exists promo_code    text;
alter table public.orders add column if not exists promo_percent numeric(5,2);
alter table public.orders add column if not exists discount      numeric(10,2) not null default 0;
create index if not exists orders_promo_idx on public.orders(promo_code_id) where promo_code_id is not null;

-- Vérifie qu'un code est utilisable par ce client (lève une exception lisible sinon).
create or replace function public.promo_assert(p public.promo_codes, p_user uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_mine int; v_users int;
begin
  if p.id is null or not p.is_active then raise exception 'Code promo invalide'; end if;
  if now() < p.starts_at then
    raise exception 'Ce code sera valable à partir du %', to_char(p.starts_at at time zone 'Africa/Tunis', 'DD/MM/YYYY');
  end if;
  if p.ends_at is not null and now() >= p.ends_at then raise exception 'Ce code promo a expiré'; end if;

  select count(*) into v_mine from public.orders
   where promo_code_id = p.id and user_id = p_user and status <> 'annulee';
  if p.max_uses_per_user is not null and v_mine >= p.max_uses_per_user then
    raise exception 'Vous avez déjà utilisé ce code (% fois maximum)', p.max_uses_per_user;
  end if;
  if p.max_users is not null and v_mine = 0 then
    select count(distinct user_id) into v_users from public.orders
     where promo_code_id = p.id and status <> 'annulee';
    if v_users >= p.max_users then raise exception 'Ce code a atteint son nombre maximum d''utilisateurs'; end if;
  end if;
end $$;
revoke all on function public.promo_assert(public.promo_codes, uuid) from public, anon, authenticated;

-- Client : vérifier un code avant de commander (aperçu de la réduction dans le panier).
create or replace function public.check_promo_code(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v public.promo_codes;
begin
  if auth.uid() is null then raise exception 'Connectez-vous pour utiliser un code promo'; end if;
  select * into v from public.promo_codes where code = upper(trim(coalesce(p_code, '')));
  perform public.promo_assert(v, auth.uid());
  return jsonb_build_object(
    'code', v.code, 'percent', v.percent, 'description', v.description, 'ends_at', v.ends_at,
    'product_ids', case when coalesce(cardinality(v.product_ids), 0) = 0 then null else to_jsonb(v.product_ids) end);
end $$;

-- Commande : nouvelle signature avec p_promo_code
drop function if exists public.place_order(jsonb, text, text, text, text, text);
create or replace function public.place_order(
  p_items jsonb, p_customer_name text, p_phone text, p_city text, p_address text, p_note text default null,
  p_promo_code text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_item jsonb;
  v_product public.products;
  v_variant public.product_variants;
  v_promo public.promo_codes;
  v_qty int;
  v_price numeric(10,2);
  v_image text;
  v_subtotal numeric(10,2) := 0;
  v_eligible numeric(10,2) := 0;
  v_discount numeric(10,2) := 0;
  v_fee numeric(10,2);
  v_free numeric(10,2);
  v_order uuid;
  v_ref text;
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[^\d+]', '', 'g');
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Votre panier est vide';
  end if;
  if jsonb_array_length(p_items) > 50 then raise exception 'Trop d''articles dans le panier'; end if;
  if length(trim(coalesce(p_customer_name, ''))) < 3 then raise exception 'Indiquez votre nom complet'; end if;
  if length(regexp_replace(v_phone, '\D', '', 'g')) < 8 then raise exception 'Numéro de téléphone invalide'; end if;
  if coalesce(trim(p_city), '') = '' then raise exception 'Choisissez votre ville'; end if;
  if length(trim(coalesce(p_address, ''))) < 5 then raise exception 'Indiquez votre adresse de livraison'; end if;

  -- code promo : verrouillé pour que deux commandes simultanées ne dépassent pas les limites
  if nullif(trim(coalesce(p_promo_code, '')), '') is not null then
    select * into v_promo from public.promo_codes where code = upper(trim(p_promo_code)) for update;
    perform public.promo_assert(v_promo, auth.uid());
  end if;

  insert into public.orders (user_id, customer_name, phone, city, address, note, subtotal, delivery_fee, total)
  values (auth.uid(), trim(p_customer_name), v_phone, trim(p_city), trim(p_address), nullif(trim(p_note), ''), 0, 0, 0)
  returning id, ref into v_order, v_ref;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := coalesce((v_item->>'quantity')::int, 0);
    if v_qty < 1 or v_qty > 99 then raise exception 'Quantité invalide'; end if;
    -- verrou de la ligne produit : deux commandes simultanées ne peuvent pas vendre le même stock
    select * into v_product from public.products where id = (v_item->>'product_id')::uuid for update;
    if v_product.id is null or not v_product.is_active then
      raise exception 'Un produit de votre panier n''est plus disponible';
    end if;

    if jsonb_array_length(v_product.options) > 0 then
      -- produit à déclinaisons : la déclinaison porte le stock (et éventuellement le prix / la photo)
      if coalesce(v_item->>'variant_id', '') = '' then
        raise exception 'Choisissez une option pour « % »', v_product.name;
      end if;
      select * into v_variant from public.product_variants
       where id = (v_item->>'variant_id')::uuid and product_id = v_product.id for update;
      if v_variant.id is null or not v_variant.is_active then
        raise exception 'Une option de « % » n''est plus disponible', v_product.name;
      end if;
      if v_variant.stock < v_qty then
        raise exception 'Stock insuffisant pour « % – % » (% disponible%)', v_product.name, v_variant.label, v_variant.stock,
          case when v_variant.stock > 1 then 's' else '' end;
      end if;
      v_price := coalesce(v_variant.price, v_product.price);
      v_image := coalesce(v_variant.image, v_product.images[1]);
      update public.product_variants set stock = stock - v_qty where id = v_variant.id;
      update public.products set sold_count = sold_count + v_qty where id = v_product.id;
      insert into public.order_items (order_id, product_id, variant_id, variant_label, product_name, image, unit_price, quantity, line_total)
      values (v_order, v_product.id, v_variant.id, v_variant.label, v_product.name, v_image, v_price, v_qty, v_price * v_qty);
    else
      if v_product.stock < v_qty then
        raise exception 'Stock insuffisant pour « % » (% disponible%)', v_product.name, v_product.stock,
          case when v_product.stock > 1 then 's' else '' end;
      end if;
      v_price := v_product.price;
      update public.products set stock = stock - v_qty, sold_count = sold_count + v_qty where id = v_product.id;
      insert into public.order_items (order_id, product_id, product_name, image, unit_price, quantity, line_total)
      values (v_order, v_product.id, v_product.name, v_product.images[1], v_price, v_qty, v_price * v_qty);
    end if;
    v_subtotal := v_subtotal + v_price * v_qty;
    if v_promo.id is not null
       and (coalesce(cardinality(v_promo.product_ids), 0) = 0 or v_product.id = any (v_promo.product_ids)) then
      v_eligible := v_eligible + v_price * v_qty;
    end if;
  end loop;

  if v_promo.id is not null then
    if v_eligible = 0 then raise exception 'Le code % ne s''applique à aucun produit de votre panier', v_promo.code; end if;
    v_discount := round(v_eligible * v_promo.percent / 100, 2);
  end if;

  -- livraison : le seuil de gratuité porte sur le sous-total avant réduction
  select greatest(coalesce((value->>'delivery_fee')::numeric, 0), 0),
         nullif((value->>'free_delivery_from')::numeric, 0)
    into v_fee, v_free
    from public.settings where key = 'shop';
  v_fee := coalesce(v_fee, 0);
  if v_free is not null and v_subtotal >= v_free then v_fee := 0; end if;

  update public.orders set
    subtotal = v_subtotal, delivery_fee = v_fee, discount = v_discount,
    total = v_subtotal - v_discount + v_fee,
    promo_code_id = v_promo.id, promo_code = v_promo.code, promo_percent = v_promo.percent
  where id = v_order;

  perform public.notify(auth.uid(), 'commande', 'Commande reçue',
    'Votre commande ' || v_ref || ' est enregistrée. Bakma vous appellera pour la confirmer.', '/espace/commandes');
  insert into public.notifications (user_id, type, title, body, link)
  select id, 'commande', 'Nouvelle commande boutique',
         v_ref || ' : ' || to_char(v_subtotal - v_discount + v_fee, 'FM999G999D00') || ' TND (' || trim(p_city) || ')'
           || coalesce(' · code ' || v_promo.code, '') || '.', '/boutique/commandes/' || v_order
  from public.profiles where role = 'admin' and status = 'actif';

  return v_order;
end $$;

-- RLS / droits : codes gérés par l'admin uniquement ; le client passe par check_promo_code / place_order
alter table public.promo_codes enable row level security;
drop policy if exists promo_codes_admin_all on public.promo_codes;
create policy promo_codes_admin_all on public.promo_codes for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.promo_codes to authenticated;

revoke execute on function public.check_promo_code(text) from public, anon;
grant execute on function public.check_promo_code(text) to authenticated;
revoke execute on function public.place_order(jsonb, text, text, text, text, text, text) from public, anon;
grant execute on function public.place_order(jsonb, text, text, text, text, text, text) to authenticated;
