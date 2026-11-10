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
--
--  Achat (annonces « vente ») : aucun contact acheteur / vendeur.
--    reçu de virement → admin valide → garantie N jours (8 par défaut) → admin verse au vendeur
--    (ou litige → remboursement).
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

do $$ begin
  create type public.purchase_status as enum (
    'paiement_a_verifier', 'paiement_refuse', 'annulee', 'garantie', 'litige', 'versee', 'remboursee'
  );
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
  favorites_count    int not null default 0,   -- tenu à jour par le trigger favorites_refresh_count
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

-- Achats : aucun contact direct acheteur / vendeur, tout passe par Bakma.
--   paiement_a_verifier (reçu envoyé) → garantie (paiement validé, animal vendu, N jours)
--   → versee (payé au vendeur) | litige → versee | remboursee ;  paiement_refuse / annulee sinon.
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
  payer_name        text,              -- titulaire du compte qui a fait le virement (saisi par l'acheteur)
  payer_account     text,              -- numéro de ce compte / RIB (chiffres uniquement)
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
drop trigger if exists purchases_touch on public.purchases;
create trigger purchases_touch before update on public.purchases for each row execute function public.touch_updated_at();
drop trigger if exists payout_accounts_touch on public.payout_accounts;
create trigger payout_accounts_touch before update on public.payout_accounts for each row execute function public.touch_updated_at();

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
    new.published_at    := old.published_at;
    new.views_count     := old.views_count;
    new.favorites_count := old.favorites_count;
  end if;
  return new;
end $$;
drop trigger if exists animals_protect on public.animals;
create trigger animals_protect before update on public.animals
  for each row execute function public.protect_animal_status();

-- Compteur de favoris : mis à jour à chaque ajout / retrait d'un favori
create or replace function public.animal_favorites_refresh()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_animal uuid := coalesce(new.animal_id, old.animal_id);
  v_prev   text := current_setting('bakma.workflow', true);
begin
  perform set_config('bakma.workflow', 'on', true);
  update public.animals
     set favorites_count = (select count(*) from public.favorites where animal_id = v_animal)
   where id = v_animal;
  perform set_config('bakma.workflow', coalesce(v_prev, ''), true);
  return null;
end $$;

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

-- Messagerie : un client ne contacte pas un autre client. Il peut écrire aux administrateurs et aux
-- vétérinaires attribués à ses animaux (règle unique : can_contact, aussi appliquée à messages_insert).
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

-- Démarrer (ou retrouver) une conversation avec un contact autorisé.
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

-- Personnes que l'utilisateur connecté peut contacter (page Messages).
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

-- ----- ACHATS (paiement par virement + garantie avant versement au vendeur)
-- Indicateur public : un paiement est-il en cours de vérification pour cet animal ?
create or replace function public.is_animal_reserved(p_animal_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.purchases where animal_id = p_animal_id and status = 'paiement_a_verifier')
$$;

-- Acheteur : acheter un animal en envoyant le reçu de virement
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

-- Admin : verser le paiement au vendeur (après la garantie, litige tranché en sa faveur,
-- ou plus tôt avec p_early = true : l'acheteur est prévenu que l'achat est finalisé)
drop function if exists public.release_purchase_payout(uuid, text);
create or replace function public.release_purchase_payout(p_purchase_id uuid, p_reference text default null, p_early boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare v_p public.purchases; v_name text; v_early boolean;
begin
  if not public.is_admin() then raise exception 'Réservé aux administrateurs'; end if;
  select * into v_p from public.purchases where id = p_purchase_id for update;
  if v_p.id is null then raise exception 'Achat introuvable'; end if;
  if v_p.status not in ('garantie', 'litige') then raise exception 'Cet achat ne peut pas être versé'; end if;
  v_early := v_p.status = 'garantie' and now() < v_p.release_at;
  if v_early and not coalesce(p_early, false) then
    raise exception 'Garantie en cours : versement possible à partir du %',
      to_char(v_p.release_at at time zone 'Africa/Tunis', 'DD/MM/YYYY à HH24:MI');
  end if;

  update public.purchases
     set status = 'versee', paid_out_at = now(), paid_out_by = auth.uid(), payout_reference = nullif(trim(p_reference), '')
   where id = p_purchase_id;
  select name into v_name from public.animals where id = v_p.animal_id;
  insert into public.activity_log (type, animal_id, actor_id, message)
  values ('achat_verse', v_p.animal_id, auth.uid(),
          case when v_early then 'Paiement versé au vendeur avant la fin de la garantie' else 'Paiement versé au vendeur' end);
  perform public.notify(v_p.seller_id, 'achat', 'Paiement versé 💸',
    to_char(v_p.amount, 'FM999G999D00') || ' TND pour ' || v_name || ' ont été virés sur votre compte.', '/espace/achats?onglet=ventes');
  if v_p.status = 'litige' then
    perform public.notify(v_p.buyer_id, 'achat', 'Litige clôturé',
      'Après examen, Bakma a clôturé le litige sur ' || v_name || '.', '/espace/achats');
  elsif v_early then
    perform public.notify(v_p.buyer_id, 'achat', 'Achat finalisé',
      'Bakma a finalisé votre achat de ' || v_name || ' et versé le paiement au vendeur. Pour toute question, contactez Bakma.', '/espace/achats');
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
-- compteur animals.favorites_count (fonction animal_favorites_refresh plus haut)
drop trigger if exists favorites_refresh_count on public.favorites;
create trigger favorites_refresh_count after insert or delete on public.favorites
  for each row execute function public.animal_favorites_refresh();
alter table public.conversations          enable row level security;
alter table public.messages               enable row level security;
alter table public.notifications          enable row level security;
alter table public.reports                enable row level security;
alter table public.activity_log           enable row level security;
alter table public.settings               enable row level security;
alter table public.purchases              enable row level security;
alter table public.payout_accounts        enable row level security;

-- Supprime les anciennes policies pour rendre le script ré-exécutable
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public' and tablename in (
             'profiles','profile_contacts','veterinarians','categories','characteristic_groups','characteristic_options','cities','animals','animal_photos',
             'publication_requests','consultations','consultation_exams','vaccinations',
             'consultation_documents','consultation_photos','animal_documents','owner_identities','favorites','conversations','messages',
             'notifications','reports','activity_log','settings','purchases','payout_accounts') loop
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
-- Pas d'insert direct : création uniquement via start_conversation (security definer).

create policy messages_select on public.messages for select using (
  exists (select 1 from public.conversations c where c.id = conversation_id
          and (auth.uid() in (c.participant_a, c.participant_b) or public.is_admin()))
);
create policy messages_insert on public.messages for insert with check (
  sender_id = auth.uid() and exists (
    select 1 from public.conversations c
    where c.id = conversation_id and auth.uid() in (c.participant_a, c.participant_b)
      and public.can_contact(case when c.participant_a = auth.uid() then c.participant_b else c.participant_a end))
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

-- ACHATS : l'acheteur lit les siens (écritures via RPC) ; le vendeur passe par my_sales() ; l'admin voit tout
create policy purchases_buyer on public.purchases for select using (buyer_id = auth.uid());
create policy purchases_admin on public.purchases for all using (public.is_admin()) with check (public.is_admin());

-- RIB DU VENDEUR : l'intéressé et les admins
create policy payout_own on public.payout_accounts for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy payout_admin on public.payout_accounts for all using (public.is_admin()) with check (public.is_admin());

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
grant execute on function public.can_contact(uuid) to authenticated;
grant execute on function public.list_contacts() to authenticated;
grant execute on function public.increment_views(uuid) to anon, authenticated;
grant execute on function public.is_animal_certified(uuid) to anon, authenticated;
grant execute on function public.is_animal_reserved(uuid) to anon, authenticated;
grant execute on function public.create_purchase(uuid, text, text, text, text, text) to authenticated;
grant execute on function public.cancel_purchase(uuid) to authenticated;
grant execute on function public.verify_purchase_payment(uuid, text) to authenticated;
grant execute on function public.reject_purchase_payment(uuid, text) to authenticated;
grant execute on function public.open_purchase_dispute(uuid, text) to authenticated;
grant execute on function public.release_purchase_payout(uuid, text, boolean) to authenticated;
grant execute on function public.refund_purchase(uuid, text, text) to authenticated;
grant execute on function public.my_sales() to authenticated;
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
  using (bucket_id in ('animal-photos', 'avatars', 'consultation-photos', 'shop-images'));

drop policy if exists "bakma upload own folder" on storage.objects;
create policy "bakma upload own folder" on storage.objects for insert to authenticated
  with check (
    bucket_id in ('animal-photos', 'avatars', 'consultation-photos', 'vet-documents', 'shop-images')
    and (storage.foldername(name))[1] = auth.uid()::text
    and (bucket_id <> 'shop-images' or public.is_admin())   -- photos boutique : admins uniquement
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
  ('moderation', '{"require_vet_check": true, "max_photos": 6, "auto_notify_vets": true}'),
  ('payment', '{"bank_name": "", "account_holder": "Bakma Store", "rib": "", "hold_days": 8}')
on conflict (key) do nothing;

-- =============================================================================
-- BOUTIQUE EN LIGNE (produits pour animaux) — Bakma seul vendeur, paiement à la livraison
-- Frais de livraison : settings.shop { delivery_fee, free_delivery_from }
-- =============================================================================
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
-- Codes promo (réduction en % sur les produits ; limites null = illimité)
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
  total           numeric(10,2) not null,              -- subtotal - discount + delivery_fee
  promo_code_id   uuid references public.promo_codes(id) on delete set null,
  promo_code      text,                                -- code saisi (copie figée)
  promo_percent   numeric(5,2),
  discount        numeric(10,2) not null default 0,    -- réduction du code promo (hors livraison)
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
-- (bases existantes) colonnes code promo
alter table public.orders add column if not exists promo_code_id uuid references public.promo_codes(id) on delete set null;
alter table public.orders add column if not exists promo_code    text;
alter table public.orders add column if not exists promo_percent numeric(5,2);
alter table public.orders add column if not exists discount      numeric(10,2) not null default 0;
create index if not exists orders_promo_idx on public.orders(promo_code_id) where promo_code_id is not null;

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
-- p_items = [{"product_id": "<uuid>", "variant_id": "<uuid|null>", "quantity": 2}, …]
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
    when 'livree'    then v_o.ref || ' a été livrée. Merci pour votre achat ! Donnez votre avis sur vos produits.'
    else v_o.ref || ' a été annulée' || coalesce(' : ' || nullif(trim(p_note), ''), '.') end;
  perform public.notify(v_o.user_id, 'commande', v_title, v_body, '/espace/commandes');
end $$;

grant execute on function public.place_order(jsonb, text, text, text, text, text, text) to authenticated;
grant execute on function public.check_promo_code(text) to authenticated;
grant execute on function public.cancel_order(uuid, text) to authenticated;
grant execute on function public.set_order_status(uuid, public.order_status, text) to authenticated;

-- 5. RLS
alter table public.shop_categories enable row level security;
alter table public.products        enable row level security;
alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;
alter table public.promo_codes     enable row level security;
drop policy if exists promo_codes_admin_all on public.promo_codes;
create policy promo_codes_admin_all on public.promo_codes for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.promo_codes to authenticated;

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

insert into storage.buckets (id, name, public) values ('shop-images', 'shop-images', true)
on conflict (id) do nothing;

-- 7. Catégories de départ
insert into public.shop_categories (slug, name, icon, sort_order) values
  ('alimentation', 'Alimentation', 'bone', 1),
  ('accessoires', 'Accessoires', 'sparkles', 2),
  ('hygiene-soins', 'Hygiène & soins', 'bath', 3),
  ('jouets', 'Jouets', 'puzzle', 4),
  ('couchage-transport', 'Couchage & transport', 'house', 5)
on conflict (slug) do nothing;

-- Produits d'exemple (sans photo) : à compléter, masquer ou supprimer depuis le back-office.
insert into public.products (category_id, name, brand, short_description, description, price, compare_at_price, stock, is_featured)
select c.id, v.name, v.brand, v.short_description, v.description, v.price, v.compare_at_price, v.stock, v.is_featured
from (values
  -- Alimentation
  ('alimentation', 'Croquettes chien adulte poulet & riz 3 kg', 'Royal Canin',
   'Alimentation complète pour chiens adultes de taille moyenne.',
   E'Croquettes riches en protéines de poulet, avec riz facile à digérer.\nAide à maintenir un poids idéal et un pelage brillant.\nPour chiens de 11 à 25 kg, à partir de 12 mois.',
   89.000, 99.000, 25, true),
  ('alimentation', 'Croquettes chat stérilisé saumon 2 kg', 'Purina One',
   'Pour chats stérilisés : contrôle du poids et santé urinaire.',
   E'Recette au saumon, riche en fibres naturelles.\nFavorise la santé des voies urinaires et limite la prise de poids.',
   54.500, null, 30, true),
  ('alimentation', 'Pâtée chat au thon – lot de 12 sachets', 'Felix',
   'Sachets fraîcheur en gelée, 12 × 85 g.',
   'Morceaux tendres de thon en gelée. Complète l''alimentation sèche et aide à l''hydratation.',
   28.900, 32.000, 40, false),
  ('alimentation', 'Graines pour perruches 1 kg', 'Vitakraft',
   'Mélange de graines enrichi en vitamines.',
   'Mélange de millet, alpiste et avoine décortiquée. Convient aux perruches et petites perruches.',
   12.500, null, 50, false),
  ('alimentation', 'Friandises dentaires chien – 7 bâtonnets', 'Pedigree Dentastix',
   'Réduit la plaque dentaire au quotidien.',
   'Un bâtonnet par jour aide à réduire l''accumulation de tartre grâce à sa texture unique.',
   14.900, null, 60, false),
  -- Accessoires
  ('accessoires', 'Laisse réglable nylon 1,5 m', 'Bakma',
   'Laisse solide avec poignée rembourrée.',
   'Nylon résistant, mousqueton en métal chromé. Convient aux chiens jusqu''à 30 kg.',
   24.000, null, 35, false),
  ('accessoires', 'Gamelle inox antidérapante 750 ml', 'Bakma',
   'Gamelle en acier inoxydable avec base en caoutchouc.',
   'Hygiénique, passe au lave-vaisselle. La base antidérapante évite les renversements.',
   18.500, 22.000, 45, false),
  ('accessoires', 'Arbre à chat 3 niveaux 90 cm', 'Trixie',
   'Griffoir en sisal, niche et plateformes.',
   E'Poteaux en sisal naturel pour les griffes, une niche douillette et deux plateformes.\nHauteur 90 cm, base 40 × 40 cm.',
   145.000, 169.000, 8, true),
  -- Hygiène & soins
  ('hygiene-soins', 'Shampooing doux chien & chat 250 ml', 'Beaphar',
   'Formule hypoallergénique au pH neutre.',
   'Nettoie en douceur sans irriter la peau. Parfum léger, convient aux peaux sensibles.',
   19.900, null, 30, false),
  ('hygiene-soins', 'Litière agglomérante 10 L', 'Catsan',
   'Contrôle des odeurs longue durée.',
   'Litière minérale qui forme des boulettes compactes, faciles à retirer.',
   21.500, null, 40, false),
  ('hygiene-soins', 'Pipettes antiparasitaires chien – 3 pipettes', 'Frontline',
   'Protection contre puces et tiques pendant 3 mois.',
   'Une pipette par mois. Pour chiens de 10 à 20 kg. Demandez conseil à votre vétérinaire.',
   62.000, 68.000, 20, false),
  -- Jouets
  ('jouets', 'Balle en caoutchouc résistante', 'Kong',
   'Jouet à mâcher quasi indestructible.',
   'Caoutchouc naturel rebondissant. Peut être garni de friandises pour occuper votre chien.',
   16.000, null, 50, false),
  ('jouets', 'Canne à plumes pour chat', 'Bakma',
   'Jouet interactif pour stimuler le chasseur.',
   'Tige flexible de 45 cm avec plumes et clochette. Idéal pour jouer ensemble.',
   9.500, null, 70, false),
  -- Couchage & transport
  ('couchage-transport', 'Panier coussin moelleux 60 cm', 'Bakma',
   'Couchage douillet, housse lavable.',
   'Rebords rembourrés pour se blottir, fond antidérapant. Pour chats et petits chiens.',
   59.000, 75.000, 12, true)
) as v(cat_slug, name, brand, short_description, description, price, compare_at_price, stock, is_featured)
join public.shop_categories c on c.slug = v.cat_slug
where not exists (select 1 from public.products p where p.name = v.name);

-- ---------------------------------------------------------------- Marques de la boutique
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

-- Reprise des marques saisies en texte sur les produits
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

-- ---------------------------------------------------------------- Boutique : favoris, avis, détails, variantes
-- a. Colonnes produit
alter table public.products add column if not exists details       text;                              -- texte libre (composition, conseils…)
alter table public.products add column if not exists specs         jsonb not null default '[]';        -- [{"label": "Poids", "value": "3 kg"}]
alter table public.products add column if not exists detail_images text[] not null default '{}';       -- visuels (étiquette, tableau nutritionnel…)
alter table public.products add column if not exists options       jsonb not null default '[]';        -- [{"name": "Taille", "values": ["S", "M"]}]
alter table public.products add column if not exists rating_avg    numeric(2,1) not null default 0;
alter table public.products add column if not exists rating_count  int not null default 0;

-- b. Déclinaisons
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

-- c. Avis
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

-- d. Favoris produits
create table if not exists public.product_favorites (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, product_id)
);
create index if not exists product_favorites_product_idx on public.product_favorites(product_id);

-- e. RLS
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

-- ---------------------------------------------------------------- Inscription : code de vérification par e-mail
-- Code à 6 chiffres envoyé par le site (SMTP), table réservée au serveur (service_role).
create table if not exists public.email_verification_codes (
  email         text not null,
  purpose       text not null default 'signup',
  code_hash     text not null,               -- sha256(code + email + secret serveur), jamais le code en clair
  expires_at    timestamptz not null,
  attempts      int not null default 0,      -- essais ratés (bloqué à 5)
  last_sent_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  primary key (email, purpose)
);

alter table public.email_verification_codes enable row level security;
revoke all on public.email_verification_codes from anon, authenticated;

-- 8. Temps réel : nouvelles commandes dans le back-office
do $$ begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object or undefined_object then null; end $$;

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
