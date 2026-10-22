-- =====================================================================
-- Migration 60: หน้าประชาสัมพันธ์ (ข่าวสาร · กิจกรรม · สื่อการสอน)
--  • โพสต์มีหัวข้อ เนื้อหา หมวด รูป/วิดีโอ/ไฟล์เอกสาร (PDF, Office) และลิงก์ YouTube ได้หลายชิ้น
--  • Admin สร้าง/แก้ไข/ลบ/ปักหมุด/ซ่อน ได้ · พนักงานทุกคนดูได้
--  • นับว่าใครเปิดอ่านแล้ว (ใช้ติดตามสื่อการสอน)
--  • ไฟล์เก็บใน Storage: news-media (ส่วนตัว ดูผ่านลิงก์ชั่วคราว)
--  ไม่ลบข้อมูลใด ๆ
-- =====================================================================
create table if not exists public.news_posts (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(trim(title)) between 1 and 200),
  body        text not null default '' check (char_length(body) <= 20000),
  cat         text not null default 'news' check (cat in ('news','event','learn')),
  media       jsonb not null default '[]'::jsonb,
  pinned      boolean not null default false,
  published   boolean not null default true,
  created_by  uuid references public.employees(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists news_posts_created_idx on public.news_posts (created_at desc);

create table if not exists public.news_reads (
  post_id     uuid not null references public.news_posts(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  at          timestamptz not null default now(),
  primary key (post_id, employee_id)
);

alter table public.news_posts enable row level security;
alter table public.news_reads enable row level security;
drop policy if exists news_read on public.news_posts;
drop policy if exists news_write on public.news_posts;
create policy news_read  on public.news_posts for select to authenticated using (public.my_employee_id() is not null and (published or public.is_admin()));
create policy news_write on public.news_posts for all    to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.news_posts from anon, public;
grant select, insert, update, delete on public.news_posts to authenticated;
revoke all on public.news_reads from anon, public, authenticated;

create or replace function public.news_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, public.my_employee_id()); end if; return new; end $$;
drop trigger if exists news_touch on public.news_posts;
create trigger news_touch before insert or update on public.news_posts for each row execute function public.news_touch();

-- บันทึกว่าเปิดอ่านแล้ว
create or replace function public.news_mark_read(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e uuid := public.my_employee_id();
begin
  if e is null then return; end if;
  insert into news_reads (post_id, employee_id) values (p_id, e) on conflict do nothing;
end $$;

-- โพสต์ที่ฉันอ่านแล้ว + จำนวนคนอ่าน (Admin เห็นรายชื่อ)
create or replace function public.news_read_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e uuid := public.my_employee_id();
begin
  if e is null then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'mine', coalesce((select jsonb_agg(post_id) from news_reads where employee_id = e), '[]'::jsonb),
    'counts', coalesce((select jsonb_object_agg(post_id, n) from (select post_id, count(*) n from news_reads group by post_id) z), '{}'::jsonb),
    'total', (select count(*) from employees where coalesce(active, true)));
end $$;

create or replace function public.news_readers(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'เฉพาะ Admin'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(nullif(x.display_name, ''), x.employee_no), 'no', x.employee_no, 'at', r.at) order by r.at desc)
    from news_reads r join employees x on x.id = r.employee_id where r.post_id = p_id), '[]'::jsonb);
end $$;

revoke execute on function public.news_mark_read(uuid), public.news_read_info(), public.news_readers(uuid), public.news_touch() from public, anon;
grant execute on function public.news_mark_read(uuid), public.news_read_info(), public.news_readers(uuid) to authenticated;

-- ที่เก็บไฟล์ รูป/วิดีโอ/เอกสาร (สูงสุด 50 MB ต่อไฟล์)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('news-media', 'news-media', false, 52428800,
        array['image/jpeg','image/png','image/webp','image/gif',
              'video/mp4','video/webm','video/quicktime',
              'application/pdf',
              'application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation'])
on conflict (id) do nothing;
drop policy if exists news_media_read on storage.objects;
drop policy if exists news_media_upload on storage.objects;
drop policy if exists news_media_delete on storage.objects;
create policy news_media_read on storage.objects for select to authenticated
  using (bucket_id = 'news-media' and public.my_employee_id() is not null);
create policy news_media_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'news-media' and public.is_admin());
create policy news_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'news-media' and public.is_admin());

notify pgrst, 'reload schema';
