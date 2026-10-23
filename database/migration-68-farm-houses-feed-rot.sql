-- =====================================================================
-- Migration 68: ฟาร์ม — ของเน่าที่ร้านริมทาง · บ้านสัตว์ · เครื่องทำอาหารสัตว์
--   1) ร้านริมทาง: ของที่วางขายครบ 24 ชม. แล้วยังไม่มีคนซื้อ = เน่า → ซื้อไม่ได้ ไม่โชว์ในตลาด
--      เจ้าของต้องกด "ทิ้ง" เอง (ไม่ได้ของคืน) ช่องถึงจะว่าง
--   2) บ้านสัตว์: ต้องมีบ้านของประเภทนั้นก่อนถึงซื้อสัตว์ได้
--      ปศุสัตว์: เล้าไก่ · คอกวัว · เล้าหมู · คอกแกะ
--      สัตว์เลี้ยง: บ้านหมา · บ้านแมว/สัตว์เล็ก · บ้านนก · คอกม้า · บ่อน้ำสัตว์ปีก
--      (สัตว์ที่มีอยู่แล้วยังอยู่ครบ — บังคับเฉพาะการซื้อใหม่)
--   3) เครื่องทำอาหารสัตว์: ใช้ผลผลิตทำ "ถุงอาหาร" · ให้อาหารสัตว์ต้องใช้ถุงอาหาร (ไม่ใช้เหรียญแล้ว)
--      1 ถุง = ให้อาหารสัตว์ชนิดนั้นทั้งคอก 1 รอบ · แจกถุงตั้งต้นให้ทุกฟาร์มที่มีสัตว์ ชนิดละ 3 ถุง
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================

-- ---------- แค็ตตาล็อก ----------
do $do$ declare c jsonb := public.farm_cat(); k text; v jsonb; grp text; begin
  c := jsonb_set(c, '{products}', (c->'products') || '{
   "feed_chicken":{"n":"ถุงอาหารไก่","e":"🌾","sell":4,"feed":"chicken"},
   "feed_cow":{"n":"ถุงอาหารวัว","e":"🌿","sell":10,"feed":"cow"},
   "feed_pig":{"n":"ถุงอาหารหมู","e":"🥔","sell":15,"feed":"pig"},
   "feed_sheep":{"n":"ถุงอาหารแกะ","e":"🍀","sell":20,"feed":"sheep"}}'::jsonb);
  c := jsonb_set(c, '{machines}', coalesce(c->'machines', '{}'::jsonb) || '{
   "feedmill":{"e":"🥣","n":"เครื่องทำอาหารสัตว์","lv":2,"cost":120,"recipes":{
     "feed_chicken":{"in":{"wheat":2},"xp":1,"min":3},
     "feed_cow":{"in":{"wheat":2,"corn":1},"xp":2,"min":5},
     "feed_pig":{"in":{"corn":2,"carrot":1},"xp":3,"min":8},
     "feed_sheep":{"in":{"wheat":2,"corn":2},"xp":4,"min":10}}}}'::jsonb);
  c := jsonb_set(c, '{decor}', (c->'decor') || '{
   "h_coop":{"n":"เล้าไก่","e":"🛖","lv":2,"cost":80,"xp":6,"house":"chicken"},
   "h_cowshed":{"n":"คอกวัว","e":"🏚️","lv":4,"cost":200,"xp":12,"house":"cow"},
   "h_sty":{"n":"เล้าหมู","e":"🏠","lv":6,"cost":320,"xp":18,"house":"pig"},
   "h_sheepfold":{"n":"คอกแกะ","e":"🏡","lv":8,"cost":480,"xp":24,"house":"sheep"},
   "h_doghouse":{"n":"บ้านหมา","e":"🐶","lv":2,"cost":100,"xp":6,"house":"dog"},
   "h_cathouse":{"n":"บ้านแมว & สัตว์เล็ก","e":"🐱","lv":2,"cost":100,"xp":6,"house":"cat"},
   "h_birdhouse":{"n":"บ้านนก","e":"🐦","lv":2,"cost":120,"xp":7,"house":"bird"},
   "h_stable":{"n":"คอกม้า","e":"🐴","lv":4,"cost":300,"xp":15,"house":"horse"},
   "h_pond":{"n":"บ่อน้ำสัตว์ปีก","e":"🦢","lv":5,"cost":260,"xp":14,"house":"water"}}'::jsonb);
  -- สัตว์เลี้ยงแต่ละตัวต้องใช้บ้านแบบไหน
  for k, v in select key, value from jsonb_each(c->'decor') where value ? 'pet' loop
    grp := case
      when k in ('horse','whorse','donkey','alpaca','deer','pet_pony','pet_horse2') then 'horse'
      when k in ('dog','husky','fox') then 'dog'
      when v->>'pet' in ('swim','wade') then 'water'
      when v->>'pet' = 'bird' or k in ('pet_chick','pet_redhen','pet_goldhen','pet_whitehen','peacock') then 'bird'
      else 'cat' end;
    c := jsonb_set(c, array['decor', k, 'home'], to_jsonb(grp));
  end loop;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

