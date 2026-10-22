-- =====================================================================
-- Migration 62: (1) หัวหน้างานไม่ต้องลงยอด KPI  (2) ระบบนับ OT ต่อจากไฟล์ HR + ดูย้อนหลังรายเดือน
--  OT 5 ระดับ: OT 1 · OT 1.5 · OT 2 · OT 3 · OT 4
--  • นำเข้าไฟล์ Excel "รายงานเปรียบเทียบ Budget" (BG_* = งบ, OT_* = ทำจริงถึงวันที่ของไฟล์)
--  • หลังวันที่ของไฟล์: สแกน/เช็คชื่อมาทำงาน → เพิ่ม OT ให้อัตโนมัติตามกฎ (Admin แก้กฎได้)
--      วันทำงานปกติ: OT 1.5 = 2.5 ชม.
--      วันหยุด (อาทิตย์ / วันหยุดโรงงาน): รายเดือน OT 1 = 8 + OT 3 = 2.5 · รายวัน OT 2 = 8 + OT 3 = 2.5
--  • หัวหน้า (สิทธิ์เช็คชื่อของแผนก) / Admin แก้ชั่วโมงรายวันได้ · พนักงานเห็นของตัวเอง หัวหน้าเห็นแผนกที่ดูแล
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================

-- ---------- (1) หัวหน้างาน / ผู้ดูแล ไม่ต้องลงยอด KPI ----------
update public.employees set kpi_required = false where role <> 'employee' and kpi_required;
create or replace function public.employees_kpi_role() returns trigger language plpgsql as $$
begin
  if new.role <> 'employee' and (tg_op = 'INSERT' or new.role is distinct from old.role) then new.kpi_required := false; end if;
  if new.role = 'employee' and tg_op = 'UPDATE' and old.role <> 'employee' and new.kpi_required = old.kpi_required and not new.kpi_required then new.kpi_required := true; end if;
  return new;
end $$;
drop trigger if exists employees_kpi_role on public.employees;
create trigger employees_kpi_role before insert or update of role on public.employees for each row execute function public.employees_kpi_role();

-- ---------- (2) OT ----------
create table if not exists public.ot_months (
  employee_id uuid not null references public.employees(id) on delete cascade,
  ym          text not null check (ym ~ '^[0-9]{4}-[0-9]{2}$'),
  pay_type    text not null default 'รายเดือน',
  budget      jsonb not null default '{}'::jsonb,
  base        jsonb not null default '{}'::jsonb,
  base_until  date,
  dept_code   text,
  dept_name   text,
  imported_at timestamptz,
  primary key (employee_id, ym)
);
create table if not exists public.ot_days (
  employee_id uuid not null references public.employees(id) on delete cascade,
  work_date   date not null,
  rate        text not null check (rate in ('1','1.5','2','3','4')),
  hours       numeric(5,2) not null check (hours >= 0 and hours <= 24),
  source      text not null default 'auto' check (source in ('auto','manual')),
  note        text not null default '',
  updated_by  uuid references public.employees(id) on delete set null,
  updated_at  timestamptz not null default now(),
  primary key (employee_id, work_date, rate)
);
create index if not exists ot_days_date_idx on public.ot_days (work_date);
alter table public.ot_months enable row level security;
alter table public.ot_days enable row level security;
revoke all on public.ot_months, public.ot_days from anon, public, authenticated;

create or replace function public.ot_rules() returns jsonb
language sql stable security definer set search_path = public as $$
  select '{"work":{"1.5":2.5},"hol_monthly":{"1":8,"3":2.5},"hol_daily":{"2":8,"3":2.5},"sunday":true}'::jsonb
         || coalesce((select value from app_settings where key = 'ot_rules'), '{}'::jsonb)
$$;

create or replace function public.ot_is_holiday(d date) returns boolean
language sql stable security definer set search_path = public as $$
  select (coalesce((public.ot_rules()->>'sunday')::boolean, true) and extract(dow from d) = 0)
      or exists (select 1 from holidays h where h.date = d and h.type = 'company')
$$;

