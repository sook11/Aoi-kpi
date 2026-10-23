-- =====================================================================
-- Migration 71: ซื้อที่ดินขยายฟาร์มได้ไม่จำกัด · ราคาแพงขึ้นเรื่อย ๆ
--   ที่ดิน 4 แปลงแรกเหมือนเดิม · แปลงที่ 5 ขึ้นไป: ราคา = 1,500 × 1.35^(ลำดับ−4) (ปัดหลักสิบ)
--   ต้องเลเวล 9 + 2×(ลำดับ−4) · ได้แปลงผักเพิ่มที่ละ 4 แปลงเหมือนเดิม · ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || '{"land_more":{"base":1500,"mul":1.35,"lv0":9,"lvstep":2}}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

create or replace function public.farm_land_info(p_k int) returns jsonb
language sql immutable as $$
  select case when p_k < jsonb_array_length(public.farm_cat()->'land') then public.farm_cat()->'land'->p_k
    else jsonb_build_object('n', 'ที่ดินขยาย แปลงที่ ' || (p_k + 1),
      'cost', (round(((public.farm_cat()->'land_more'->>'base')::numeric * power((public.farm_cat()->'land_more'->>'mul')::numeric, p_k - jsonb_array_length(public.farm_cat()->'land') + 1)) / 10) * 10)::int,
      'lv', (public.farm_cat()->'land_more'->>'lv0')::int + (public.farm_cat()->'land_more'->>'lvstep')::int * (p_k - jsonb_array_length(public.farm_cat()->'land') + 1)) end
$$;

create or replace function public.farm_land_buy() returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); p farm_profile; z jsonb;
begin
  select * into p from farm_profile where employee_id = e for update;
  z := public.farm_land_info(p.land);
  if not public.is_admin() and public.farm_level(p.xp) < (z->>'lv')::int then raise exception 'ต้องเลเวล % ก่อน', z->>'lv'; end if;
  perform public.farm_spend(e, (z->>'cost')::int, 'ซื้อ' || (z->>'n'));
  update farm_profile set land = land + 1 where employee_id = e;
  perform public.farm_add_xp(e, 10 * (p.land + 1));
  return p.land + 1;
end $$;
revoke execute on function public.farm_land_buy() from public, anon;
grant execute on function public.farm_land_buy() to authenticated;
notify pgrst, 'reload schema';
