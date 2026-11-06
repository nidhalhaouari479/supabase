-- =============================================================================
--  BAKMA STORE — Schéma Supabase complet
--  À exécuter UNE FOIS dans Supabase > SQL Editor > New query > Run.
--  Le script est idempotent : il peut être relancé sans casser les données.
--
--  Rôles : particulier (client / propriétaire), veterinaire, admin.
--  (Le rôle « photographe » de la maquette a été volontairement supprimé.)
--
--  Workflow d'une annonce :
--    brouillon → (soumission) → en_verification
--      → consultation vétérinaire (nouvelle → en_cours → terminee | a_revoir)
--      → en_attente_approbation → (admin) publiee | refusee
--    Le propriétaire peut annuler tant que l'annonce n'est pas publiée.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. TYPES
-- -----------------------------------------------------------------------------
do $$ begin
  create type public.user_role as enum ('particulier', 'veterinaire', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.account_status as enum ('actif', 'suspendu');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.animal_sex as enum ('male', 'femelle');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.age_unit as enum ('jours', 'semaines', 'mois', 'ans');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.listing_type as enum ('adoption', 'vente');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.animal_status as enum (
    'brouillon', 'en_verification', 'en_attente_approbation',
    'publiee', 'refusee', 'annulee', 'adoptee', 'vendue'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.request_status as enum ('en_cours', 'approuvee', 'refusee', 'annulee');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.request_step as enum (
    'soumise', 'verification_veterinaire', 'attente_approbation', 'publiee'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.consultation_status as enum ('nouvelle', 'en_cours', 'terminee', 'a_revoir', 'annulee');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.vet_decision as enum ('approuve', 'refuse', 'a_revoir');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.exam_result as enum ('normal', 'a_surveiller', 'anormal');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.vaccination_status as enum ('a_jour', 'a_faire', 'en_retard');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.report_status as enum ('ouvert', 'en_cours', 'resolu', 'rejete');
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- 2. TABLES
-- -----------------------------------------------------------------------------

-- Profils (1-1 avec auth.users)
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  role            public.user_role not null default 'particulier',
  status          public.account_status not null default 'actif',
  full_name       text not null default '',
  avatar_url      text,
  city            text,
  bio             text,
  response_time   text default 'Répond généralement rapidement',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- Coordonnées privées (email / téléphone) : séparées des profils publics
create table if not exists public.profile_contacts (
  id          uuid primary key references public.profiles(id) on delete cascade,
  email       text,
  phone       text,
  updated_at  timestamptz not null default now()
);

-- Informations spécifiques aux vétérinaires
create table if not exists public.veterinarians (
  profile_id      uuid primary key references public.profiles(id) on delete cascade,
  clinic_name     text,
  license_number  text,
  specialty       text,
  address         text,
  city            text,
  is_verified     boolean not null default false,   -- validé par un admin
  verified_at     timestamptz,
  created_at      timestamptz not null default now()
);

-- Catégories d'animaux
create table if not exists public.categories (
  id          serial primary key,
  slug        text unique not null,
  name        text not null,
  icon        text,
  sort_order  int not null default 0
);

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

-- Villes (Tunisie)
create table if not exists public.cities (
  id    serial primary key,
  name  text unique not null
);

-- Animaux / annonces
create table if not exists public.animals (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null references public.profiles(id) on delete cascade,
  category_id        int references public.categories(id),
  name               text not null,
  breed              text,
  age_value          int,
  age_unit           public.age_unit default 'mois',
  sex                public.animal_sex,
  size               text,
  weight_kg          numeric(6,2),
  color              text,
  city               text,
  latitude           double precision,
  longitude          double precision,
  short_description  text,
  description        text,
  why_adopt          text,
  vaccinated         boolean not null default false,
  dewormed           boolean not null default false,
  healthy            boolean not null default false,
  sterilized         boolean not null default false,
  traits             text[] not null default '{}',
  needs              text[] not null default '{}',
  adoption_conditions text,
  listing_type       public.listing_type not null default 'adoption',
  price              numeric(10,2) not null default 0,
  status             public.animal_status not null default 'brouillon',
  cover_url          text,
  views_count        int not null default 0,
  published_at       timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists animals_status_idx   on public.animals(status);
create index if not exists animals_owner_idx    on public.animals(owner_id);
create index if not exists animals_category_idx on public.animals(category_id);
create index if not exists animals_city_idx     on public.animals(city);

-- Valeurs choisies par groupe de caractéristiques : { "<slug du groupe>": ["libellé", …] }.
-- Les colonnes vaccinated / dewormed / healthy / sterilized / traits / needs en sont déduites (trigger).
alter table public.animals add column if not exists characteristics jsonb not null default '{}'::jsonb;

-- Photos des annonces
create table if not exists public.animal_photos (
  id          uuid primary key default gen_random_uuid(),
  animal_id   uuid not null references public.animals(id) on delete cascade,
  url         text not null,
  position    int not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists animal_photos_animal_idx on public.animal_photos(animal_id);

-- Demandes de publication
create sequence if not exists public.request_ref_seq;
create table if not exists public.publication_requests (
  id              uuid primary key default gen_random_uuid(),
  ref             text unique not null
                  default ('DP-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.request_ref_seq')::text, 5, '0')),
  animal_id       uuid not null references public.animals(id) on delete cascade,
  owner_id        uuid not null references public.profiles(id) on delete cascade,
  status          public.request_status not null default 'en_cours',
  step            public.request_step not null default 'soumise',
  admin_note      text,
  refusal_reason  text,
  submitted_at    timestamptz not null default now(),
  decided_at      timestamptz,
  decided_by      uuid references public.profiles(id),
  updated_at      timestamptz not null default now()
);
create index if not exists requests_status_idx on public.publication_requests(status);
create index if not exists requests_animal_idx on public.publication_requests(animal_id);

-- Consultations vétérinaires
create table if not exists public.consultations (
  id              uuid primary key default gen_random_uuid(),
  request_id      uuid not null references public.publication_requests(id) on delete cascade,
  animal_id       uuid not null references public.animals(id) on delete cascade,
  vet_id          uuid references public.profiles(id) on delete set null,  -- null = non attribuée
  status          public.consultation_status not null default 'nouvelle',
  scheduled_at    timestamptz,
  consulted_at    timestamptz,
  summary         text,
  observations    text,
  weight_kg       numeric(6,2),
  temperature     numeric(4,1),
  decision        public.vet_decision,
  certified       boolean not null default false,
  review_reason   text,           -- motif si « à revoir »
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists consultations_vet_idx     on public.consultations(vet_id);
create index if not exists consultations_status_idx  on public.consultations(status);
create index if not exists consultations_request_idx on public.consultations(request_id);

create table if not exists public.consultation_exams (
  id               uuid primary key default gen_random_uuid(),
  consultation_id  uuid not null references public.consultations(id) on delete cascade,
  name             text not null,
  result           public.exam_result not null default 'normal',
  note             text,
  position         int not null default 0
);

create table if not exists public.vaccinations (
  id               uuid primary key default gen_random_uuid(),
  consultation_id  uuid references public.consultations(id) on delete cascade,
  animal_id        uuid not null references public.animals(id) on delete cascade,
  name             text not null,
  status           public.vaccination_status not null default 'a_jour',
  vaccinated_on    date,
  next_due_on      date
);

create table if not exists public.consultation_documents (
  id               uuid primary key default gen_random_uuid(),
  consultation_id  uuid not null references public.consultations(id) on delete cascade,
  title            text not null,
  file_path        text not null,   -- chemin dans le bucket privé « vet-documents »
  file_name        text,
  kind             text default 'rapport',  -- rapport | vaccination | certificat | autre
  created_at       timestamptz not null default now()
);

create table if not exists public.consultation_photos (
  id               uuid primary key default gen_random_uuid(),
  consultation_id  uuid not null references public.consultations(id) on delete cascade,
  url              text not null,
  created_at       timestamptz not null default now()
);

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

-- Favoris
create table if not exists public.favorites (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  animal_id   uuid not null references public.animals(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, animal_id)
);

-- Messagerie
create table if not exists public.conversations (
  id               uuid primary key default gen_random_uuid(),
  animal_id        uuid references public.animals(id) on delete set null,
  participant_a    uuid not null references public.profiles(id) on delete cascade,
  participant_b    uuid not null references public.profiles(id) on delete cascade,
  last_message     text,
  last_message_at  timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  constraint conversations_distinct check (participant_a <> participant_b)
);
create unique index if not exists conversations_unique_pair
  on public.conversations (least(participant_a, participant_b), greatest(participant_a, participant_b), coalesce(animal_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table if not exists public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations(id) on delete cascade,
  sender_id        uuid not null references public.profiles(id) on delete cascade,
  body             text not null,
  read_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index if not exists messages_conversation_idx on public.messages(conversation_id, created_at);

-- Notifications
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  type        text not null default 'info',
  title       text not null,
  body        text,
  link        text,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);

-- Signalements
create table if not exists public.reports (
  id                uuid primary key default gen_random_uuid(),
  reporter_id       uuid references public.profiles(id) on delete set null,
  animal_id         uuid references public.animals(id) on delete cascade,
  reported_user_id  uuid references public.profiles(id) on delete cascade,
  reason            text not null,
  details           text,
  status            public.report_status not null default 'ouvert',
  handled_by        uuid references public.profiles(id),
  handled_at        timestamptz,
  created_at        timestamptz not null default now()
);

-- Journal d'activité (tableau de bord admin)
create table if not exists public.activity_log (
  id          uuid primary key default gen_random_uuid(),
  type        text not null,    -- nouvelle_demande | consultation_prise | consultation_terminee | a_revoir | approuvee | refusee | annulee
  request_id  uuid references public.publication_requests(id) on delete cascade,
  animal_id   uuid references public.animals(id) on delete cascade,
  actor_id    uuid references public.profiles(id) on delete set null,
  message     text,
  created_at  timestamptz not null default now()
);
create index if not exists activity_log_created_idx on public.activity_log(created_at desc);

-- Paramètres de la plateforme (admin)
create table if not exists public.settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 3. FONCTIONS UTILITAIRES
-- -----------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and status = 'actif')
$$;

create or replace function public.is_vet()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p join public.veterinarians v on v.profile_id = p.id
    where p.id = auth.uid() and p.role = 'veterinaire' and p.status = 'actif' and v.is_verified
  )
$$;

-- Helpers SECURITY DEFINER (évitent la récursion entre policies animals <-> consultations)
create or replace function public.owns_animal(p_animal_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.animals where id = p_animal_id and owner_id = auth.uid())
$$;

create or replace function public.is_vet_of_animal(p_animal_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.consultations where animal_id = p_animal_id and vet_id = auth.uid())
$$;

create or replace function public.can_see_consultation(p_consultation_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.consultations c join public.animals a on a.id = c.animal_id
    where c.id = p_consultation_id and (
      public.is_admin() or a.owner_id = auth.uid() or c.vet_id = auth.uid()
      or (c.vet_id is null and public.is_vet())
    )
  )
$$;

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

create or replace function public.is_consultation_vet(p_consultation_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.consultations where id = p_consultation_id and vet_id = auth.uid())
$$;

create or replace function public.shares_consultation(p_other uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.consultations c join public.animals a on a.id = c.animal_id
    where (c.vet_id = auth.uid() and a.owner_id = p_other) or (a.owner_id = auth.uid() and c.vet_id = p_other)
  )
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists animals_touch on public.animals;
create trigger animals_touch before update on public.animals for each row execute function public.touch_updated_at();
drop trigger if exists requests_touch on public.publication_requests;
create trigger requests_touch before update on public.publication_requests for each row execute function public.touch_updated_at();
drop trigger if exists consultations_touch on public.consultations;
create trigger consultations_touch before update on public.consultations for each row execute function public.touch_updated_at();

-- Création automatique du profil à l'inscription.
-- Toute inscription crée un compte 'particulier' (le rôle n'est jamais lu depuis les métadonnées).
-- Les comptes vétérinaire / admin sont attribués ensuite par un administrateur.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := 'particulier';
begin
  insert into public.profiles (id, role, full_name, city, avatar_url)
  values (
    new.id, v_role,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'city',
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;

  insert into public.profile_contacts (id, email, phone)
  values (new.id, new.email, new.raw_user_meta_data->>'phone')
  on conflict (id) do nothing;

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Garde l'email de profile_contacts synchronisé avec auth.users
create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profile_contacts set email = new.email, updated_at = now() where id = new.id;
  return new;
end $$;
drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row execute function public.handle_user_email_change();

-- Empêche un utilisateur non-admin de modifier son propre rôle / statut.
create or replace function public.protect_profile_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role   := old.role;
    new.status := old.status;
  end if;
  return new;
end $$;
drop trigger if exists profiles_protect on public.profiles;
create trigger profiles_protect before update on public.profiles
  for each row execute function public.protect_profile_columns();

-- Quand un admin passe un utilisateur en 'veterinaire', sa fiche vétérinaire est créée et validée.
create or replace function public.on_profile_role_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role = 'veterinaire' and old.role is distinct from 'veterinaire' then
    insert into public.veterinarians (profile_id, city, is_verified, verified_at)
    values (new.id, new.city, true, now())
    on conflict (profile_id) do update set is_verified = true, verified_at = coalesce(veterinarians.verified_at, now());
    perform public.notify(new.id, 'compte', 'Compte vétérinaire activé',
      'Vous avez désormais accès à l''espace vétérinaire de Bakma Store.', null);
  end if;
  return new;
end $$;
drop trigger if exists profiles_role_change on public.profiles;
create trigger profiles_role_change after update of role on public.profiles
  for each row execute function public.on_profile_role_change();

-- Empêche un vétérinaire de s'auto-valider.
create or replace function public.protect_vet_columns()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.is_verified := old.is_verified;
    new.verified_at := old.verified_at;
  end if;
  return new;
end $$;
drop trigger if exists veterinarians_protect on public.veterinarians;
create trigger veterinarians_protect before update on public.veterinarians
  for each row execute function public.protect_vet_columns();

-- Le propriétaire ne peut pas forcer le statut d'une annonce (sauf brouillon / adoptée / vendue).
create or replace function public.protect_animal_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
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
drop trigger if exists animals_protect on public.animals;
create trigger animals_protect before update on public.animals
  for each row execute function public.protect_animal_status();

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

-- Notification helper
create or replace function public.notify(p_user uuid, p_type text, p_title text, p_body text, p_link text)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, type, title, body, link) values (p_user, p_type, p_title, p_body, p_link);
$$;

-- Mise à jour du dernier message d'une conversation
create or replace function public.on_new_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message = left(new.body, 200), last_message_at = new.created_at
  where id = new.conversation_id;
  return new;
end $$;
drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert after insert on public.messages
  for each row execute function public.on_new_message();

-- Documents de l'animal (facultatifs) : 6 maximum par annonce
create or replace function public.check_animal_documents_limit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- verrou sur l'annonce : deux dépôts simultanés ne peuvent pas dépasser la limite
  perform 1 from public.animals where id = new.animal_id for update;
  if (select count(*) from public.animal_documents where animal_id = new.animal_id) >= 6 then
    raise exception 'Vous pouvez joindre 6 documents maximum par annonce';
  end if;
  return new;
end $$;
drop trigger if exists animal_documents_limit on public.animal_documents;
create trigger animal_documents_limit before insert on public.animal_documents
  for each row execute function public.check_animal_documents_limit();

-- -----------------------------------------------------------------------------
-- 4. WORKFLOW (RPC appelées depuis les applications via supabase.rpc(...))
-- -----------------------------------------------------------------------------

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

-- Propriétaire : annuler sa demande
create or replace function public.cancel_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_req public.publication_requests;
begin
  select * into v_req from public.publication_requests where id = p_request_id;
  if v_req.id is null then raise exception 'Demande introuvable'; end if;
  if v_req.owner_id <> auth.uid() and not public.is_admin() then raise exception 'Accès refusé'; end if;
  if v_req.status <> 'en_cours' then raise exception 'Cette demande ne peut plus être annulée'; end if;

  perform set_config('bakma.workflow', 'on', true);
  update public.publication_requests set status = 'annulee', decided_at = now() where id = p_request_id;
  update public.consultations set status = 'annulee' where request_id = p_request_id and status in ('nouvelle', 'en_cours', 'a_revoir');
  update public.animals set status = 'annulee' where id = v_req.animal_id;
  insert into public.activity_log (type, request_id, animal_id, actor_id, message)
  values ('annulee', p_request_id, v_req.animal_id, auth.uid(), 'Demande annulée');
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

-- Vétérinaire : clôturer la consultation avec une décision
create or replace function public.complete_consultation(
  p_consultation_id uuid, p_decision public.vet_decision, p_review_reason text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_c public.consultations; v_owner uuid; v_name text;
begin
  select * into v_c from public.consultations where id = p_consultation_id for update;
  if v_c.id is null then raise exception 'Consultation introuvable'; end if;
  if v_c.vet_id is distinct from auth.uid() then raise exception 'Accès refusé'; end if;
  if v_c.status not in ('en_cours', 'a_revoir') then raise exception 'Consultation non modifiable'; end if;

  select a.owner_id, a.name into v_owner, v_name from public.animals a where a.id = v_c.animal_id;
  perform set_config('bakma.workflow', 'on', true);

  if p_decision = 'a_revoir' then
    update public.consultations set status = 'a_revoir', decision = 'a_revoir', review_reason = p_review_reason,
           consulted_at = coalesce(consulted_at, now()) where id = p_consultation_id;
    insert into public.activity_log (type, request_id, animal_id, actor_id, message)
    values ('a_revoir', v_c.request_id, v_c.animal_id, auth.uid(), 'Consultation à revoir');
    perform public.notify(v_owner, 'consultation', 'Informations à compléter',
      coalesce(p_review_reason, 'Le vétérinaire demande des compléments pour ' || v_name || '.'),
      '/espace/annonces/' || v_c.animal_id);
  else
    update public.consultations set status = 'terminee', decision = p_decision,
           certified = (p_decision = 'approuve'), consulted_at = coalesce(consulted_at, now())
     where id = p_consultation_id;
    update public.publication_requests set step = 'attente_approbation' where id = v_c.request_id;
    update public.animals set status = 'en_attente_approbation' where id = v_c.animal_id;
    insert into public.activity_log (type, request_id, animal_id, actor_id, message)
    values ('consultation_terminee', v_c.request_id, v_c.animal_id, auth.uid(),
            case when p_decision = 'approuve' then 'Validée par le vétérinaire' else 'Avis défavorable du vétérinaire' end);
    -- notifier les admins
    insert into public.notifications (user_id, type, title, body, link)
    select id, 'demande', 'Demande en attente d''approbation',
           v_name || ' : consultation vétérinaire terminée.', '/demandes/' || v_c.request_id
    from public.profiles where role = 'admin' and status = 'actif';
  end if;
end $$;

-- Propriétaire : signaler que les compléments demandés (« à revoir ») ont été apportés
create or replace function public.resubmit_consultation(p_consultation_id uuid, p_message text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_c public.consultations; v_name text;
begin
  select * into v_c from public.consultations where id = p_consultation_id for update;
  if v_c.id is null then raise exception 'Consultation introuvable'; end if;
  if not public.owns_animal(v_c.animal_id) then raise exception 'Accès refusé'; end if;
  if v_c.status <> 'a_revoir' then raise exception 'Aucun complément n''est demandé pour cette consultation'; end if;

  update public.consultations set status = 'en_cours', review_reason = null where id = p_consultation_id;
  select name into v_name from public.animals where id = v_c.animal_id;
  insert into public.activity_log (type, request_id, animal_id, actor_id, message)
  values ('complements_envoyes', v_c.request_id, v_c.animal_id, auth.uid(), 'Compléments envoyés par le propriétaire');
  if v_c.vet_id is not null then
    perform public.notify(v_c.vet_id, 'consultation', 'Compléments reçus',
      coalesce(p_message, 'Le propriétaire de ' || v_name || ' a complété les informations demandées.'),
      '/demandes/' || p_consultation_id);
  end if;
end $$;

-- Admin : approuver (publier) une demande
create or replace function public.approve_request(p_request_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_req public.publication_requests; v_name text;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_req from public.publication_requests where id = p_request_id for update;
  if v_req.id is null then raise exception 'Demande introuvable'; end if;
  if v_req.status <> 'en_cours' then raise exception 'Demande déjà traitée'; end if;

  perform set_config('bakma.workflow', 'on', true);
  update public.publication_requests
     set status = 'approuvee', step = 'publiee', admin_note = p_note, decided_at = now(), decided_by = auth.uid()
   where id = p_request_id;
  update public.animals set status = 'publiee', published_at = now() where id = v_req.animal_id
  returning name into v_name;
  insert into public.activity_log (type, request_id, animal_id, actor_id, message)
  values ('approuvee', p_request_id, v_req.animal_id, auth.uid(), 'Demande approuvée');
  perform public.notify(v_req.owner_id, 'demande', 'Annonce publiée 🎉',
    v_name || ' est maintenant visible sur Bakma Store.', '/animaux/' || v_req.animal_id);
end $$;

-- Admin : refuser une demande
create or replace function public.refuse_request(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_req public.publication_requests; v_name text;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_req from public.publication_requests where id = p_request_id for update;
  if v_req.id is null then raise exception 'Demande introuvable'; end if;
  if v_req.status <> 'en_cours' then raise exception 'Demande déjà traitée'; end if;

  perform set_config('bakma.workflow', 'on', true);
  update public.publication_requests
     set status = 'refusee', refusal_reason = p_reason, decided_at = now(), decided_by = auth.uid()
   where id = p_request_id;
  update public.consultations set status = 'annulee' where request_id = p_request_id and status in ('nouvelle', 'en_cours', 'a_revoir');
  update public.animals set status = 'refusee' where id = v_req.animal_id returning name into v_name;
  insert into public.activity_log (type, request_id, animal_id, actor_id, message)
  values ('refusee', p_request_id, v_req.animal_id, auth.uid(), 'Demande refusée');
  perform public.notify(v_req.owner_id, 'demande', 'Annonce refusée',
    coalesce(p_reason, 'Votre annonce ' || v_name || ' n''a pas été acceptée.'), '/espace/annonces/' || v_req.animal_id);
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

-- Démarrer (ou retrouver) une conversation avec un autre utilisateur
create or replace function public.start_conversation(p_other uuid, p_animal_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  if p_other = auth.uid() then raise exception 'Impossible de vous écrire à vous-même'; end if;
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

-- Incrémenter le compteur de vues (public)
create or replace function public.increment_views(p_animal_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('bakma.workflow', 'on', true);
  update public.animals set views_count = views_count + 1 where id = p_animal_id and status = 'publiee';
end $$;

-- Indicateur public : l'animal a-t-il été certifié par un vétérinaire ?
create or replace function public.is_animal_certified(p_animal_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.consultations c join public.animals a on a.id = c.animal_id
    where c.animal_id = p_animal_id and c.status = 'terminee' and c.certified
      and a.status in ('publiee', 'adoptee', 'vendue')
  )
$$;

-- Statistiques publiques (compte par catégorie des annonces publiées)
create or replace view public.category_counts with (security_invoker = true) as
  select c.id, c.slug, c.name, c.icon, c.sort_order,
         count(a.id) filter (where a.status = 'publiee') as total
  from public.categories c left join public.animals a on a.category_id = c.id
  group by c.id;

-- -----------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- -----------------------------------------------------------------------------
alter table public.profiles               enable row level security;
alter table public.profile_contacts       enable row level security;
alter table public.veterinarians          enable row level security;
alter table public.categories             enable row level security;
alter table public.characteristic_groups  enable row level security;
alter table public.characteristic_options enable row level security;
alter table public.cities                 enable row level security;
alter table public.animals                enable row level security;
alter table public.animal_photos          enable row level security;
alter table public.publication_requests   enable row level security;
alter table public.consultations          enable row level security;
alter table public.consultation_exams     enable row level security;
alter table public.vaccinations           enable row level security;
alter table public.consultation_documents enable row level security;
alter table public.consultation_photos    enable row level security;
alter table public.animal_documents       enable row level security;
alter table public.owner_identities       enable row level security;
alter table public.favorites              enable row level security;
alter table public.conversations          enable row level security;
alter table public.messages               enable row level security;
alter table public.notifications          enable row level security;
alter table public.reports                enable row level security;
alter table public.activity_log           enable row level security;
alter table public.settings               enable row level security;

-- Supprime les anciennes policies pour rendre le script ré-exécutable
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public' and tablename in (
             'profiles','profile_contacts','veterinarians','categories','characteristic_groups','characteristic_options','cities','animals','animal_photos',
             'publication_requests','consultations','consultation_exams','vaccinations',
             'consultation_documents','consultation_photos','animal_documents','owner_identities','favorites','conversations','messages',
             'notifications','reports','activity_log','settings') loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- PROFILES : lecture publique (nom, avatar… affichés sur les annonces)
create policy profiles_select on public.profiles for select using (true);
create policy profiles_update_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_admin_all on public.profiles for all using (public.is_admin()) with check (public.is_admin());

-- PROFILE CONTACTS : soi-même, admin, et les parties d'une même consultation (vétérinaire <-> propriétaire)
create policy contacts_select on public.profile_contacts for select using (
  id = auth.uid()
  or public.is_admin()
  or public.shares_consultation(id)
);
create policy contacts_update_self on public.profile_contacts for update using (id = auth.uid()) with check (id = auth.uid());
create policy contacts_admin on public.profile_contacts for all using (public.is_admin()) with check (public.is_admin());

-- VETERINARIANS
create policy vets_select on public.veterinarians for select using (true);
create policy vets_update_self on public.veterinarians for update using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy vets_admin_all on public.veterinarians for all using (public.is_admin()) with check (public.is_admin());

-- CATEGORIES / CITIES : lecture publique, écriture admin
create policy categories_select on public.categories for select using (true);
create policy categories_admin on public.categories for all using (public.is_admin()) with check (public.is_admin());
create policy char_groups_select on public.characteristic_groups for select using (true);
create policy char_groups_admin on public.characteristic_groups for all using (public.is_admin()) with check (public.is_admin());
create policy char_options_select on public.characteristic_options for select using (true);
create policy char_options_admin on public.characteristic_options for all using (public.is_admin()) with check (public.is_admin());
create policy cities_select on public.cities for select using (true);
create policy cities_admin on public.cities for all using (public.is_admin()) with check (public.is_admin());

-- ANIMALS
create policy animals_select on public.animals for select using (
  status in ('publiee', 'adoptee', 'vendue')
  or owner_id = auth.uid()
  or public.is_admin()
  or (public.is_vet() and status in ('en_verification', 'en_attente_approbation'))
  or public.is_vet_of_animal(id)
);
create policy animals_insert_owner on public.animals for insert with check (owner_id = auth.uid() and status = 'brouillon');
create policy animals_update_owner on public.animals for update
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy animals_delete_owner on public.animals for delete
  using (owner_id = auth.uid() and status in ('brouillon', 'refusee', 'annulee'));
create policy animals_admin_all on public.animals for all using (public.is_admin()) with check (public.is_admin());

-- ANIMAL PHOTOS (visibles si l'animal est visible)
create policy animal_photos_select on public.animal_photos for select using (
  exists (select 1 from public.animals a where a.id = animal_id)
);
create policy animal_photos_owner on public.animal_photos for all
  using (public.owns_animal(animal_id)) with check (public.owns_animal(animal_id));
create policy animal_photos_admin on public.animal_photos for all using (public.is_admin()) with check (public.is_admin());

-- PUBLICATION REQUESTS (écritures via RPC uniquement, sauf admin)
create policy requests_select on public.publication_requests for select using (
  owner_id = auth.uid() or public.is_admin() or public.is_vet()
);
create policy requests_admin on public.publication_requests for all using (public.is_admin()) with check (public.is_admin());

-- CONSULTATIONS
create policy consultations_select on public.consultations for select using (
  public.is_admin()
  or (public.is_vet() and (vet_id = auth.uid() or vet_id is null))
  or public.owns_animal(animal_id)
);
create policy consultations_vet_update on public.consultations for update
  using (vet_id = auth.uid() and status in ('nouvelle', 'en_cours', 'a_revoir'))
  with check (vet_id = auth.uid());
create policy consultations_admin on public.consultations for all using (public.is_admin()) with check (public.is_admin());

-- Détails de consultation : lisibles par ceux qui voient la consultation, modifiables par le vétérinaire assigné
create policy exams_select on public.consultation_exams for select using (public.can_see_consultation(consultation_id));
create policy exams_vet on public.consultation_exams for all
  using (public.is_consultation_vet(consultation_id)) with check (public.is_consultation_vet(consultation_id));
create policy exams_admin on public.consultation_exams for all using (public.is_admin()) with check (public.is_admin());

create policy vaccinations_select on public.vaccinations for select using (
  exists (select 1 from public.animals a where a.id = animal_id)
);
create policy vaccinations_vet on public.vaccinations for all
  using (public.is_consultation_vet(consultation_id)) with check (public.is_consultation_vet(consultation_id));
create policy vaccinations_admin on public.vaccinations for all using (public.is_admin()) with check (public.is_admin());

create policy documents_select on public.consultation_documents for select using (public.can_see_consultation(consultation_id));
create policy documents_vet on public.consultation_documents for all
  using (public.is_consultation_vet(consultation_id)) with check (public.is_consultation_vet(consultation_id));
create policy documents_admin on public.consultation_documents for all using (public.is_admin()) with check (public.is_admin());

create policy cphotos_select on public.consultation_photos for select using (public.can_see_consultation(consultation_id));
create policy cphotos_vet on public.consultation_photos for all
  using (public.is_consultation_vet(consultation_id)) with check (public.is_consultation_vet(consultation_id));
create policy cphotos_admin on public.consultation_photos for all using (public.is_admin()) with check (public.is_admin());

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

-- FAVORITES
create policy favorites_own on public.favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- CONVERSATIONS / MESSAGES
create policy conversations_participant on public.conversations for select using (
  auth.uid() in (participant_a, participant_b) or public.is_admin()
);
create policy conversations_insert on public.conversations for insert with check (auth.uid() in (participant_a, participant_b));

create policy messages_select on public.messages for select using (
  exists (select 1 from public.conversations c where c.id = conversation_id
          and (auth.uid() in (c.participant_a, c.participant_b) or public.is_admin()))
);
create policy messages_insert on public.messages for insert with check (
  sender_id = auth.uid() and exists (
    select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.participant_a, c.participant_b))
);
create policy messages_mark_read on public.messages for update using (
  exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.participant_a, c.participant_b))
);

-- NOTIFICATIONS
create policy notifications_own on public.notifications for select using (user_id = auth.uid());
create policy notifications_update_own on public.notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_delete_own on public.notifications for delete using (user_id = auth.uid());
create policy notifications_admin on public.notifications for all using (public.is_admin()) with check (public.is_admin());

-- REPORTS
create policy reports_insert on public.reports for insert with check (reporter_id = auth.uid());
create policy reports_select_own on public.reports for select using (reporter_id = auth.uid() or public.is_admin());
create policy reports_admin on public.reports for all using (public.is_admin()) with check (public.is_admin());

-- ACTIVITY LOG
create policy activity_admin on public.activity_log for select using (public.is_admin());

-- SETTINGS : lecture publique, écriture admin
create policy settings_select on public.settings for select using (true);
create policy settings_admin on public.settings for all using (public.is_admin()) with check (public.is_admin());

-- Droits d'exécution des RPC
grant execute on function public.submit_animal(uuid, timestamptz[]) to authenticated;
grant execute on function public.cancel_request(uuid) to authenticated;
grant execute on function public.claim_consultation(uuid, timestamptz) to authenticated;
grant execute on function public.complete_consultation(uuid, public.vet_decision, text) to authenticated;
grant execute on function public.approve_request(uuid, text) to authenticated;
grant execute on function public.resubmit_consultation(uuid, text) to authenticated;
grant execute on function public.refuse_request(uuid, text) to authenticated;
grant execute on function public.assign_vet(uuid, uuid, timestamptz) to authenticated;
grant execute on function public.start_conversation(uuid, uuid) to authenticated;
grant execute on function public.increment_views(uuid) to anon, authenticated;
grant execute on function public.is_animal_certified(uuid) to anon, authenticated;
revoke execute on function public.notify(uuid, text, text, text, text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. STORAGE (buckets + policies)
--    Chemin des fichiers : <user_id>/<...>  (le 1er dossier = propriétaire)
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values
  ('animal-photos', 'animal-photos', true),
  ('avatars', 'avatars', true),
  ('consultation-photos', 'consultation-photos', true),
  ('vet-documents', 'vet-documents', false)
on conflict (id) do nothing;

drop policy if exists "bakma public read" on storage.objects;
create policy "bakma public read" on storage.objects for select
  using (bucket_id in ('animal-photos', 'avatars', 'consultation-photos'));

drop policy if exists "bakma upload own folder" on storage.objects;
create policy "bakma upload own folder" on storage.objects for insert to authenticated
  with check (
    bucket_id in ('animal-photos', 'avatars', 'consultation-photos', 'vet-documents')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "bakma update own folder" on storage.objects;
create policy "bakma update own folder" on storage.objects for update to authenticated
  using ((storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "bakma delete own folder" on storage.objects;
create policy "bakma delete own folder" on storage.objects for delete to authenticated
  using ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin());

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

-- -----------------------------------------------------------------------------
-- 7. REALTIME (messages + notifications en direct)
-- -----------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- -----------------------------------------------------------------------------
-- 8. DONNÉES DE BASE
-- -----------------------------------------------------------------------------
insert into public.categories (slug, name, icon, sort_order) values
  ('chiens', 'Chiens', 'dog', 1),
  ('chats', 'Chats', 'cat', 2),
  ('oiseaux', 'Oiseaux', 'bird', 3),
  ('rongeurs', 'Rongeurs', 'rabbit', 4),
  ('poissons', 'Poissons', 'fish', 5),
  ('reptiles', 'Reptiles', 'turtle', 6),
  ('animaux-de-ferme', 'Animaux de ferme', 'horse', 7),
  ('autres', 'Autres', 'paw-print', 8)
on conflict (slug) do nothing;  -- les catégories sont ensuite gérées par l'admin (back-office > Catalogue)

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

insert into public.cities (name) values
  ('Tunis'), ('Ariana'), ('Ben Arous'), ('Manouba'), ('Nabeul'), ('Zaghouan'), ('Bizerte'),
  ('Béja'), ('Jendouba'), ('Le Kef'), ('Siliana'), ('Sousse'), ('Monastir'), ('Mahdia'),
  ('Sfax'), ('Kairouan'), ('Kasserine'), ('Sidi Bouzid'), ('Gabès'), ('Médenine'),
  ('Tataouine'), ('Gafsa'), ('Tozeur'), ('Kébili')
on conflict (name) do nothing;

insert into public.settings (key, value) values
  ('platform', '{"name": "Bakma Store", "contact_email": "contact@bakma.tn", "contact_phone": "+216 00 000 000", "currency": "TND"}'),
  ('moderation', '{"require_vet_check": true, "max_photos": 6, "auto_notify_vets": true}')
on conflict (key) do nothing;

-- =============================================================================
--  CRÉER LE PREMIER ADMINISTRATEUR
--  1) Inscrivez-vous normalement (site public ou Supabase > Authentication > Add user)
--  2) Exécutez :
--       update public.profiles set role = 'admin'
--         where id = (select id from auth.users where email = 'votre@email.com');
--
--  CRÉER UN VÉTÉRINAIRE : back-office > Vétérinaires > « Ajouter un vétérinaire »
--  (nécessite SUPABASE_SERVICE_ROLE_KEY dans backoffice/.env.local).
--  Ou bien le vétérinaire s'inscrit sur le site public, puis un admin change son rôle
--  en « Vétérinaire » (back-office > Utilisateurs) ou en SQL :
--       update public.profiles set role = 'veterinaire'
--       where id = (select id from auth.users where email = 'veto@email.com');
-- =============================================================================
