-- =====================================================================
-- อัปเดต 158: หัวหน้างาน (role ไม่ใช่ employee) ลงเวลาเข้า-เลิกงานเองได้ → ระบบคิด OT จากเวลาจริง
--   attendance + clock_in_at / clock_out_at / check_out_time
--   att_self_clock('in'|'out') : เวลาจากเซิร์ฟเวอร์ (แก้เวลาเองไม่ได้)
--   OT จากเวลาจริง (ปรับได้ที่ ot_rules.self):
--     วันทำงาน : ชม.เกิน std_span (9 = งาน 8 + พัก 1) → OT 1.5 ปัดลงทีละ 0.5 ชม.
--     วันหยุด  : (ช่วงเวลา - พัก 1) ไม่เกิน 8 ชม. → OT 1 (รายเดือน) / OT 2 (รายวัน) · ส่วนเกิน 8 → OT 3
--   ไม่ลบข้อมูลใด ๆ
-- =====================================================================
alter table public.attendance add column if not exists clock_in_at  timestamptz;
alter table public.attendance add column if not exists clock_out_at timestamptz;
alter table public.attendance add column if not exists check_out_time text;

create or replace function public.ot_self_rules() returns jsonb
language sql stable security definer set search_path = public as $$
  select '{"std_span":9,"break":1,"round":0.5,"hol_cap":8}'::jsonb || coalesce(public.ot_rules()->'self', '{}'::jsonb)
$$;

create or replace function public.ot_apply(p_emp uuid, p_date date) returns void
language plpgsql security definer set search_path = public as $$
declare v_ym text := to_char(p_date, 'YYYY-MM'); m ot_months; pt text; r jsonb; k text; v text; present boolean;
        a attendance; sr jsonb; span numeric; rd numeric; w numeric; base_h numeric; extra numeric; hol boolean;
begin
  delete from ot_days where employee_id = p_emp and work_date = p_date and source = 'auto';
  if exists (select 1 from ot_days where employee_id = p_emp and work_date = p_date and source = 'manual') then return; end if;
  select * into a from attendance where employee_id = p_emp and work_date = p_date;
  present := found and a.status in ('มาทำงาน','เข้างานสาย','ต่อกะสาย');
  if not present then return; end if;
  -- ลงเวลาเอง แต่ยังไม่ลงเวลาเลิกงาน → ยังไม่คิด OT
  if a.clock_in_at is not null and a.clock_out_at is null then return; end if;
  select * into m from ot_months where employee_id = p_emp and ot_months.ym = v_ym;
  if found and m.base_until is not null and p_date <= m.base_until then return; end if;
  if not found then
    insert into ot_months (employee_id, ym, pay_type, budget, dept_code, dept_name)
      select p_emp, v_ym, coalesce(o.pay_type, 'รายเดือน'), coalesce(o.budget, '{}'::jsonb), o.dept_code, o.dept_name
        from (select 1) z left join lateral (select * from ot_months where employee_id = p_emp order by ym desc limit 1) o on true
      on conflict do nothing;
    select * into m from ot_months where employee_id = p_emp and ot_months.ym = v_ym;
  end if;
  pt := coalesce(m.pay_type, 'รายเดือน');
  hol := public.ot_is_holiday(p_date);
  -- เวลาจริงจากการลงเวลาเอง
  if a.clock_in_at is not null and a.clock_out_at is not null then
    sr := public.ot_self_rules();
    span := extract(epoch from (a.clock_out_at - a.clock_in_at)) / 3600.0;
    rd := greatest(0.25, coalesce((sr->>'round')::numeric, 0.5));
    if not hol then
      extra := floor(greatest(0, span - coalesce((sr->>'std_span')::numeric, 9)) / rd) * rd;
      if extra > 0 then insert into ot_days (employee_id, work_date, rate, hours, source) values (p_emp, p_date, '1.5', least(extra, 24), 'auto') on conflict do nothing; end if;
    else
      w := greatest(0, span - coalesce((sr->>'break')::numeric, 1));
      base_h := floor(least(w, coalesce((sr->>'hol_cap')::numeric, 8)) / rd) * rd;
      extra := floor(greatest(0, w - coalesce((sr->>'hol_cap')::numeric, 8)) / rd) * rd;
      if base_h > 0 then insert into ot_days (employee_id, work_date, rate, hours, source) values (p_emp, p_date, case when pt like '%วัน%' then '2' else '1' end, base_h, 'auto') on conflict do nothing; end if;
      if extra > 0 then insert into ot_days (employee_id, work_date, rate, hours, source) values (p_emp, p_date, '3', least(extra, 24), 'auto') on conflict do nothing; end if;
    end if;
    return;
  end if;
  r := public.ot_rules();
  r := case when hol then case when pt like '%วัน%' then r->'hol_daily' else r->'hol_monthly' end else r->'work' end;
  for k, v in select key, value from jsonb_each_text(coalesce(r, '{}'::jsonb)) loop
    if k in ('1','1.5','2','3','4') and v::numeric > 0 then
      insert into ot_days (employee_id, work_date, rate, hours, source) values (p_emp, p_date, k, v::numeric, 'auto')
      on conflict (employee_id, work_date, rate) do nothing;
    end if;
  end loop;
