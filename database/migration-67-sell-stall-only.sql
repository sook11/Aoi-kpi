-- =====================================================================
-- Migration 67: ผลผลิตฟาร์ม (ผัก/ผลไม้/ไข่/นม ฯลฯ) ขายได้เฉพาะที่ "ร้านริมทาง" เท่านั้น
--   farm_sell เดิมย้ายไปเป็น farm_sell_core (เรียกตรงไม่ได้)
--   farm_sell ตัวใหม่: ปลา/ของจากทะเลสาบยังขายได้ตามปกติ · ผลผลิตฟาร์มถูกปฏิเสธ
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ begin
  if to_regprocedure('public.farm_sell_core(text,integer)') is null and to_regprocedure('public.farm_sell(text,integer)') is not null then
    alter function public.farm_sell(text, int) rename to farm_sell_core;
  end if;
end $do$;
revoke execute on function public.farm_sell_core(text, int) from public, anon, authenticated;

create or replace function public.farm_sell(p_item text, p_qty int) returns int
language plpgsql security definer set search_path = public as $$
declare cat jsonb := public.farm_cat();
begin
  if (cat->'crops') ? p_item or (cat->'products') ? p_item or exists (select 1 from jsonb_each(cat->'decor') d where d.value->>'fruit' = p_item) then
    raise exception 'ผลผลิตฟาร์มขายได้ที่ร้านริมทางเท่านั้น';
  end if;
  return public.farm_sell_core(p_item, p_qty);
end $$;
revoke execute on function public.farm_sell(text, int) from public, anon;
grant execute on function public.farm_sell(text, int) to authenticated;
notify pgrst, 'reload schema';
