-- =============================================================================
-- Versement anticipé : l'admin peut verser le paiement au vendeur avant la fin
-- de la garantie (p_early = true). L'acheteur est alors prévenu que la garantie
-- est clôturée.
-- =============================================================================

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

revoke execute on function public.release_purchase_payout(uuid, text, boolean) from public, anon;
grant execute on function public.release_purchase_payout(uuid, text, boolean) to authenticated;
