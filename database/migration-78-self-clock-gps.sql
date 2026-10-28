-- =====================================================================
-- อัปเดต 159: ลงเวลาหัวหน้างาน — ตรวจ GPS ที่ตั้งโรงงาน + Admin แก้เวลา (ลืมกด)
--   app_settings.factory_geo = {lat, lng, radius}  (Admin ตั้งจากหน้า OT)
--   att_self_clock(kind, lat, lng, acc) : ต้องอยู่ในรัศมีโรงงาน (ถ้าตั้งค่าไว้) · เก็บพิกัด/ระยะไว้ตรวจย้อนหลัง
--   att_self_list(date) / att_self_edit(...) : Admin ดู/แก้เวลาเข้า-เลิกงานของหัวหน้างาน → คิด OT ใหม่
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================
alter table public.attendance add column if not exists clock_in_geo  jsonb;
alter table public.attendance add column if not exists clock_out_geo jsonb;

create or replace function public.geo_dist_m(a_lat numeric, a_lng numeric, b_lat numeric, b_lng numeric) returns numeric
language sql immutable as $$
  select (2 * 6371000 * asin(sqrt(power(sin(radians((b_lat - a_lat) / 2)), 2)
         + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians((b_lng - a_lng) / 2)), 2))))::numeric
$$;

create or replace function public.factory_geo() returns jsonb
language sql stable security definer set search_path = public as $$
  select value from app_settings where key = 'factory_geo'
