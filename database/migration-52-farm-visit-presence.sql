-- =====================================================================
-- Migration 52: ฟาร์ม — ตัวละครเพื่อนที่มาเยี่ยม แสดงเฉพาะตอนที่ยังอยู่ในฟาร์มจริง
--  • ระหว่างเยี่ยม แอปส่งสัญญาณ "ยังอยู่" ทุก 1 นาที (farm_visit)
--  • กดกลับ → farm_visit_leave → ตัวละครหายทันที
--  • ปิดแอป/ไม่มีสัญญาณเกิน 3 นาที → ตัวละครหายเอง
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
alter table public.farm_visits add column if not exists left_at timestamptz;

create or replace function public.farm_visit(p_owner uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id();
begin
  if me is null or p_owner is null or p_owner = me then return; end if;
  insert into farm_visits (visitor_id, owner_id, day) values (me, p_owner, public.farm_today())
  on conflict (visitor_id, owner_id, day) do update set at = now(), left_at = null;
end $$;

create or replace function public.farm_visit_leave(p_owner uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id();
begin
  if me is null or p_owner is null then return; end if;
  update farm_visits set left_at = now()
   where visitor_id = me and owner_id = p_owner and day = public.farm_today() and left_at is null;
end $$;

create or replace function public.farm_guests(p_emp uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', coalesce(nullif(x.display_name, ''), x.employee_no), 'admin', x.role = 'admin', 'at', v.at) order by v.at desc), '[]')
  from (select * from farm_visits
         where owner_id = coalesce(p_emp, public.my_employee_id()) and day = public.farm_today()
           and left_at is null and at > now() - interval '3 minutes'
         order by at desc limit 6) v
  join employees x on x.id = v.visitor_id
  where public.my_employee_id() is not null
$$;

-- คนที่เยี่ยมค้างไว้ก่อนอัปเดตนี้ ถือว่ากลับแล้ว
update public.farm_visits set left_at = now() where left_at is null and at < now() - interval '3 minutes';

revoke execute on function public.farm_visit_leave(uuid) from public, anon;
grant execute on function public.farm_visit_leave(uuid) to authenticated;
notify pgrst, 'reload schema';
