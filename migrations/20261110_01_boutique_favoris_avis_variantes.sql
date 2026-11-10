-- =============================================================================
--  Migration 2026-11-10 (1) — Boutique : favoris, avis, détails produit, variantes
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261107_05).
--
--  - products.details / specs / detail_images : onglet « Détails du produit »
--  - products.options + product_variants     : déclinaisons (taille, couleur…) avec
--                                              prix, stock et photo propres
--  - products.rating_avg / rating_count      : note moyenne (tenue à jour par trigger)
--  - product_reviews                         : avis clients (achat livré obligatoire)
--  - product_favorites                       : produits favoris des clients
--  - order_items.variant_id / variant_label  : déclinaison commandée (figée)
--  - place_order / restock_order             : gestion du stock par déclinaison
-- =============================================================================

-- 1. Colonnes produit
alter table public.products add column if not exists details       text;                              -- texte libre (composition, conseils…)
alter table public.products add column if not exists specs         jsonb not null default '[]';        -- [{"label": "Poids", "value": "3 kg"}]
alter table public.products add column if not exists detail_images text[] not null default '{}';       -- visuels (étiquette, tableau nutritionnel…)
alter table public.products add column if not exists options       jsonb not null default '[]';        -- [{"name": "Taille", "values": ["S", "M"]}]
alter table public.products add column if not exists rating_avg    numeric(2,1) not null default 0;
alter table public.products add column if not exists rating_count  int not null default 0;

-- 2. Déclinaisons
create table if not exists public.product_variants (
  id                uuid primary key default gen_random_uuid(),
  product_id        uuid not null references public.products(id) on delete cascade,
  options           jsonb not null default '{}',     -- {"Taille": "M", "Couleur": "Rouge"}
  label             text not null,                   -- « M / Rouge » (affichage, commandes)
  sku               text,
  price             numeric(10,2) check (price is null or price > 0),                       -- null = prix du produit
  compare_at_price  numeric(10,2) check (compare_at_price is null or compare_at_price > 0),
  stock             int not null default 0 check (stock >= 0),
  image             text,                            -- photo propre (ex. la couleur)
  is_active         boolean not null default true,
  sort_order        int not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint product_variants_label_uniq unique (product_id, label) deferrable initially deferred
);
create index if not exists product_variants_product_idx on public.product_variants(product_id);

drop trigger if exists product_variants_touch on public.product_variants;
create trigger product_variants_touch before update on public.product_variants for each row execute function public.touch_updated_at();

alter table public.order_items add column if not exists variant_id    uuid references public.product_variants(id) on delete set null;
alter table public.order_items add column if not exists variant_label text;

-- Produit à déclinaisons : son stock = somme des déclinaisons actives (listes, rupture, filtres).
create or replace function public.products_sync_variant_stock()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(new.options) = 'array' and jsonb_array_length(new.options) > 0 then
    new.stock := coalesce((select sum(stock) from public.product_variants where product_id = new.id and is_active), 0);
  end if;
  return new;
end $$;

drop trigger if exists products_sync_variant_stock on public.products;
create trigger products_sync_variant_stock before insert or update on public.products
  for each row execute function public.products_sync_variant_stock();

create or replace function public.product_variants_refresh_product()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- relance products_sync_variant_stock
  update public.products set updated_at = now() where id = coalesce(new.product_id, old.product_id);
  return null;
end $$;

drop trigger if exists product_variants_refresh_product on public.product_variants;
create trigger product_variants_refresh_product after insert or update or delete on public.product_variants
  for each row execute function public.product_variants_refresh_product();

