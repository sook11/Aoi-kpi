-- =====================================================================
-- Migration 73: จัดผังฟาร์มใหม่ได้ (ย้ายอาคาร คอก แปลงผัก รั้ว ทางเดิน) — เก็บผังต่อฟาร์ม
--   ย้ายของแต่งไปวางบนที่ดินขยาย (ลานของแต่ง) ได้ · ไม่ลบข้อมูลใด ๆ
-- =====================================================================
alter table public.farm_profile add column if not exists layout jsonb not null default '{}'::jsonb;

create or replace function public.farm_layout_of(p_emp uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select layout from farm_profile where employee_id = coalesce(p_emp, public.my_employee_id())), '{}'::jsonb) where public.my_employee_id() is not null
$$;

create or replace function public.farm_layout_save(p_layout jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); k text; v jsonb;
begin
  if p_layout is null or jsonb_typeof(p_layout) <> 'object' then raise exception 'ผังไม่ถูกต้อง'; end if;
  if length(p_layout::text) > 30000 then raise exception 'ผังใหญ่เกินไป'; end if;
  for k, v in select key, value from jsonb_each(coalesce(p_layout->'m', '{}')) loop
    if jsonb_typeof(v) <> 'array' or abs((v->>0)::numeric) > 40 or abs((v->>1)::numeric) > 40 then raise exception 'ตำแหน่งไม่ถูกต้อง'; end if;
  end loop;
  update farm_profile set layout = jsonb_build_object('m', coalesce(p_layout->'m', '{}'), 'h', coalesce(p_layout->'h', '{}')) where employee_id = e;
end $$;

-- ย้ายของแต่ง: วางในฟาร์ม หรือบนที่ดินขยายที่ตั้งเป็น "ลานของแต่ง"
create or replace function public.farm_move_decor(p_id uuid, p_x int, p_y int, p_ox int default null, p_oy int default null) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.farm_me(); d farm_decor; o farm_decor; okp boolean;
begin
  select * into d from farm_decor where id = p_id and employee_id = e and not stored for update;
  if not found then raise exception 'ไม่พบของแต่งชิ้นนี้'; end if;
  okp := exists (select 1 from farm_parcels f, public.farm_parcel_def(f.pid) x where f.employee_id = e and f.use = 'decor'
          and p_x >= (x->>'x')::numeric and p_x < (x->>'x')::numeric + (x->>'w')::int and p_y >= (x->>'y')::numeric and p_y < (x->>'y')::numeric + (x->>'h')::int);
  if not okp and (p_x < 0 or p_x > 11 or p_y < 0 or p_y > 11) then raise exception 'วางนอกฟาร์มไม่ได้'; end if;
  select * into o from farm_decor where employee_id = e and gx = p_x and gy = p_y and id <> p_id and not stored limit 1;
  if found then update farm_decor set gx = coalesce(d.gx, p_ox), gy = coalesce(d.gy, p_oy) where id = o.id; end if;
  update farm_decor set gx = p_x, gy = p_y where id = p_id;
end $$;

revoke execute on function public.farm_layout_of(uuid), public.farm_layout_save(jsonb), public.farm_move_decor(uuid,int,int,int,int) from public, anon;
grant execute on function public.farm_layout_of(uuid), public.farm_layout_save(jsonb), public.farm_move_decor(uuid,int,int,int,int) to authenticated;
notify pgrst, 'reload schema';
