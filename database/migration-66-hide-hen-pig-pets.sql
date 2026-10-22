-- =====================================================================
-- Migration 66: ไก่/หมู เป็นสัตว์ในคอก (ปศุสัตว์) ไม่ใช่สัตว์เลี้ยงเดินเล่น
--   ซ่อน ไก่ทอง · ไก่ขาว · หมูน้อย ออกจากร้านสัตว์เลี้ยง (โมเดลใหม่ไปใช้กับ ไก่/หมู ในคอกแทน)
--   ตัวที่ซื้อไปแล้วยังอยู่ ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := jsonb_set(c, '{decor,pet_goldhen,hide}', 'true'::jsonb);
  c := jsonb_set(c, '{decor,pet_whitehen,hide}', 'true'::jsonb);
  c := jsonb_set(c, '{decor,pet_piglet,hide}', 'true'::jsonb);
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;
-- กันซื้อของที่ซ่อนผ่าน API
create or replace function public.farm_hidden_guard() returns trigger language plpgsql as $$
begin
  if coalesce((public.farm_cat()->'decor'->new.item->>'hide')::boolean, false) then raise exception 'สินค้านี้ไม่ขายแล้ว'; end if;
  return new;
end $$;
drop trigger if exists farm_hidden_guard on public.farm_decor;
create trigger farm_hidden_guard before insert on public.farm_decor for each row execute function public.farm_hidden_guard();
notify pgrst, 'reload schema';