-- ---------- บ้านสัตว์ ----------
create or replace function public.farm_has_house(p_emp uuid, p_grp text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_grp is null or exists (select 1 from farm_decor d where d.employee_id = p_emp and public.farm_cat()->'decor'->d.item->>'house' = p_grp)
$$;
revoke execute on function public.farm_has_house(uuid, text) from public, anon, authenticated;

do $do$ begin
  if to_regprocedure('public.farm_buy_animal_core(text)') is null then alter function public.farm_buy_animal(text) rename to farm_buy_animal_core; end if;
  if to_regprocedure('public.farm_buy_decor_core(text)') is null then alter function public.farm_buy_decor(text) rename to farm_buy_decor_core; end if;
end $do$;
revoke execute on function public.farm_buy_animal_core(text), public.farm_buy_decor_core(text) from public, anon, authenticated;

create or replace function public.farm_house_name(p_grp text) returns text language sql immutable as $$
  select coalesce((select value->>'n' from jsonb_each(public.farm_cat()->'decor') where value->>'house' = p_grp limit 1), 'บ้านสัตว์')
$$;

create or replace function public.farm_buy_animal(p_animal text) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me();
begin
  if not public.farm_has_house(e, p_animal) then raise exception 'ต้องสร้าง % ก่อน ถึงจะเลี้ยงได้', public.farm_house_name(p_animal); end if;
  perform public.farm_buy_animal_core(p_animal);
  -- แถมถุงอาหาร 1 ถุงต่อการซื้อ
  if public.farm_cat()->'products' ? ('feed_' || p_animal) then perform public.farm_add_item(e, 'feed_' || p_animal, 1); end if;
end $$;

create or replace function public.farm_buy_decor(p_item text) returns boolean
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); c jsonb := public.farm_cat()->'decor'->p_item;
begin
  if c ? 'house' and exists (select 1 from farm_decor where employee_id = e and item = p_item) then raise exception '% มีแล้ว (มีได้ 1 หลัง)', c->>'n'; end if;
  if c ? 'pet' and not public.farm_has_house(e, c->>'home') then raise exception 'ต้องสร้าง % ก่อน ถึงจะเลี้ยง % ได้', public.farm_house_name(c->>'home'), c->>'n'; end if;
  return public.farm_buy_decor_core(p_item);
end $$;

revoke execute on function public.farm_buy_animal(text), public.farm_buy_decor(text), public.farm_house_name(text) from public, anon;
grant execute on function public.farm_buy_animal(text), public.farm_buy_decor(text) to authenticated;

-- ---------- ให้อาหารด้วยถุงอาหาร (1 ถุง = ทั้งคอกของชนิดนั้น 1 รอบ) ----------
create or replace function public.farm_feed(p_id uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); cat jsonb := public.farm_cat()->'animals'; a text; have int; n int := 0; m int; miss text := null;
begin
  if p_id is not null then
    select animal into a from farm_animals where id = p_id and employee_id = e;
    if a is null then raise exception 'ไม่พบสัตว์ตัวนี้'; end if;
    if not exists (select 1 from farm_animals where id = p_id and ready_at is null) then raise exception 'ตัวนี้กินอิ่มแล้ว'; end if;
  end if;
  for a in select distinct animal from farm_animals where employee_id = e and ready_at is null and (p_id is null or id = p_id) order by 1 loop
    select qty into have from farm_items where employee_id = e and item = 'feed_' || a for update;
    if coalesce(have, 0) < 1 then miss := coalesce(miss || ', ', '') || coalesce(public.farm_cat()->'products'->('feed_' || a)->>'n', 'ถุงอาหาร' || a); continue; end if;
    update farm_items set qty = qty - 1 where employee_id = e and item = 'feed_' || a;
    with u as (update farm_animals x set ready_at = now() + make_interval(mins => (cat->x.animal->>'min')::int)
               where x.employee_id = e and x.animal = a and x.ready_at is null returning 1) select count(*) into m from u;
    n := n + m;
  end loop;
  if n = 0 then
    if miss is not null then raise exception 'ไม่มี % — ทำที่ 🥣 เครื่องทำอาหารสัตว์', miss; end if;
    raise exception 'ทุกตัวกินอิ่มแล้ว';
  end if;
  return n;
