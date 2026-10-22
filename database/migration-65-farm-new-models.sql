-- =====================================================================
-- Migration 65: ฟาร์ม — ของแต่ง/สัตว์เลี้ยงใหม่จากโมเดล 3D ของผู้ใช้
--   ของแต่ง: ต้นไม้คริสตัลโคมไฟ · ดอกพริมโรส · แปลงหญ้าเขียว · กอหญ้าสูง · ต้นโอ๊กใหญ่ · ต้นไม้ผู้พิทักษ์ · น้ำพุโบราณ
--   สัตว์เลี้ยง: ไก่ทอง · ไก่ขาว · หมูน้อย · ม้าน้ำตาล · นกบลูเจย์
--   (ต้นกล้วย และทานตะวัน ใช้โมเดลใหม่ในหน้าเว็บ ไม่ต้องแก้ฐานข้อมูล)
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := jsonb_set(c, '{decor}', (c->'decor') || '{
   "d_primrose":{"n":"ดอกพริมโรส","e":"🌼","lv":1,"cost":45,"xp":4},
   "d_grass":{"n":"แปลงหญ้าเขียว","e":"🌱","lv":1,"cost":20,"xp":2},
   "d_tuft":{"n":"กอหญ้าสูง","e":"🌾","lv":1,"cost":30,"xp":3},
   "d_oak":{"n":"ต้นโอ๊กใหญ่","e":"🌳","lv":3,"cost":160,"xp":12},
   "d_guardian":{"n":"ต้นไม้ผู้พิทักษ์","e":"🌳","lv":4,"cost":240,"xp":18},
   "d_fountain":{"n":"น้ำพุโบราณ","e":"⛲","lv":6,"cost":700,"xp":45},
   "d_lantern":{"n":"ต้นไม้คริสตัลโคมไฟ","e":"🏮","lv":5,"cost":900,"xp":60},
   "pet_whitehen":{"n":"ไก่ขาว","e":"🐔","lv":2,"cost":160,"xp":12,"pet":"walk"},
   "pet_piglet":{"n":"หมูน้อย","e":"🐷","lv":2,"cost":200,"xp":14,"pet":"walk"},
   "pet_goldhen":{"n":"ไก่ทอง","e":"🐓","lv":3,"cost":350,"xp":25,"pet":"walk"},
   "pet_bluejay":{"n":"นกบลูเจย์","e":"🐦","lv":3,"cost":260,"xp":18,"pet":"bird"},
   "pet_horse2":{"n":"ม้าน้ำตาล","e":"🐎","lv":6,"cost":1200,"xp":70,"pet":"walk"}}'::jsonb);
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;
create or replace function public.farm_is_tree(p_item text) returns boolean
language sql immutable as $$
  select p_item in ('tree','oak','pine2','pine3','birch','sakura','xmastree','palm','lt_oak','lt_oak2','lt_apple','lt_autumn','lt_cherry','d_oak','d_guardian')
      or coalesce(public.farm_cat()->'decor'->p_item ? 'fruit', false)
$$;
notify pgrst, 'reload schema';