create or replace function public.ot_can_edit(p_emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from employees x where x.id = p_emp and public.has_perm('att_check', x.department_id))
$$;
create or replace function public.ot_can_see(p_emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_emp = public.my_employee_id() or public.is_admin()
      or exists (select 1 from employees x where x.id = p_emp and public.can_see_department(x.department_id))
$$;

-- ใส่ OT อัตโนมัติของวันหนึ่งตามการเช็คชื่อ (ไม่ทับรายการที่หัวหน้าแก้เอง และไม่นับวันที่อยู่ในไฟล์แล้ว)
create or replace function public.ot_apply(p_emp uuid, p_date date) returns void
language plpgsql security definer set search_path = public as $$
declare v_ym text := to_char(p_date, 'YYYY-MM'); m ot_months; pt text; r jsonb; k text; v text; present boolean;
begin
  delete from ot_days where employee_id = p_emp and work_date = p_date and source = 'auto';
  if exists (select 1 from ot_days where employee_id = p_emp and work_date = p_date and source = 'manual') then return; end if;
  select exists (select 1 from attendance a where a.employee_id = p_emp and a.work_date = p_date and a.status in ('มาทำงาน','เข้างานสาย','ต่อกะสาย')) into present;
  if not present then return; end if;
  select * into m from ot_months where employee_id = p_emp and ot_months.ym = v_ym;
  if found and m.base_until is not null and p_date <= m.base_until then return; end if;
  if not found then
    select o.pay_type into pt from ot_months o where o.employee_id = p_emp order by o.ym desc limit 1;
    insert into ot_months (employee_id, ym, pay_type, budget, dept_code, dept_name)
      select p_emp, v_ym, coalesce(o.pay_type, 'รายเดือน'), coalesce(o.budget, '{}'::jsonb), o.dept_code, o.dept_name
        from (select 1) z left join lateral (select * from ot_months where employee_id = p_emp order by ym desc limit 1) o on true
      on conflict do nothing;
    select * into m from ot_months where employee_id = p_emp and ot_months.ym = v_ym;
  end if;
  pt := coalesce(m.pay_type, 'รายเดือน');
  r := public.ot_rules();
  r := case when public.ot_is_holiday(p_date) then case when pt like '%วัน%' then r->'hol_daily' else r->'hol_monthly' end else r->'work' end;
  for k, v in select key, value from jsonb_each_text(coalesce(r, '{}'::jsonb)) loop
    if k in ('1','1.5','2','3','4') and v::numeric > 0 then
      insert into ot_days (employee_id, work_date, rate, hours, source) values (p_emp, p_date, k, v::numeric, 'auto')
      on conflict (employee_id, work_date, rate) do nothing;
    end if;
  end loop;
end $$;

create or replace function public.ot_att_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE','DELETE') then perform public.ot_apply(old.employee_id, old.work_date); end if;
  if tg_op in ('INSERT','UPDATE') then perform public.ot_apply(new.employee_id, new.work_date); end if;
  return null;
end $$;
drop trigger if exists attendance_ot on public.attendance;
create trigger attendance_ot after insert or update of status, work_date, employee_id or delete on public.attendance for each row execute function public.ot_att_trg();

-- นำเข้าไฟล์ OT (Admin) — แถว: {no, ym, pay_type, dept_code, dept_name, bg:{rate:h}, ot:{rate:h}}
create or replace function public.ot_import(p_rows jsonb, p_base_until date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; e uuid; n int := 0; miss jsonb := '[]'::jsonb; d date; v_ym text;
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    select id into e from employees where employee_no = x->>'no';
    if e is null then miss := miss || to_jsonb(x->>'no'); continue; end if;
    v_ym := x->>'ym';
    insert into ot_months (employee_id, ym, pay_type, budget, base, base_until, dept_code, dept_name, imported_at)
    values (e, v_ym, coalesce(nullif(x->>'pay_type', ''), 'รายเดือน'), coalesce(x->'bg', '{}'), coalesce(x->'ot', '{}'), p_base_until, x->>'dept_code', x->>'dept_name', now())
    on conflict (employee_id, ym) do update set pay_type = excluded.pay_type, budget = excluded.budget, base = excluded.base, base_until = excluded.base_until,
      dept_code = excluded.dept_code, dept_name = excluded.dept_name, imported_at = now();
    -- ไฟล์ครอบคลุมถึง base_until แล้ว: ล้าง OT อัตโนมัติก่อนหน้านั้น · คำนวณวันหลังจากนั้นใหม่จากการเช็คชื่อ
    delete from ot_days where employee_id = e and source = 'auto' and to_char(work_date, 'YYYY-MM') = v_ym and work_date <= p_base_until;
    for d in select a.work_date from attendance a where a.employee_id = e and to_char(a.work_date, 'YYYY-MM') = v_ym and a.work_date > p_base_until loop
      perform public.ot_apply(e, d);
    end loop;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', n, 'missing', miss);
end $$;

-- สรุป OT รายเดือน (เห็นตามสิทธิ์)
create or replace function public.ot_report(p_ym text, p_emp uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.my_employee_id();
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  return coalesce((select jsonb_agg(z order by z.dept_name nulls last, z.no) from (
    select x.id, x.employee_no no, coalesce(nullif(x.display_name, ''), x.employee_no) name, x.department_id dept_id,
           coalesce(m.dept_name, dp.name) dept_name, coalesce(m.pay_type, 'รายเดือน') pay_type, coalesce(m.budget, '{}'::jsonb) budget, coalesce(m.base, '{}'::jsonb) base, m.base_until,
           coalesce((select jsonb_object_agg(rate, h) from (select rate, sum(hours) h from ot_days dd where dd.employee_id = x.id and to_char(dd.work_date, 'YYYY-MM') = p_ym group by rate) q), '{}'::jsonb) add
      from employees x left join ot_months m on m.employee_id = x.id and m.ym = p_ym left join departments dp on dp.id = x.department_id
     where x.active and (p_emp is null or x.id = p_emp)
       and (m.employee_id is not null or exists (select 1 from ot_days dd where dd.employee_id = x.id and to_char(dd.work_date, 'YYYY-MM') = p_ym))
       and public.ot_can_see(x.id)) z), '[]'::jsonb);
end $$;

create or replace function public.ot_days_of(p_emp uuid, p_ym text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.ot_can_see(p_emp) then raise exception 'ไม่มีสิทธิ์ดู OT ของคนนี้'; end if;
  return jsonb_build_object('days', coalesce((select jsonb_agg(jsonb_build_object('d', work_date, 'rate', rate, 'h', hours, 'src', source, 'note', note) order by work_date, rate)
           from ot_days where employee_id = p_emp and to_char(work_date, 'YYYY-MM') = p_ym), '[]'::jsonb),
    'att', coalesce((select jsonb_agg(jsonb_build_object('d', work_date, 'st', status, 't', check_in_time) order by work_date) from attendance where employee_id = p_emp and to_char(work_date, 'YYYY-MM') = p_ym), '[]'::jsonb),
    'month', (select to_jsonb(m) - 'employee_id' from ot_months m where m.employee_id = p_emp and m.ym = p_ym),
    'can_edit', public.ot_can_edit(p_emp));
end $$;

-- หัวหน้า/Admin แก้ชั่วโมง OT ของวันหนึ่ง (ใส่ 0 ทุกระดับ = ไม่ได้ทำ OT วันนั้น)
create or replace function public.ot_set_day(p_emp uuid, p_date date, p_hours jsonb, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare k text; v text; any_h boolean := false;
begin
  if not public.ot_can_edit(p_emp) then raise exception 'ไม่มีสิทธิ์แก้ OT ของคนนี้'; end if;
  delete from ot_days where employee_id = p_emp and work_date = p_date;
  for k, v in select key, value from jsonb_each_text(coalesce(p_hours, '{}'::jsonb)) loop
    if k in ('1','1.5','2','3','4') and coalesce(nullif(v, '')::numeric, 0) > 0 then
      insert into ot_days (employee_id, work_date, rate, hours, source, note, updated_by) values (p_emp, p_date, k, v::numeric, 'manual', left(coalesce(p_note, ''), 200), public.my_employee_id());
      any_h := true;
    end if;
  end loop;
  if not any_h then insert into ot_days (employee_id, work_date, rate, hours, source, note, updated_by) values (p_emp, p_date, '1.5', 0, 'manual', left(coalesce(p_note, 'ไม่ได้ทำ OT'), 200), public.my_employee_id()); end if;
end $$;

-- กลับไปใช้ค่าอัตโนมัติ
create or replace function public.ot_reset_day(p_emp uuid, p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.ot_can_edit(p_emp) then raise exception 'ไม่มีสิทธิ์แก้ OT ของคนนี้'; end if;
  delete from ot_days where employee_id = p_emp and work_date = p_date and source = 'manual';
  perform public.ot_apply(p_emp, p_date);
end $$;

create or replace function public.ot_months_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(ym order by ym desc), '[]'::jsonb) from (select distinct ym from ot_months union select distinct to_char(work_date, 'YYYY-MM') from ot_days) z
$$;

revoke execute on function public.ot_apply(uuid, date), public.ot_att_trg(), public.employees_kpi_role() from public, anon, authenticated;
revoke execute on function public.ot_rules(), public.ot_is_holiday(date), public.ot_can_edit(uuid), public.ot_can_see(uuid), public.ot_import(jsonb, date), public.ot_report(text, uuid),
  public.ot_days_of(uuid, text), public.ot_set_day(uuid, date, jsonb, text), public.ot_reset_day(uuid, date), public.ot_months_list() from public, anon;
grant execute on function public.ot_rules(), public.ot_import(jsonb, date), public.ot_report(text, uuid), public.ot_days_of(uuid, text), public.ot_set_day(uuid, date, jsonb, text),
  public.ot_reset_day(uuid, date), public.ot_months_list(), public.ot_can_edit(uuid) to authenticated;
notify pgrst, 'reload schema';
