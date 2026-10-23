-- =====================================================================
-- Migration 69: เล้าไก่/คอกสัตว์ — 1 เล้า/คอก เลี้ยงได้ 5 ตัว (มีแค่ไก่ที่เป็นเล้า · วัว หมู แกะ เป็นคอก) · สร้างเล้าเพิ่มได้หลายหลัง · ซื้อพื้นที่คอกเพิ่มได้ไม่จำกัดตามเลเวล
--   • ไก่/วัว/หมู/แกะ: จำนวนที่เลี้ยงได้ = 5 × จำนวนเล้าของชนิดนั้น
--   • เล้าหลังแรกของแต่ละชนิดตั้งในคอกเดิม · หลังที่ 2 ขึ้นไปต้องมี "พื้นที่คอก" ว่าง
--   • พื้นที่คอก: ซื้อได้ 1 ช่องทุก ๆ 5 เลเวล (เลเวล 5 = 1 ช่อง, 10 = 2 ช่อง, …) ราคาเพิ่มขึ้นทีละ 300
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================
alter table public.farm_profile add column if not exists pens int not null default 0;

do $do$ declare c jsonb := public.farm_cat(); begin
  c := c || jsonb_build_object('per_house', 5, 'max_per_animal', 9999, 'pen_every', 5, 'pen_cost', 300);
  -- มีแค่ไก่ที่เป็น "เล้า" · วัว/หมู/แกะ เป็น "คอก"
  c := jsonb_set(c, '{decor,h_sty}', (c->'decor'->'h_sty') || '{"n":"คอกหมู","e":"🐖"}'::jsonb);
  c := jsonb_set(c, '{decor,h_cowshed}', (c->'decor'->'h_cowshed') || '{"n":"คอกวัว","e":"🐄"}'::jsonb);
  c := jsonb_set(c, '{decor,h_sheepfold}', (c->'decor'->'h_sheepfold') || '{"n":"คอกแกะ","e":"🐑"}'::jsonb);
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

-- จำนวนเล้าของชนิดนั้น
create or replace function public.farm_house_count(p_emp uuid, p_grp text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from farm_decor d where d.employee_id = p_emp and public.farm_cat()->'decor'->d.item->>'house' = p_grp
$$;
-- พื้นที่คอกที่ใช้ไป = เล้าที่เกินหลังแรกของแต่ละชนิด
create or replace function public.farm_pen_used(p_emp uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(0, n - 1)), 0)::int from (
    select public.farm_cat()->'decor'->d.item->>'house' grp, count(*) n from farm_decor d
     where d.employee_id = p_emp and (public.farm_cat()->'animals') ? (public.farm_cat()->'decor'->d.item->>'house') group by 1) z
$$;
revoke execute on function public.farm_house_count(uuid, text), public.farm_pen_used(uuid) from public, anon, authenticated;

create or replace function public.farm_pen_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e uuid := public.my_employee_id(); p farm_profile; c jsonb := public.farm_cat(); mx int; every int := coalesce((c->>'pen_every')::int, 5);
begin
  if e is null then return null; end if;
  select * into p from farm_profile where employee_id = e;
  if not found then return null; end if;
  mx := public.farm_level(p.xp) / every;
  return jsonb_build_object('pens', p.pens, 'used', public.farm_pen_used(e), 'max', mx, 'per_house', coalesce((c->>'per_house')::int, 5),
    'next_cost', coalesce((c->>'pen_cost')::int, 300) * (p.pens + 1), 'next_level', case when p.pens >= mx then (p.pens + 1) * every end);
end $$;

create or replace function public.farm_pen_buy() returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); p farm_profile; c jsonb := public.farm_cat(); every int := coalesce((c->>'pen_every')::int, 5);
begin
  select * into p from farm_profile where employee_id = e for update;
  if p.pens >= public.farm_level(p.xp) / every then raise exception 'ต้องเลเวล % ก่อน ถึงจะซื้อพื้นที่คอกช่องถัดไปได้', (p.pens + 1) * every; end if;
  perform public.farm_spend(e, coalesce((c->>'pen_cost')::int, 300) * (p.pens + 1), 'ซื้อพื้นที่คอกสัตว์');
  update farm_profile set pens = pens + 1 where employee_id = e;
  return p.pens + 1;
end $$;

create or replace function public.farm_buy_decor(p_item text) returns boolean
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); cat jsonb := public.farm_cat(); c jsonb := cat->'decor'->p_item; lv boolean; pens int;
begin
  if c ? 'house' then
    lv := (cat->'animals') ? (c->>'house');
    if not lv and exists (select 1 from farm_decor where employee_id = e and item = p_item) then raise exception '% มีแล้ว (มีได้ 1 หลัง)', c->>'n'; end if;
    if lv and public.farm_house_count(e, c->>'house') >= 1 then
      select farm_profile.pens into pens from farm_profile where employee_id = e;
      if public.farm_pen_used(e) + 1 > coalesce(pens, 0) then raise exception 'พื้นที่คอกเต็ม — ซื้อพื้นที่คอกเพิ่มก่อน (มี % ช่อง ใช้ไป %)', coalesce(pens, 0), public.farm_pen_used(e); end if;
    end if;
  end if;
  if c ? 'pet' and not public.farm_has_house(e, c->>'home') then raise exception 'ต้องสร้าง % ก่อน ถึงจะเลี้ยง % ได้', public.farm_house_name(c->>'home'), c->>'n'; end if;
  return public.farm_buy_decor_core(p_item);
end $$;

create or replace function public.farm_buy_animal(p_animal text) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); h int := public.farm_house_count(e, p_animal); per int := coalesce((public.farm_cat()->>'per_house')::int, 5); n int;
begin
  if h = 0 then raise exception 'ต้องสร้าง % ก่อน ถึงจะเลี้ยงได้', public.farm_house_name(p_animal); end if;
  select count(*) into n from farm_animals where employee_id = e and animal = p_animal;
  if n >= h * per then raise exception '% เต็มแล้ว (% / % ตัว) — สร้าง% เพิ่ม', public.farm_house_name(p_animal), n, h * per, public.farm_house_name(p_animal); end if;
  perform public.farm_buy_animal_core(p_animal);
  if public.farm_cat()->'products' ? ('feed_' || p_animal) then perform public.farm_add_item(e, 'feed_' || p_animal, 1); end if;
end $$;

revoke execute on function public.farm_pen_info(), public.farm_pen_buy(), public.farm_buy_decor(text), public.farm_buy_animal(text) from public, anon;
grant execute on function public.farm_pen_info(), public.farm_pen_buy(), public.farm_buy_decor(text), public.farm_buy_animal(text) to authenticated;
notify pgrst, 'reload schema';