end $$;
revoke execute on function public.farm_feed(uuid) from public, anon;
grant execute on function public.farm_feed(uuid) to authenticated;

-- ถุงอาหารตั้งต้น: ทุกฟาร์มที่มีสัตว์ ชนิดละ 3 ถุง
insert into farm_items (employee_id, item, qty)
select distinct employee_id, 'feed_' || animal, 3 from farm_animals
on conflict (employee_id, item) do update set qty = farm_items.qty + 3;

-- ---------- ร้านริมทาง: ของเน่าเมื่อครบ 24 ชม. ----------
create or replace function public.farm_stall_is_rotten(p_created timestamptz, p_buyer uuid) returns boolean
language sql stable as $$ select p_buyer is null and p_created < now() - interval '24 hours' $$;

do $do$ begin
  if to_regprocedure('public.farm_stall_buy_core(bigint)') is null then alter function public.farm_stall_buy(bigint) rename to farm_stall_buy_core; end if;
  if to_regprocedure('public.farm_stall_cancel_core(bigint)') is null then alter function public.farm_stall_cancel(bigint) rename to farm_stall_cancel_core; end if;
  if to_regprocedure('public.farm_stall_market_core()') is null then alter function public.farm_stall_market() rename to farm_stall_market_core; end if;
end $do$;
revoke execute on function public.farm_stall_buy_core(bigint), public.farm_stall_cancel_core(bigint), public.farm_stall_market_core() from public, anon, authenticated;

create or replace function public.farm_stall_buy(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from farm_stall where id = p_id and public.farm_stall_is_rotten(created_at, buyer_id)) then raise exception 'ของชิ้นนี้เน่าแล้ว 🤢 ซื้อไม่ได้'; end if;
  return public.farm_stall_buy_core(p_id);
end $$;

create or replace function public.farm_stall_cancel(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from farm_stall where id = p_id and public.farm_stall_is_rotten(created_at, buyer_id)) then raise exception 'ของเน่าแล้ว เก็บคืนไม่ได้ — กด 🗑️ ทิ้ง'; end if;
  perform public.farm_stall_cancel_core(p_id);
end $$;

-- ทิ้งของเน่า (ไม่ได้ของคืน) → ช่องว่าง
create or replace function public.farm_stall_discard(p_id bigint default null) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); n int;
begin
  with d as (delete from farm_stall where seller_id = e and (p_id is null or id = p_id) and public.farm_stall_is_rotten(created_at, buyer_id) returning 1) select count(*) into n from d;
  if n = 0 then raise exception 'ไม่มีของเน่าให้ทิ้ง'; end if;
  return n;
end $$;

create or replace function public.farm_stall_market() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((select jsonb_agg(x) from jsonb_array_elements(public.farm_stall_market_core()) x
    where not exists (select 1 from farm_stall s where s.id = (x->>'id')::bigint and public.farm_stall_is_rotten(s.created_at, s.buyer_id))), '[]');
end $$;

-- เวลาที่วางขาย (ใช้นับถอยหลัง/แสดงของเน่า) ของร้านตัวเองหรือร้านเพื่อน
create or replace function public.farm_stall_times(p_emp uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(id::text, created_at), '{}') from farm_stall
   where seller_id = coalesce(p_emp, public.my_employee_id()) and buyer_id is null and public.my_employee_id() is not null
$$;

revoke execute on function public.farm_stall_buy(bigint), public.farm_stall_cancel(bigint), public.farm_stall_discard(bigint), public.farm_stall_market(), public.farm_stall_times(uuid) from public, anon;
grant execute on function public.farm_stall_buy(bigint), public.farm_stall_cancel(bigint), public.farm_stall_discard(bigint), public.farm_stall_market(), public.farm_stall_times(uuid) to authenticated;

notify pgrst, 'reload schema';
