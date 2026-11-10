-- =============================================================================
--  Migration 2026-11-07 (3) — Boutique en ligne (produits pour animaux)
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261107_02).
--
--  Bakma est le seul vendeur. Paiement à la livraison (espèces au livreur).
--  Frais de livraison réglés par l'admin : settings.shop
--    { "delivery_fee": 7, "free_delivery_from": null }   (null / 0 = jamais offerte)
--
--  - shop_categories / products : catalogue géré par l'admin
--  - orders / order_items       : commandes (prix et noms figés à la commande)
--  - place_order()              : crée la commande, recalcule prix + livraison côté serveur,
--                                 réserve le stock (décrément) de façon atomique
--  - cancel_order()             : le client annule tant que la commande est « nouvelle »
--  - set_order_status()         : l'admin fait avancer la commande (stock rendu si annulée)
--  - bucket public shop-images  : photos des produits
-- =============================================================================

-- 1. Types
do $$ begin
  create type public.order_status as enum ('nouvelle', 'confirmee', 'expediee', 'livree', 'annulee');
exception when duplicate_object then null; end $$;

-- 2. Tables
create table if not exists public.shop_categories (
  id          serial primary key,
  slug        text unique not null,
  name        text not null,
  icon        text,                      -- clé d'icône (même jeu que les catégories d'animaux)
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.products (
  id                uuid primary key default gen_random_uuid(),
  category_id       int references public.shop_categories(id) on delete set null,
  name              text not null,
  brand             text,
  short_description text,
  description       text,
  price             numeric(10,2) not null check (price > 0),
  compare_at_price  numeric(10,2) check (compare_at_price is null or compare_at_price > 0),  -- ancien prix (barré)
  stock             int not null default 0 check (stock >= 0),
  images            text[] not null default '{}',   -- URLs publiques (bucket shop-images), la 1re = couverture
  is_active         boolean not null default true,  -- visible sur le site
  is_featured       boolean not null default false, -- mis en avant
  sold_count        int not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists products_category_idx on public.products(category_id);
create index if not exists products_active_idx   on public.products(is_active);

create sequence if not exists public.order_ref_seq;
create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  ref             text unique not null
                  default ('CMD-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.order_ref_seq')::text, 5, '0')),
  user_id         uuid not null references public.profiles(id) on delete restrict,
  status          public.order_status not null default 'nouvelle',
  customer_name   text not null,
  phone           text not null,
  city            text not null,
  address         text not null,
  note            text,
  payment_method  text not null default 'livraison',   -- paiement à la livraison
  subtotal        numeric(10,2) not null,
  delivery_fee    numeric(10,2) not null default 0,
  total           numeric(10,2) not null,
  admin_note      text,
  cancel_reason   text,
  confirmed_at    timestamptz,
  shipped_at      timestamptz,
  delivered_at    timestamptz,
  cancelled_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists orders_user_idx   on public.orders(user_id);
create index if not exists orders_status_idx on public.orders(status);

create table if not exists public.order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  product_id    uuid references public.products(id) on delete set null,
  product_name  text not null,          -- figé à la commande
  image         text,
  unit_price    numeric(10,2) not null,
  quantity      int not null check (quantity > 0),
  line_total    numeric(10,2) not null
);
create index if not exists order_items_order_idx on public.order_items(order_id);

drop trigger if exists products_touch on public.products;
create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();
drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();

-- 3. Réglages (frais de livraison)
insert into public.settings (key, value) values ('shop', '{"delivery_fee": 7, "free_delivery_from": null}')
on conflict (key) do nothing;

