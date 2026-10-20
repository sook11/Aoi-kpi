-- =====================================================================
-- Migration 50: ฟาร์ม — สัตว์เลี้ยง 3D ชุดใหม่ + ต้นไม้ใบดก + บันทึกคนมาเยี่ยม + ป้ายโฆษณา
--   1) แค็ตตาล็อก: สัตว์เลี้ยงใหม่ 8 ชนิด + ต้นไม้ใบดก 5 แบบ (ของแต่ง)
--   2) farm_visits: บันทึกว่าใครมาเยี่ยมฟาร์มไหนวันนี้ → เจ้าของเห็นตัวละครเพื่อนเดินในฟาร์ม
--   3) farm_visitors_of: ดูลูกค้าที่ยืนรอหน้าฟาร์มเพื่อน (อ่านอย่างเดียว)
--   4) ป้ายโฆษณา: Admin ใส่รูป/วิดีโอ ให้ "ทุกบ้าน" หรือ "เฉพาะบ้าน" (ไฟล์อยู่ใน Storage: farm-ads)
--   6) รถส่งของแบบใหม่ 5 คัน ซื้อได้เมื่อถึงเลเวล (ราคาสูง) · เลือกคันที่ใช้ได้
--   5) ตัดต้นไม้ด้วยขวานได้ทุกต้น (ต้นไม้ผลที่ยังไม่ตาย + ต้นไม้ประดับ) ไม่ต้องรอให้ตาย
--   ไม่ลบข้อมูลใด ๆ (นอกจากต้นไม้ที่ผู้เล่นสั่งตัดเอง)
-- =====================================================================
do $do$ declare c jsonb := public.farm_cat(); begin
  c := jsonb_set(c, '{decor}', (c->'decor') || '{
   "pet_sparrow":{"n":"นกกระจอก","e":"🐦","lv":1,"cost":80,"xp":6,"pet":"bird"},
   "pet_chick":{"n":"ลูกเจี๊ยบ","e":"🐤","lv":1,"cost":60,"xp":5,"pet":"walk"},
   "pet_redhen":{"n":"แม่ไก่แดง","e":"🐔","lv":2,"cost":100,"xp":8,"pet":"walk"},
   "pet_bluebird":{"n":"นกสีฟ้า","e":"🐦","lv":2,"cost":120,"xp":9,"pet":"bird"},
   "pet_greenbird":{"n":"นกสีเขียว","e":"🐦","lv":2,"cost":120,"xp":9,"pet":"bird"},
   "pet_greybird":{"n":"นกพิราบน้อย","e":"🕊️","lv":3,"cost":140,"xp":11,"pet":"bird"},
   "pet_bee":{"n":"ผึ้งน้อย","e":"🐝","lv":3,"cost":150,"xp":12,"pet":"bird"},
   "pet_pony":{"n":"ม้าแคระ","e":"🐴","lv":4,"cost":260,"xp":20,"pet":"walk"},
   "lt_oak":{"n":"ต้นโอ๊กใบดก","e":"🌳","lv":1,"cost":80,"xp":6},
   "lt_oak2":{"n":"ต้นไม้ใหญ่ใบดก","e":"🌳","lv":2,"cost":120,"xp":9},
   "lt_apple":{"n":"ต้นไม้ผลแดง (ประดับ)","e":"🌳","lv":2,"cost":120,"xp":9},
   "lt_autumn":{"n":"ต้นเมเปิลใบส้ม","e":"🍁","lv":3,"cost":180,"xp":14},
   "lt_cherry":{"n":"ต้นซากุระชมพู","e":"🌸","lv":3,"cost":200,"xp":16}}'::jsonb);
  c := c || '{"vehicles":{
   "v_police":{"n":"รถตำรวจ","e":"🚓","lv":5,"cost":1500,"xp":30},
   "v_sport":{"n":"รถสปอร์ตสีส้ม","e":"🏎️","lv":7,"cost":2500,"xp":45},
   "v_f1":{"n":"รถแข่ง F1","e":"🏎️","lv":9,"cost":4000,"xp":60},
   "v_classic":{"n":"รถคลาสสิกสีแดง","e":"🚗","lv":11,"cost":6000,"xp":80},
   "v_roadster":{"n":"รถเปิดประทุนวินเทจ","e":"🚘","lv":13,"cost":8000,"xp":100}}}'::jsonb;
  execute 'create or replace function public.farm_cat() returns jsonb language sql immutable as $f$ select ' || quote_literal(c::text) || '::jsonb $f$';
end $do$;