-- Admin : remplacer les déclinaisons d'un produit en une fois.
-- p_variants = [{"id": "<uuid|null>", "options": {...}, "label": "M / Rouge", "sku": null,
--                "price": null, "compare_at_price": null, "stock": 3, "image": null, "is_active": true}]
create or replace function public.set_product_variants(p_product_id uuid, p_variants jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v jsonb;
  i int := 0;
  v_id uuid;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  if not exists (select 1 from public.products where id = p_product_id) then raise exception 'Produit introuvable'; end if;
  if p_variants is null or jsonb_typeof(p_variants) <> 'array' then p_variants := '[]'; end if;
  if jsonb_array_length(p_variants) > 100 then raise exception 'Trop de déclinaisons (100 maximum)'; end if;

  delete from public.product_variants
   where product_id = p_product_id
     and id not in (select (e->>'id')::uuid from jsonb_array_elements(p_variants) e where coalesce(e->>'id', '') <> '');

  for v in select * from jsonb_array_elements(p_variants) loop
    i := i + 1;
    if coalesce(trim(v->>'label'), '') = '' then raise exception 'Déclinaison sans nom'; end if;
    if coalesce((v->>'stock')::int, 0) < 0 then raise exception 'Stock invalide pour « % »', v->>'label'; end if;
    v_id := nullif(v->>'id', '')::uuid;
    if v_id is not null and exists (select 1 from public.product_variants where id = v_id and product_id = p_product_id) then
      update public.product_variants set
        options = coalesce(v->'options', '{}'), label = trim(v->>'label'), sku = nullif(trim(v->>'sku'), ''),
        price = nullif(v->>'price', '')::numeric, compare_at_price = nullif(v->>'compare_at_price', '')::numeric,
        stock = coalesce((v->>'stock')::int, 0), image = nullif(v->>'image', ''),
        is_active = coalesce((v->>'is_active')::boolean, true), sort_order = i
      where id = v_id;
    else
      insert into public.product_variants (product_id, options, label, sku, price, compare_at_price, stock, image, is_active, sort_order)
      values (p_product_id, coalesce(v->'options', '{}'), trim(v->>'label'), nullif(trim(v->>'sku'), ''),
              nullif(v->>'price', '')::numeric, nullif(v->>'compare_at_price', '')::numeric,
              coalesce((v->>'stock')::int, 0), nullif(v->>'image', ''), coalesce((v->>'is_active')::boolean, true), i);
    end if;
  end loop;

  update public.products set updated_at = now() where id = p_product_id;
end $$;
grant execute on function public.set_product_variants(uuid, jsonb) to authenticated;

-- 3. Avis
create table if not exists public.product_reviews (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references public.products(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  rating      smallint not null check (rating between 1 and 5),
  comment     text check (comment is null or length(comment) <= 2000),
  is_visible  boolean not null default true,       -- l'admin peut masquer un avis
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (product_id, user_id)
);
create index if not exists product_reviews_product_idx on public.product_reviews(product_id, created_at desc);

drop trigger if exists product_reviews_touch on public.product_reviews;
create trigger product_reviews_touch before update on public.product_reviews for each row execute function public.touch_updated_at();

-- Le client a-t-il reçu ce produit (commande livrée) ?
create or replace function public.has_purchased_product(p_product_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.order_items i join public.orders o on o.id = i.order_id
    where o.user_id = auth.uid() and o.status = 'livree' and i.product_id = p_product_id
  );
$$;
grant execute on function public.has_purchased_product(uuid) to authenticated;

-- Seul l'admin change la visibilité ; le client ne peut ni déplacer ni réattribuer son avis.
create or replace function public.protect_review_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    new.is_visible := old.is_visible;
    new.product_id := old.product_id;
    new.user_id := old.user_id;
  end if;
  return new;
end $$;

drop trigger if exists protect_review_columns on public.product_reviews;
create trigger protect_review_columns before update on public.product_reviews
  for each row execute function public.protect_review_columns();

-- Note moyenne du produit (avis visibles)
create or replace function public.product_reviews_refresh_rating()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pid uuid := coalesce(new.product_id, old.product_id);
begin
  update public.products p set
    rating_count = s.n,
    rating_avg   = coalesce(round(s.avg, 1), 0)
  from (select count(*) as n, avg(rating) as avg from public.product_reviews where product_id = v_pid and is_visible) s
  where p.id = v_pid;
  return null;
end $$;

drop trigger if exists product_reviews_refresh_rating on public.product_reviews;
create trigger product_reviews_refresh_rating after insert or update or delete on public.product_reviews
  for each row execute function public.product_reviews_refresh_rating();

-- Nouvel avis : prévenir les admins
create or replace function public.on_new_product_review()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, type, title, body, link)
  select pr.id, 'avis', 'Nouvel avis produit',
         repeat('★', new.rating) || ' sur « ' || (select name from public.products where id = new.product_id) || ' »',
         '/boutique/avis'
  from public.profiles pr where pr.role = 'admin' and pr.status = 'actif';
  return null;
end $$;

drop trigger if exists on_new_product_review on public.product_reviews;
create trigger on_new_product_review after insert on public.product_reviews
  for each row execute function public.on_new_product_review();

-- 4. Favoris produits
create table if not exists public.product_favorites (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, product_id)
);
create index if not exists product_favorites_product_idx on public.product_favorites(product_id);