-- 4. Fonctions
-- Passer commande. p_items = [{"product_id": "<uuid>", "quantity": 2}, …]
create or replace function public.place_order(
  p_items jsonb, p_customer_name text, p_phone text, p_city text, p_address text, p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_item jsonb;
  v_product public.products;
  v_qty int;
  v_subtotal numeric(10,2) := 0;
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
    if v_product.stock < v_qty then
      raise exception 'Stock insuffisant pour « % » (% disponible%)', v_product.name, v_product.stock,
        case when v_product.stock > 1 then 's' else '' end;
    end if;
    update public.products set stock = stock - v_qty, sold_count = sold_count + v_qty where id = v_product.id;
    insert into public.order_items (order_id, product_id, product_name, image, unit_price, quantity, line_total)
    values (v_order, v_product.id, v_product.name, v_product.images[1], v_product.price, v_qty, v_product.price * v_qty);
    v_subtotal := v_subtotal + v_product.price * v_qty;
  end loop;

  select greatest(coalesce((value->>'delivery_fee')::numeric, 0), 0),
         nullif((value->>'free_delivery_from')::numeric, 0)
    into v_fee, v_free
    from public.settings where key = 'shop';
  v_fee := coalesce(v_fee, 0);
  if v_free is not null and v_subtotal >= v_free then v_fee := 0; end if;

  update public.orders set subtotal = v_subtotal, delivery_fee = v_fee, total = v_subtotal + v_fee where id = v_order;

  perform public.notify(auth.uid(), 'commande', 'Commande reçue',
    'Votre commande ' || v_ref || ' est enregistrée. Bakma vous appellera pour la confirmer.', '/espace/commandes');
  insert into public.notifications (user_id, type, title, body, link)
  select id, 'commande', 'Nouvelle commande boutique',
         v_ref || ' : ' || to_char(v_subtotal + v_fee, 'FM999G999D00') || ' TND (' || trim(p_city) || ').', '/boutique/commandes/' || v_order
  from public.profiles where role = 'admin' and status = 'actif';

  return v_order;
end $$;

-- Rendre le stock d'une commande (annulation)
create or replace function public.restock_order(p_order_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.products p set stock = p.stock + i.quantity, sold_count = greatest(p.sold_count - i.quantity, 0)
    from public.order_items i where i.order_id = p_order_id and i.product_id = p.id;
$$;
revoke all on function public.restock_order(uuid) from public, anon, authenticated;

-- Client : annuler tant que la commande n'est pas confirmée
create or replace function public.cancel_order(p_order_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_o public.orders;
begin
  select * into v_o from public.orders where id = p_order_id for update;
  if v_o.id is null or v_o.user_id <> auth.uid() then raise exception 'Commande introuvable'; end if;
  if v_o.status <> 'nouvelle' then raise exception 'Cette commande est déjà confirmée : contactez Bakma pour l''annuler.'; end if;
  update public.orders set status = 'annulee', cancelled_at = now(), cancel_reason = coalesce(nullif(trim(p_reason), ''), 'Annulée par le client')
   where id = p_order_id;
  perform public.restock_order(p_order_id);
  insert into public.notifications (user_id, type, title, body, link)
  select id, 'commande', 'Commande annulée par le client', v_o.ref || ' a été annulée.', '/boutique/commandes/' || p_order_id
  from public.profiles where role = 'admin' and status = 'actif';
end $$;

-- Admin : changer le statut (nouvelle → confirmee → expediee → livree, ou annulee)
create or replace function public.set_order_status(p_order_id uuid, p_status public.order_status, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_o public.orders;
  v_title text;
  v_body text;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_o from public.orders where id = p_order_id for update;
  if v_o.id is null then raise exception 'Commande introuvable'; end if;
  if v_o.status in ('livree', 'annulee') then raise exception 'Cette commande est clôturée'; end if;
  if p_status = v_o.status then return; end if;
  if p_status = 'nouvelle' then raise exception 'Statut invalide'; end if;

  update public.orders set
    status        = p_status,
    confirmed_at  = case when p_status = 'confirmee' then now() else confirmed_at end,
    shipped_at    = case when p_status = 'expediee' then now() else shipped_at end,
    delivered_at  = case when p_status = 'livree' then now() else delivered_at end,
    cancelled_at  = case when p_status = 'annulee' then now() else cancelled_at end,
    cancel_reason = case when p_status = 'annulee' then coalesce(nullif(trim(p_note), ''), 'Annulée par Bakma') else cancel_reason end,
    admin_note    = case when p_status <> 'annulee' and nullif(trim(p_note), '') is not null then trim(p_note) else admin_note end
  where id = p_order_id;

  if p_status = 'annulee' then perform public.restock_order(p_order_id); end if;

  v_title := case p_status
    when 'confirmee' then 'Commande confirmée'
    when 'expediee'  then 'Commande en cours de livraison'
    when 'livree'    then 'Commande livrée'
    else 'Commande annulée' end;
  v_body := case p_status
    when 'confirmee' then v_o.ref || ' est confirmée : nous préparons votre colis.'
    when 'expediee'  then v_o.ref || ' est en route. Préparez ' || to_char(v_o.total, 'FM999G999D00') || ' TND pour le livreur.'
    when 'livree'    then v_o.ref || ' a été livrée. Merci pour votre achat !'
    else v_o.ref || ' a été annulée' || coalesce(' : ' || nullif(trim(p_note), ''), '.') end;
  perform public.notify(v_o.user_id, 'commande', v_title, v_body, '/espace/commandes');
end $$;

grant execute on function public.place_order(jsonb, text, text, text, text, text) to authenticated;
grant execute on function public.cancel_order(uuid, text) to authenticated;
grant execute on function public.set_order_status(uuid, public.order_status, text) to authenticated;

-- 5. RLS
alter table public.shop_categories enable row level security;
alter table public.products        enable row level security;
alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;

drop policy if exists shop_categories_select on public.shop_categories;
create policy shop_categories_select on public.shop_categories for select using (is_active or public.is_admin());
drop policy if exists shop_categories_admin on public.shop_categories;
create policy shop_categories_admin on public.shop_categories for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists products_select on public.products;
create policy products_select on public.products for select using (is_active or public.is_admin());
drop policy if exists products_admin on public.products;
create policy products_admin on public.products for all using (public.is_admin()) with check (public.is_admin());

-- Commandes : lecture par le client et l'admin ; écriture uniquement via les fonctions ci-dessus
-- (l'admin peut aussi modifier la note interne directement).
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists orders_admin_update on public.orders;
create policy orders_admin_update on public.orders for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items for select using (
  exists (select 1 from public.orders o where o.id = order_id and (o.user_id = auth.uid() or public.is_admin()))
);

grant select on public.shop_categories, public.products to anon, authenticated;
grant insert, update, delete on public.shop_categories, public.products to authenticated;
-- Mise à jour directe limitée à la note interne : statut, montants et stock passent par les fonctions.
grant select on public.orders to authenticated;
revoke update on public.orders from authenticated;
grant update (admin_note) on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant usage on sequence public.shop_categories_id_seq to authenticated;

-- 6. Storage : photos des produits (bucket public)
insert into storage.buckets (id, name, public) values ('shop-images', 'shop-images', true)
on conflict (id) do nothing;

drop policy if exists "bakma public read" on storage.objects;
create policy "bakma public read" on storage.objects for select
  using (bucket_id in ('animal-photos', 'avatars', 'consultation-photos', 'shop-images'));

drop policy if exists "bakma upload own folder" on storage.objects;
create policy "bakma upload own folder" on storage.objects for insert to authenticated
  with check (
    bucket_id in ('animal-photos', 'avatars', 'consultation-photos', 'vet-documents', 'shop-images')
    and (storage.foldername(name))[1] = auth.uid()::text
    and (bucket_id <> 'shop-images' or public.is_admin())
  );

-- 7. Catégories de départ
insert into public.shop_categories (slug, name, icon, sort_order) values
  ('alimentation', 'Alimentation', 'bone', 1),
  ('accessoires', 'Accessoires', 'sparkles', 2),
  ('hygiene-soins', 'Hygiène & soins', 'bath', 3),
  ('jouets', 'Jouets', 'puzzle', 4),
  ('couchage-transport', 'Couchage & transport', 'house', 5)
on conflict (slug) do nothing;

-- 8. Temps réel : nouvelles commandes dans le back-office
do $$ begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object or undefined_object then null; end $$;
