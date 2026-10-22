-- =====================================================================
-- Migration 63: นกยูง (สัตว์เลี้ยง) — โมเดล 3D ใหม่ + ราคาแพงมาก
--   ราคา 600 → 12,000 เหรียญ · ปลดล็อกเลเวล 8 · XP 150 · เลี้ยงได้สูงสุด 2 ตัวเหมือนเดิม
--   ไม่ลบข้อมูลใด ๆ (คนที่ซื้อไปแล้วยังมีนกยูงอยู่)
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := jsonb_set(c, '{decor,peacock}', '{"n":"นกยูงรำแพน","e":"🦚","lv":8,"cost":12000,"xp":150,"pet":"walk"}'::jsonb);
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;
notify pgrst, 'reload schema';
