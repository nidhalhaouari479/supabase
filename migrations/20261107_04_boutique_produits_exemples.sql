-- =============================================================================
--  Migration 2026-11-07 (4) — Boutique : produits d'exemple
--  À exécuter UNE FOIS dans Supabase > SQL Editor (après 20261107_03).
--
--  14 produits de démonstration répartis dans les 5 catégories de départ.
--  Sans photo (le site affiche un pictogramme) : ajoutez les photos depuis
--  le back-office > Boutique > Produits, ou masquez / supprimez ces exemples.
--  Rejouable sans doublon : un produit n'est inséré que si son nom n'existe pas.
-- =============================================================================

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
