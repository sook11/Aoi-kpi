-- =====================================================================
-- Migration 64: ของแต่งฟาร์ม — ต้นสนใหญ่ (โมเดล 3D ใหม่)
--   ต้นมะพร้าว (ประดับ) และต้นมะพร้าว (ปลูกเก็บผล) ใช้โมเดลใหม่ในหน้าเว็บ ไม่ต้องแก้ฐานข้อมูล
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := jsonb_set(c, '{decor,pine3}', '{"n":"ต้นสนใหญ่","e":"🌲","lv":2,"cost":150,"xp":10}'::jsonb);
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;
-- ต้นสนใหญ่ตัดได้เหมือนต้นไม้อื่น
create or replace function public.farm_is_tree(p_item text) returns boolean
language sql immutable as $$
  select p_item in ('tree','oak','pine2','pine3','birch','sakura','xmastree','palm','lt_oak','lt_oak2','lt_apple','lt_autumn','lt_cherry')
      or coalesce(public.farm_cat()->'decor'->p_item ? 'fruit', false)
$$;
notify pgrst, 'reload schema';
