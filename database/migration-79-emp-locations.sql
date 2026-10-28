-- =====================================================================
-- อัปเดต 160: ตำแหน่งพนักงานขณะเปิดแอป (แจ้งพนักงานแล้ว) — ดูได้เฉพาะ Admin
--   emp_locations : 1 แถว / การส่งตำแหน่ง (เก็บย้อนหลัง 30 วัน)
--   loc_ping(lat,lng,acc)        : แอปส่งตำแหน่งตอนเปิด / ทุก ~10 นาทีขณะเปิดอยู่
--   loc_latest() / loc_history() : Admin เท่านั้น
-- =====================================================================
create table if not exists public.emp_locations (
  id          bigserial primary key,
  employee_id uuid not null references public.employees(id) on delete cascade,
  lat         numeric(9,6) not null,
  lng         numeric(9,6) not null,
  acc         int,
  at          timestamptz not null default now()
);
create index if not exists emp_locations_emp_at on public.emp_locations (employee_id, at desc);
create index if not exists emp_locations_at on public.emp_locations (at);
alter table public.emp_locations enable row level security;
revoke all on public.emp_locations from anon, public, authenticated;

create or replace function public.loc_ping(p_lat numeric, p_lng numeric, p_acc numeric default null) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); l emp_locations;
begin
  if me is null or p_lat is null or p_lng is null then return; end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then return; end if;
  select * into l from emp_locations where employee_id = me order by at desc limit 1;
  -- ส่งถี่เกิน: ภายใน 4 นาที ให้ทับแถวล่าสุดแทน
  if found and l.at > now() - interval '4 minutes' then
    update emp_locations set lat = p_lat, lng = p_lng, acc = round(p_acc), at = now() where id = l.id;
  else
    insert into emp_locations (employee_id, lat, lng, acc) values (me, p_lat, p_lng, round(p_acc));
  end if;
  if random() < 0.02 then delete from emp_locations where at < now() - interval '30 days'; end if;
end $$;

create or replace function public.loc_latest() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fg jsonb := public.factory_geo();
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  return coalesce((select jsonb_agg(z order by z.at desc) from (
    select distinct on (l.employee_id) l.employee_id id, e.employee_no no, coalesce(nullif(e.display_name, ''), e.employee_no) name, d.name dept, e.department_id dept_id,
           l.lat, l.lng, l.acc, l.at,
           case when fg is null then null else round(public.geo_dist_m(l.lat, l.lng, (fg->>'lat')::numeric, (fg->>'lng')::numeric)) end dist
      from emp_locations l join employees e on e.id = l.employee_id left join departments d on d.id = e.department_id
     where e.active and l.at > now() - interval '30 days'
     order by l.employee_id, l.at desc) z), '[]'::jsonb);
end $$;

create or replace function public.loc_history(p_emp uuid, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'acc', acc, 'at', at) order by at)
    from emp_locations where employee_id = p_emp and (at at time zone 'Asia/Bangkok')::date = p_date), '[]'::jsonb);
end $$;

revoke execute on function public.loc_ping(numeric, numeric, numeric), public.loc_latest(), public.loc_history(uuid, date) from public, anon;
grant execute on function public.loc_ping(numeric, numeric, numeric), public.loc_latest(), public.loc_history(uuid, date) to authenticated;
notify pgrst, 'reload schema';
