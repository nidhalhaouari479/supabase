-- =============================================================================
--  Migration 2026-10-16 — Catalogue (caractéristiques gérées par l'admin)
--  À exécuter UNE FOIS dans Supabase > SQL Editor sur une base existante.
--  (supabase/schema.sql contient déjà ces changements pour une nouvelle installation.)
--
--  - Tables characteristic_groups / characteristic_options (+ RLS)
--  - Colonne animals.characteristics + synchro des anciennes colonnes santé/traits/besoins
--  - Données de départ (Santé, Caractère, Besoins) + reprise des annonces existantes
--  Création des vétérinaires par l'admin : aucun changement SQL, ajouter
--  SUPABASE_SERVICE_ROLE_KEY dans backoffice/.env.local.
-- =============================================================================

-- 1. Tables
-- Caractéristiques des animaux (Santé, Caractère, Besoins…), entièrement gérées par l'admin.
-- Un groupe = une rubrique du formulaire d'annonce ; ses options = les choix proposés.
create table if not exists public.characteristic_groups (
  id            serial primary key,
  slug          text unique not null,                -- clé dans animals.characteristics (non modifiable)
  name          text not null,
  icon          text,
  multiple      boolean not null default true,       -- plusieurs choix possibles
  allow_custom  boolean not null default false,      -- le propriétaire peut saisir une valeur libre
  sort_order    int not null default 0
);

create table if not exists public.characteristic_options (
  id          serial primary key,
  group_id    int not null references public.characteristic_groups(id) on delete cascade,
  label       text not null,
  icon        text,
  code        text unique,   -- lien avec les colonnes santé historiques : vaccinated | dewormed | healthy | sterilized
  sort_order  int not null default 0,
  unique (group_id, label)
);

-- Valeurs choisies par groupe de caractéristiques : { "<slug du groupe>": ["libellé", …] }.
-- Les colonnes vaccinated / dewormed / healthy / sterilized / traits / needs en sont déduites (trigger).
alter table public.animals add column if not exists characteristics jsonb not null default '{}'::jsonb;

-- 2. Fonctions et triggers
-- Vrai si les caractéristiques contiennent l'option portant ce code (ex. 'vaccinated').
create or replace function public.has_characteristic(p_chars jsonb, p_code text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.characteristic_options o join public.characteristic_groups g on g.id = o.group_id
    where o.code = p_code and jsonb_typeof(p_chars->g.slug) = 'array' and (p_chars->g.slug) ? o.label
  )
$$;

-- Déduit les colonnes historiques (santé, traits, besoins) de animals.characteristics.
create or replace function public.sync_animal_characteristics()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- '{}' = non renseigné (ancien client) : on conserve les colonnes telles quelles.
  if new.characteristics = '{}'::jsonb
     or (tg_op = 'UPDATE' and new.characteristics is not distinct from old.characteristics) then
    return new;
  end if;
  new.vaccinated := public.has_characteristic(new.characteristics, 'vaccinated');
  new.dewormed   := public.has_characteristic(new.characteristics, 'dewormed');
  new.healthy    := public.has_characteristic(new.characteristics, 'healthy');
  new.sterilized := public.has_characteristic(new.characteristics, 'sterilized');
  new.traits := case when jsonb_typeof(new.characteristics->'caractere') = 'array'
                     then array(select jsonb_array_elements_text(new.characteristics->'caractere')) else '{}' end;
  new.needs  := case when jsonb_typeof(new.characteristics->'besoins') = 'array'
                     then array(select jsonb_array_elements_text(new.characteristics->'besoins')) else '{}' end;
  return new;
end $$;
drop trigger if exists animals_characteristics on public.animals;
create trigger animals_characteristics before insert or update of characteristics on public.animals
  for each row execute function public.sync_animal_characteristics();

-- Renommer une option renomme aussi la valeur dans les annonces existantes.
create or replace function public.on_characteristic_option_rename()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_slug text;
begin
  if new.label is distinct from old.label then
    select slug into v_slug from public.characteristic_groups where id = old.group_id;
    update public.animals a
       set characteristics = jsonb_set(
             a.characteristics, array[v_slug],
             (select coalesce(jsonb_agg(case when x = old.label then new.label else x end), '[]'::jsonb)
                from jsonb_array_elements_text(a.characteristics->v_slug) x))
     where jsonb_typeof(a.characteristics->v_slug) = 'array' and (a.characteristics->v_slug) ? old.label;
  end if;
  return new;
end $$;
drop trigger if exists characteristic_options_rename on public.characteristic_options;
create trigger characteristic_options_rename after update on public.characteristic_options
  for each row execute function public.on_characteristic_option_rename();

-- 3. Sécurité (RLS)
alter table public.characteristic_groups  enable row level security;
alter table public.characteristic_options enable row level security;

drop policy if exists char_groups_select on public.characteristic_groups;
drop policy if exists char_groups_admin on public.characteristic_groups;
drop policy if exists char_options_select on public.characteristic_options;
drop policy if exists char_options_admin on public.characteristic_options;
create policy char_groups_select on public.characteristic_groups for select using (true);
create policy char_groups_admin on public.characteristic_groups for all using (public.is_admin()) with check (public.is_admin());
create policy char_options_select on public.characteristic_options for select using (true);
create policy char_options_admin on public.characteristic_options for all using (public.is_admin()) with check (public.is_admin());

-- 4. Données de départ
-- Caractéristiques de départ : insérées UNE SEULE FOIS (table vide), ensuite gérées
-- dans back-office > Catalogue (une ré-exécution n'écrase ni ne recrée rien).
do $seed$ begin
  if exists (select 1 from public.characteristic_groups) then return; end if;

  insert into public.characteristic_groups (slug, name, icon, multiple, allow_custom, sort_order) values
    ('sante', 'Santé', 'heart-pulse', true, false, 1),
    ('caractere', 'Caractère', 'sparkles', true, true, 2),
    ('besoins', 'Besoins', 'house', true, false, 3)
  on conflict do nothing;

  insert into public.characteristic_options (group_id, label, icon, code, sort_order)
  select g.id, v.label, v.icon, v.code, v.sort_order
  from (values
    ('sante', 'Vacciné', 'syringe', 'vaccinated', 1),
    ('sante', 'Vermifugé', 'pill', 'dewormed', 2),
    ('sante', 'En bonne santé', 'heart-pulse', 'healthy', 3),
    ('sante', 'Stérilisé', 'scissors', 'sterilized', 4),
    ('caractere', 'Sociable', 'users', null, 1),
    ('caractere', 'Calme', 'moon', null, 2),
    ('caractere', 'Joueur', 'puzzle', null, 3),
    ('caractere', 'Affectueux', 'heart', null, 4),
    ('caractere', 'Énergique', 'zap', null, 5),
    ('caractere', 'Propre', 'sparkles', null, 6),
    ('caractere', 'Bon avec les enfants', 'baby', null, 7),
    ('caractere', 'Bon avec les autres animaux', 'paw-print', null, 8),
    ('besoins', 'Espace extérieur', 'house', null, 1),
    ('besoins', 'Promenades régulières', 'leaf', null, 2),
    ('besoins', 'Alimentation adaptée', 'droplets', null, 3),
    ('besoins', 'Beaucoup d''attention', 'heart', null, 4),
    ('besoins', 'Toilettage régulier', 'scissors', null, 5),
    ('besoins', 'Cage / aquarium', 'box', null, 6)
  ) as v(slug, label, icon, code, sort_order)
  join public.characteristic_groups g on g.slug = v.slug
  on conflict do nothing;
end $seed$;

-- Reprise des annonces existantes : remplit animals.characteristics depuis les anciennes colonnes.
update public.animals a set characteristics = jsonb_build_object(
  'sante', (select coalesce(jsonb_agg(o.label order by o.sort_order), '[]'::jsonb)
              from public.characteristic_options o
             where (o.code = 'vaccinated' and a.vaccinated) or (o.code = 'dewormed' and a.dewormed)
                or (o.code = 'healthy' and a.healthy) or (o.code = 'sterilized' and a.sterilized)),
  'caractere', to_jsonb(a.traits),
  'besoins', to_jsonb(a.needs))
where a.characteristics = '{}'::jsonb;
