-- =============================================================================
--  Migration 2026-11-07 (5) — Boutique : marques
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261107_04).
--
--  - shop_brands         : marques gérées par l'admin (nom, slug, logo, ordre, active)
--  - products.brand_id   : lien vers la marque (filtre « Marque » sur la boutique)
--  - products.brand      : conservé, recopié automatiquement depuis la marque (affichage)
--  Les marques déjà saisies en texte sur les produits sont reprises automatiquement.
-- =============================================================================

-- 1. Table
create table if not exists public.shop_brands (
  id          serial primary key,
  name        text unique not null,
  slug        text unique not null,
  logo_url    text,                     -- URL publique (bucket shop-images)
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

alter table public.products add column if not exists brand_id int references public.shop_brands(id) on delete set null;
create index if not exists products_brand_idx on public.products(brand_id);

-- 2. Reprise des marques saisies en texte
insert into public.shop_brands (name, slug)
select distinct on (lower(trim(brand))) trim(brand),
       trim(both '-' from regexp_replace(lower(translate(trim(brand),
         'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ',
         'aaaaaaceeeeiiiinooooouuuuyyaaaaaaceeeeiiiinooooouuuuy')), '[^a-z0-9]+', '-', 'g'))
from public.products
where coalesce(trim(brand), '') <> ''
order by lower(trim(brand))
on conflict do nothing;

update public.products p set brand_id = b.id
from public.shop_brands b
where p.brand_id is null and lower(trim(p.brand)) = lower(b.name);

-- 3. Le nom affiché (products.brand) suit toujours la marque liée
create or replace function public.products_sync_brand()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.brand_id is not null then
    new.brand := (select name from public.shop_brands where id = new.brand_id);
  elsif tg_op = 'UPDATE' and old.brand_id is not null then
    new.brand := null;  -- marque retirée (ou supprimée)
  end if;                -- sinon : texte libre conservé (anciens produits non liés)
  return new;
end $$;

drop trigger if exists products_sync_brand on public.products;
create trigger products_sync_brand before insert or update of brand_id, brand on public.products
  for each row execute function public.products_sync_brand();

create or replace function public.shop_brands_propagate_name()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.name is distinct from old.name then
    update public.products set brand = new.name where brand_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists shop_brands_propagate_name on public.shop_brands;
create trigger shop_brands_propagate_name after update of name on public.shop_brands
  for each row execute function public.shop_brands_propagate_name();

-- Marque supprimée : brand_id passe à null (on delete set null), ce qui relance
-- products_sync_brand et vide le nom affiché.

-- 4. RLS
alter table public.shop_brands enable row level security;

drop policy if exists shop_brands_select on public.shop_brands;
create policy shop_brands_select on public.shop_brands for select using (is_active or public.is_admin());
drop policy if exists shop_brands_admin on public.shop_brands;
create policy shop_brands_admin on public.shop_brands for all using (public.is_admin()) with check (public.is_admin());

grant select on public.shop_brands to anon, authenticated;
grant insert, update, delete on public.shop_brands to authenticated;
grant usage on sequence public.shop_brands_id_seq to authenticated;