-- 5. Commande : stock par déclinaison
-- p_items = [{"product_id": "<uuid>", "variant_id": "<uuid|null>", "quantity": 2}, …]
create or replace function public.place_order(
  p_items jsonb, p_customer_name text, p_phone text, p_city text, p_address text, p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_item jsonb;
  v_product public.products;
  v_variant public.product_variants;
  v_qty int;
  v_price numeric(10,2);
  v_image text;
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

-- Rendre le stock d'une commande (annulation). Agrégé : un même produit peut figurer
-- sur plusieurs lignes (une par déclinaison).
create or replace function public.restock_order(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.product_variants v set stock = v.stock + a.q
    from (select variant_id, sum(quantity) as q from public.order_items
           where order_id = p_order_id and variant_id is not null group by variant_id) a
   where v.id = a.variant_id;

  -- (pour un produit à déclinaisons, le stock est ensuite recalculé par products_sync_variant_stock)
  update public.products p set
      stock = p.stock + a.q_simple,
      sold_count = greatest(p.sold_count - a.q, 0)
    from (select product_id, sum(quantity) as q,
                 coalesce(sum(quantity) filter (where variant_id is null), 0) as q_simple
            from public.order_items where order_id = p_order_id and product_id is not null group by product_id) a
   where p.id = a.product_id;
end $$;
revoke all on function public.restock_order(uuid) from public, anon, authenticated;

-- 6. Livraison : inviter à donner un avis
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
    when 'livree'    then v_o.ref || ' a été livrée. Merci pour votre achat ! Donnez votre avis sur vos produits.'
    else v_o.ref || ' a été annulée' || coalesce(' : ' || nullif(trim(p_note), ''), '.') end;
  perform public.notify(v_o.user_id, 'commande', v_title, v_body, '/espace/commandes');
end $$;

-- 7. RLS
alter table public.product_variants  enable row level security;
alter table public.product_reviews   enable row level security;
alter table public.product_favorites enable row level security;

drop policy if exists product_variants_select on public.product_variants;
create policy product_variants_select on public.product_variants for select using (is_active or public.is_admin());
drop policy if exists product_variants_admin on public.product_variants;
create policy product_variants_admin on public.product_variants for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists product_reviews_select on public.product_reviews;
create policy product_reviews_select on public.product_reviews for select
  using (is_visible or user_id = auth.uid() or public.is_admin());
drop policy if exists product_reviews_insert on public.product_reviews;
create policy product_reviews_insert on public.product_reviews for insert
  with check (user_id = auth.uid() and public.has_purchased_product(product_id));
drop policy if exists product_reviews_update on public.product_reviews;
create policy product_reviews_update on public.product_reviews for update
  using (user_id = auth.uid() or public.is_admin()) with check (user_id = auth.uid() or public.is_admin());
drop policy if exists product_reviews_delete on public.product_reviews;
create policy product_reviews_delete on public.product_reviews for delete
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists product_favorites_own on public.product_favorites;
create policy product_favorites_own on public.product_favorites for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select on public.product_variants, public.product_reviews to anon, authenticated;
grant insert, update, delete on public.product_variants to authenticated;
grant insert, delete on public.product_reviews to authenticated;
grant update (rating, comment, is_visible) on public.product_reviews to authenticated;
grant select, insert, delete on public.product_favorites to authenticated;