$$;
create or replace function public.factory_geo_set(p_lat numeric, p_lng numeric, p_radius int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  if p_lat is null then delete from app_settings where key = 'factory_geo'; return null; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'พิกัดไม่ถูกต้อง'; end if;
  v := jsonb_build_object('lat', round(p_lat, 6), 'lng', round(p_lng, 6), 'radius', greatest(50, least(coalesce(p_radius, 300), 5000)));
  insert into app_settings (key, value) values ('factory_geo', v) on conflict (key) do update set value = excluded.value;
  return v;
end $$;

drop function if exists public.att_self_clock(text);
create or replace function public.att_self_clock(p_kind text, p_lat numeric default null, p_lng numeric default null, p_acc numeric default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); e employees; a attendance; loc timestamp := now() at time zone 'Asia/Bangkok'; d date; hm text;
        fg jsonb := public.factory_geo(); dist numeric; geo jsonb;
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  select * into e from employees where id = me;
  if e.role = 'employee' or not e.active then raise exception 'ลงเวลาเองได้เฉพาะหัวหน้างาน'; end if;
  if p_lat is not null and p_lng is not null then
    geo := jsonb_build_object('lat', round(p_lat, 6), 'lng', round(p_lng, 6), 'acc', round(coalesce(p_acc, 0)));
  end if;
  if fg is not null then
    if geo is null then raise exception 'ต้องเปิด GPS (ตำแหน่ง) ก่อนลงเวลา'; end if;
    if coalesce(p_acc, 0) > 1000 then raise exception 'สัญญาณ GPS ไม่แม่น (±% ม.) — ออกไปที่โล่งแล้วลองใหม่', round(p_acc); end if;
    dist := public.geo_dist_m(p_lat, p_lng, (fg->>'lat')::numeric, (fg->>'lng')::numeric);
    geo := geo || jsonb_build_object('dist', round(dist));
    if dist > (fg->>'radius')::numeric + least(coalesce(p_acc, 0), 150) then
      raise exception 'อยู่นอกพื้นที่โรงงาน (ห่าง % ม.) — ลงเวลาได้เมื่ออยู่ที่โรงงานเท่านั้น', round(dist);
    end if;
  end if;
  d := loc::date; hm := to_char(loc, 'HH24:MI');
  select * into a from attendance where employee_id = me and clock_in_at is not null and clock_out_at is null and clock_in_at > now() - interval '20 hours' order by clock_in_at desc limit 1;
  if p_kind = 'in' then
    if a.id is not null then raise exception 'ลงเวลาเข้างานไว้แล้ว (%) — กดลงเวลาเลิกงาน', a.check_in_time; end if;
    if exists (select 1 from attendance x where x.employee_id = me and x.work_date = d and x.clock_out_at is not null) then raise exception 'วันนี้ลงเวลาเข้า-เลิกงานครบแล้ว'; end if;
    insert into attendance (employee_id, work_date, status, check_in_time, source, department_id, shift, recorded_by, clock_in_at, clock_out_at, check_out_time, clock_in_geo, clock_out_geo, note)
    values (me, d, 'มาทำงาน', hm, 'manual', e.department_id, e.shift, me, now(), null, null, geo, null, 'ลงเวลาเอง (หัวหน้างาน)')
    on conflict (employee_id, work_date) do update set status = 'มาทำงาน', check_in_time = excluded.check_in_time, clock_in_at = excluded.clock_in_at,
      clock_out_at = null, check_out_time = null, clock_in_geo = excluded.clock_in_geo, clock_out_geo = null, recorded_by = me, note = excluded.note, updated_at = now();
    perform public.ot_apply(me, d);
  elsif p_kind = 'out' then
    if a.id is null then raise exception 'ยังไม่ได้ลงเวลาเข้างาน (หรือเกิน 20 ชม.แล้ว — ให้ Admin แก้เวลาให้)'; end if;
    update attendance set clock_out_at = now(), check_out_time = hm, clock_out_geo = geo, updated_at = now() where id = a.id;
    perform public.ot_apply(me, a.work_date);
  else raise exception 'คำสั่งไม่ถูกต้อง';
  end if;
  return public.att_self_status() || jsonb_build_object('dist', round(dist));
end $$;

-- Admin: รายชื่อหัวหน้างาน + เวลาที่ลงของวันนั้น
create or replace function public.att_self_list(p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  return coalesce((select jsonb_agg(z order by z.dept nulls last, z.name) from (
    select e.id, e.employee_no no, coalesce(nullif(e.display_name, ''), e.employee_no) name, d.name dept, e.role,
           a.status, a.check_in_time "in", a.check_out_time "out", a.clock_in_at in_at, a.clock_out_at out_at, a.clock_in_geo in_geo, a.clock_out_geo out_geo, a.note,
           (select coalesce(jsonb_object_agg(o.rate, o.hours), '{}'::jsonb) from ot_days o where o.employee_id = e.id and o.work_date = p_date) ot
      from employees e left join departments d on d.id = e.department_id
      left join attendance a on a.employee_id = e.id and a.work_date = p_date
     where e.active and e.role <> 'employee') z), '[]'::jsonb);
end $$;

-- Admin แก้เวลา (HH:MM) · เวลาเลิกงานน้อยกว่าเวลาเข้า = ข้ามวัน · p_in = null → ลบการลงเวลาวันนั้น
create or replace function public.att_self_edit(p_emp uuid, p_date date, p_in text, p_out text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e employees; ti timestamptz; tout timestamptz; me uuid := public.my_employee_id();
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  select * into e from employees where id = p_emp;
  if not found then raise exception 'ไม่พบพนักงาน'; end if;
  if p_in is null or p_in = '' then
    update attendance set clock_in_at = null, clock_out_at = null, check_out_time = null, updated_at = now() where employee_id = p_emp and work_date = p_date;
    delete from attendance where employee_id = p_emp and work_date = p_date and (note like 'ลงเวลาเอง%' or note like 'แก้เวลาโดย Admin%');
    perform public.ot_apply(p_emp, p_date);
    return '{}'::jsonb;
  end if;
  if p_in !~ '^[0-2][0-9]:[0-5][0-9]$' or (p_out is not null and p_out <> '' and p_out !~ '^[0-2][0-9]:[0-5][0-9]$') then raise exception 'รูปแบบเวลาไม่ถูกต้อง (HH:MM)'; end if;
  ti := (p_date + p_in::time) at time zone 'Asia/Bangkok';
  if p_out is not null and p_out <> '' then
    tout := (p_date + p_out::time) at time zone 'Asia/Bangkok';
    if tout <= ti then tout := tout + interval '1 day'; end if;
  end if;
  insert into attendance (employee_id, work_date, status, check_in_time, source, department_id, shift, recorded_by, clock_in_at, clock_out_at, check_out_time, note)
  values (p_emp, p_date, 'มาทำงาน', p_in, 'manual', e.department_id, e.shift, me, ti, tout, nullif(p_out, ''), 'แก้เวลาโดย Admin')
  on conflict (employee_id, work_date) do update set status = 'มาทำงาน', check_in_time = excluded.check_in_time, clock_in_at = excluded.clock_in_at,
    clock_out_at = excluded.clock_out_at, check_out_time = excluded.check_out_time, recorded_by = me, note = 'แก้เวลาโดย Admin', updated_at = now();
  perform public.ot_apply(p_emp, p_date);
  return (select coalesce(jsonb_object_agg(rate, hours), '{}'::jsonb) from ot_days where employee_id = p_emp and work_date = p_date);
end $$;

revoke execute on function public.factory_geo_set(numeric, numeric, int), public.att_self_clock(text, numeric, numeric, numeric), public.att_self_list(date), public.att_self_edit(uuid, date, text, text), public.factory_geo() from public, anon;
grant execute on function public.factory_geo_set(numeric, numeric, int), public.att_self_clock(text, numeric, numeric, numeric), public.att_self_list(date), public.att_self_edit(uuid, date, text, text), public.factory_geo() to authenticated;
notify pgrst, 'reload schema';
