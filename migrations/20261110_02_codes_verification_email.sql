-- =============================================================================
--  Migration 2026-11-10 (2) — Inscription : code de vérification par e-mail
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261110_01).
--
--  L'inscription n'utilise plus le lien de confirmation Supabase : le site envoie un
--  code à 6 chiffres via notre SMTP (spa/app/api/auth/inscription/*), puis crée le
--  compte déjà confirmé avec la clé service_role.
--  Table accessible uniquement côté serveur (service_role) : RLS activé, aucune policy.
-- =============================================================================

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