end $$;

-- สถานะลงเวลาล่าสุดของฉัน (ภายใน 36 ชม.)
create or replace function public.att_self_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); e employees; a attendance;
begin
  if me is null then return null; end if;
  select * into e from employees where id = me;
  select * into a from attendance where employee_id = me and clock_in_at is not null and clock_in_at > now() - interval '36 hours' order by clock_in_at desc limit 1;
  return jsonb_build_object('can', e.role <> 'employee' and e.active,
    'work_date', a.work_date, 'in', a.check_in_time, 'out', a.check_out_time, 'in_at', a.clock_in_at, 'out_at', a.clock_out_at,
    'open', a.clock_in_at is not null and a.clock_out_at is null and a.clock_in_at > now() - interval '20 hours',
    'ot', case when a.work_date is null then null else (select coalesce(jsonb_object_agg(rate, hours), '{}'::jsonb) from ot_days d where d.employee_id = me and d.work_date = a.work_date) end);
end $$;

create or replace function public.att_self_clock(p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_employee_id(); e employees; a attendance; loc timestamp := now() at time zone 'Asia/Bangkok'; d date; hm text;
begin
  if me is null then raise exception 'ต้องเป็นพนักงานในระบบ'; end if;
  select * into e from employees where id = me;
  if e.role = 'employee' or not e.active then raise exception 'ลงเวลาเองได้เฉพาะหัวหน้างาน'; end if;
  d := loc::date; hm := to_char(loc, 'HH24:MI');
  select * into a from attendance where employee_id = me and clock_in_at is not null and clock_out_at is null and clock_in_at > now() - interval '20 hours' order by clock_in_at desc limit 1;
  if p_kind = 'in' then
    if a.id is not null then raise exception 'ลงเวลาเข้างานไว้แล้ว (%) — กดลงเวลาเลิกงาน', a.check_in_time; end if;
    if exists (select 1 from attendance x where x.employee_id = me and x.work_date = d and x.clock_out_at is not null) then raise exception 'วันนี้ลงเวลาเข้า-เลิกงานครบแล้ว'; end if;
    insert into attendance (employee_id, work_date, status, check_in_time, source, department_id, shift, recorded_by, clock_in_at, clock_out_at, check_out_time, note)
    values (me, d, 'มาทำงาน', hm, 'manual', e.department_id, e.shift, me, now(), null, null, 'ลงเวลาเอง (หัวหน้างาน)')
    on conflict (employee_id, work_date) do update set status = 'มาทำงาน', check_in_time = excluded.check_in_time, clock_in_at = excluded.clock_in_at,
      clock_out_at = null, check_out_time = null, recorded_by = me, note = excluded.note, updated_at = now();
    perform public.ot_apply(me, d);
  elsif p_kind = 'out' then
    if a.id is null then raise exception 'ยังไม่ได้ลงเวลาเข้างาน (หรือเกิน 20 ชม.แล้ว — ให้แอดมิน/หัวหน้าแก้ OT ให้)'; end if;
    update attendance set clock_out_at = now(), check_out_time = hm, updated_at = now() where id = a.id;
    perform public.ot_apply(me, a.work_date);
  else raise exception 'คำสั่งไม่ถูกต้อง';
  end if;
  return public.att_self_status();
end $$;

revoke execute on function public.ot_apply(uuid, date), public.ot_self_rules() from public, anon, authenticated;
revoke execute on function public.att_self_status(), public.att_self_clock(text) from public, anon;
grant execute on function public.att_self_status(), public.att_self_clock(text) to authenticated;
notify pgrst, 'reload schema';