-- ---------- คนมาเยี่ยมฟาร์ม ----------
create table if not exists public.farm_visits (
  visitor_id uuid not null references public.employees(id) on delete cascade,
  owner_id   uuid not null references public.employees(id) on delete cascade,
  day        date not null,
  at         timestamptz not null default now(),
  primary key (visitor_id, owner_id, day)
);
create index if not exists farm_visits_owner_idx on public.farm_visits (owner_id, day);
alter table public.farm_visits enable row level security;
revoke all on public.farm_visits from anon, public, authenticated;

create or replace function public.farm_visit(p_owner uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id();
begin
  if me is null or p_owner is null or p_owner = me then return; end if;
  insert into farm_visits (visitor_id, owner_id, day) values (me, p_owner, public.farm_today())
  on conflict (visitor_id, owner_id, day) do update set at = now();
end $$;

-- ใครมาเยี่ยมฟาร์มนี้วันนี้ (ล่าสุด 6 คน) — ใช้แสดงตัวละครเดินในฟาร์ม
create or replace function public.farm_guests(p_emp uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', coalesce(nullif(x.display_name, ''), x.employee_no), 'admin', x.role = 'admin', 'at', v.at) order by v.at desc), '[]')
  from (select * from farm_visits where owner_id = coalesce(p_emp, public.my_employee_id()) and day = public.farm_today() order by at desc limit 6) v
  join employees x on x.id = v.visitor_id
  where public.my_employee_id() is not null
$$;

-- ลูกค้าที่ยืนรอหน้าฟาร์มเพื่อน (ไม่ส่งราคา/ของที่ขอ)
create or replace function public.farm_visitors_of(p_emp uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('slot', slot, 'npc', npc, 'arrive_at', arrive_at) order by slot), '[]')
  from farm_visitors where employee_id = p_emp and arrive_at <= now() and public.my_employee_id() is not null
$$;

-- ---------- ป้ายโฆษณา ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('farm-ads', 'farm-ads', false, 31457280,
        array['video/mp4','video/webm','video/quicktime','image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do nothing;
drop policy if exists farm_ads_read on storage.objects;
drop policy if exists farm_ads_upload on storage.objects;
drop policy if exists farm_ads_delete on storage.objects;
create policy farm_ads_read on storage.objects for select to authenticated
  using (bucket_id = 'farm-ads' and public.my_employee_id() is not null);
create policy farm_ads_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'farm-ads' and public.is_admin());
create policy farm_ads_delete on storage.objects for delete to authenticated
  using (bucket_id = 'farm-ads' and public.is_admin());

create table if not exists public.farm_ads (
  id          bigserial primary key,
  target_id   uuid references public.employees(id) on delete cascade,   -- null = ทุกบ้าน
  media_path  text not null,
  media_type  text not null check (media_type in ('image', 'video')),
  caption     text not null default '',
  created_by  uuid references public.employees(id) on delete set null,
  created_at  timestamptz not null default now(),
  active      boolean not null default true
);
create index if not exists farm_ads_target_idx on public.farm_ads (target_id, active);
alter table public.farm_ads enable row level security;
revoke all on public.farm_ads from anon, public, authenticated;

-- ป้ายของบ้านนี้: ถ้ามีป้ายเฉพาะบ้าน ใช้อันนั้น ไม่งั้นใช้ป้ายทุกบ้าน
create or replace function public.farm_ad_get(p_emp uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.my_employee_id() is null then null else
    (select jsonb_build_object('id', a.id, 'path', a.media_path, 'type', a.media_type, 'caption', a.caption, 'scope', case when a.target_id is null then 'all' else 'farm' end, 'at', a.created_at)
     from farm_ads a where a.active and (a.target_id = coalesce(p_emp, public.my_employee_id()) or a.target_id is null)
     order by (a.target_id is null), a.created_at desc limit 1) end
$$;

create or replace function public.farm_ad_set(p_target uuid, p_path text, p_type text, p_caption text default '') returns bigint
language plpgsql security definer set search_path = public as $$
declare r bigint;
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin เท่านั้น'; end if;
  if p_path is null or p_path = '' then raise exception 'ไม่มีไฟล์'; end if;
  update farm_ads set active = false where active and target_id is not distinct from p_target;
  insert into farm_ads (target_id, media_path, media_type, caption, created_by) values (p_target, p_path, p_type, coalesce(p_caption, ''), public.my_employee_id()) returning id into r;
  return r;
end $$;

-- ปิดป้าย (p_target = null → ปิดป้ายทุกบ้าน)
create or replace function public.farm_ad_clear(p_target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin เท่านั้น'; end if;
  update farm_ads set active = false where active and target_id is not distinct from p_target;
end $$;

-- ---------- ตัดต้นไม้ได้ทุกต้น ----------
create or replace function public.farm_is_tree(p_item text) returns boolean
language sql immutable as $$
  select p_item in ('tree','oak','pine2','birch','sakura','xmastree','palm','lt_oak','lt_oak2','lt_apple','lt_autumn','lt_cherry')
      or coalesce(public.farm_cat()->'decor'->p_item ? 'fruit', false)
$$;
create or replace function public.farm_tree_chop(p_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); d farm_decor; c jsonb; have int; cn int;
begin
  select * into d from farm_decor where id = p_id and employee_id = e for update;
  if not found then raise exception 'ไม่พบต้นไม้นี้'; end if;
  if not public.farm_is_tree(d.item) then raise exception 'ตัดได้เฉพาะต้นไม้'; end if;
  c := public.farm_cat()->'decor'->d.item;
  select qty into have from farm_items where employee_id = e and item = 'axe' for update;
  if coalesce(have, 0) < 1 then raise exception 'ต้องมี 🪓 ขวาน — ซื้อในร้านค้า หรือหาจากกล่องสุ่มในฟาร์มเพื่อนบ้าน'; end if;
  update farm_items set qty = qty - 1 where employee_id = e and item = 'axe';
  delete from farm_decor where id = p_id;
  cn := 5 + (coalesce((c->>'cost')::int, 0) / 10);
  insert into farm_ledger (employee_id, delta, reason) values (e, cn, 'ตัดต้นไม้ ' || coalesce(c->>'n', d.item));
  perform public.farm_add_xp(e, 5);
  return cn;
end $$;

-- ---------- รถส่งของ ----------
alter table public.farm_profile add column if not exists truck text;
create table if not exists public.farm_vehicles (
  employee_id uuid not null references public.employees(id) on delete cascade,
  item        text not null,
  at          timestamptz not null default now(),
  primary key (employee_id, item)
);
alter table public.farm_vehicles enable row level security;
revoke all on public.farm_vehicles from anon, public, authenticated;

create or replace function public.farm_vehicle_info(p_emp uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.my_employee_id() is null then null else jsonb_build_object(
    'active', (select truck from farm_profile where employee_id = coalesce(p_emp, public.my_employee_id())),
    'owned', coalesce((select jsonb_agg(item order by at) from farm_vehicles where employee_id = coalesce(p_emp, public.my_employee_id())), '[]')) end
$$;
create or replace function public.farm_vehicle_buy(p_item text) returns text
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); v jsonb := public.farm_cat()->'vehicles'->p_item; p farm_profile;
begin
  if v is null then raise exception 'ไม่มีรถคันนี้'; end if;
  select * into p from farm_profile where employee_id = e for update;
  if not public.is_admin() and public.farm_level(p.xp) < (v->>'lv')::int then raise exception 'ต้องเลเวล % ก่อน', v->>'lv'; end if;
  if exists (select 1 from farm_vehicles where employee_id = e and item = p_item) then raise exception 'มีรถคันนี้แล้ว'; end if;
  perform public.farm_spend(e, (v->>'cost')::int, 'ซื้อ' || (v->>'n'));
  insert into farm_vehicles (employee_id, item) values (e, p_item);
  update farm_profile set truck = p_item where employee_id = e;
  perform public.farm_add_xp(e, coalesce((v->>'xp')::int, 0));
  return p_item;
end $$;
create or replace function public.farm_vehicle_use(p_item text) returns text
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me();
begin
  if p_item is not null and not exists (select 1 from farm_vehicles where employee_id = e and item = p_item) then raise exception 'ยังไม่มีรถคันนี้'; end if;
  update farm_profile set truck = p_item where employee_id = e;
  return p_item;
end $$;
revoke execute on function public.farm_vehicle_info(uuid), public.farm_vehicle_buy(text), public.farm_vehicle_use(text) from public, anon;
grant execute on function public.farm_vehicle_info(uuid), public.farm_vehicle_buy(text), public.farm_vehicle_use(text) to authenticated;

revoke execute on function public.farm_visit(uuid), public.farm_guests(uuid), public.farm_visitors_of(uuid), public.farm_ad_get(uuid), public.farm_ad_set(uuid, text, text, text), public.farm_ad_clear(uuid) from public, anon;
grant execute on function public.farm_visit(uuid), public.farm_guests(uuid), public.farm_visitors_of(uuid), public.farm_ad_get(uuid), public.farm_ad_set(uuid, text, text, text), public.farm_ad_clear(uuid) to authenticated;
notify pgrst, 'reload schema';
