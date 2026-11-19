-- Yum Diwa POS + Online Pickup — run in Supabase → SQL Editor
-- Safe to run again: it creates what is missing and updates functions/policies.

------------------------------------------------------------
-- 1) Orders (walk-in = source 'pos', queue 1–99; online = source 'online', queue 101–999)
------------------------------------------------------------
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  queue         integer      not null,
  date          text         not null,               -- 'YYYY-MM-DD' Thai time
  created_at    timestamptz  not null default now(),
  status        text         not null default 'open' check (status in ('open', 'paid', 'void')),
  items         jsonb        not null default '[]'::jsonb,
  spice         text         default '',
  note          text         default '',
  subtotal      numeric(10,2) not null default 0,
  discount      numeric(10,2) not null default 0,
  total         numeric(10,2) not null default 0,
  coupon_id     text         default '',
  coupon_label  text         default '',
  pay_method    text         default '',
  paid_at       timestamptz,
  void_at       timestamptz,
  created_by    uuid         default auth.uid(),
  unique (date, queue)
);
alter table public.orders add column if not exists source         text not null default 'pos';
alter table public.orders add column if not exists pickup_time    text;          -- 'HH:MM'
alter table public.orders add column if not exists customer_name  text;
alter table public.orders add column if not exists customer_phone text;
alter table public.orders add column if not exists ready_at       timestamptz;
alter table public.orders add column if not exists customer_paid_at timestamptz;   -- customer tapped "โอนแล้ว"
alter table public.orders add column if not exists receipt_path text;
create index if not exists orders_date_idx on public.orders (date);

------------------------------------------------------------
-- 1b) Staff allowlist. Customer orders remain anonymous; only staff can use POS data.
------------------------------------------------------------
create table if not exists public.staff_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.staff_accounts enable row level security;
revoke all on public.staff_accounts from public, anon, authenticated;
insert into public.staff_accounts (user_id)
  select id from auth.users
  where not exists (select 1 from public.staff_accounts);
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_accounts where user_id = auth.uid());
$$;
revoke all on function public.is_staff() from public;
grant execute on function public.is_staff() to authenticated;

alter table public.orders enable row level security;
drop policy if exists "staff read"   on public.orders;
drop policy if exists "staff insert" on public.orders;
drop policy if exists "staff update" on public.orders;
drop policy if exists "staff delete" on public.orders;
drop policy if exists "staff read and customer history" on public.orders;
create policy "staff read"   on public.orders for select to authenticated using (public.is_staff());
create policy "staff insert" on public.orders for insert to authenticated with check (public.is_staff());
create policy "staff update" on public.orders for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "staff delete" on public.orders for delete to authenticated using (public.is_staff());
-- Customers (anon) get NO direct access to orders. They go through the two functions below.
revoke all on public.orders from anon;
grant select, insert, update, delete on public.orders to authenticated;

------------------------------------------------------------
-- 2) Shop settings: the online open/close switch
------------------------------------------------------------
create table if not exists public.settings (
  id           integer primary key default 1 check (id = 1),
  online_open  boolean not null default true,
  open_from    text    not null default '00:00',
  open_until   text    not null default '23:45',
  updated_at   timestamptz not null default now()
);
insert into public.settings (id, online_open, open_from, open_until)
values (1, true, '00:00', '23:45')
on conflict (id) do update set online_open = excluded.online_open,
                              open_from = excluded.open_from,
                              open_until = excluded.open_until,
                              updated_at = now();
alter table public.settings enable row level security;
drop policy if exists "anyone reads settings" on public.settings;
drop policy if exists "staff updates settings" on public.settings;
create policy "anyone reads settings"  on public.settings for select to anon, authenticated using (true);
create policy "staff updates settings" on public.settings for update to authenticated using (public.is_staff()) with check (public.is_staff());
grant select on public.settings to anon, authenticated;
grant update on public.settings to authenticated;

------------------------------------------------------------
-- 2b) Private storage for customer payment slips
------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-receipts', 'payment-receipts', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880,
                              allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];
drop policy if exists "customer upload payment slips" on storage.objects;
drop policy if exists "staff read payment slips" on storage.objects;
create policy "customer upload payment slips" on storage.objects
  for insert to anon with check (
    bucket_id = 'payment-receipts'
    and name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}\.(jpg|png|webp)$'
  );
create policy "staff read payment slips" on storage.objects
  for select to authenticated using (bucket_id = 'payment-receipts' and public.is_staff());

------------------------------------------------------------
-- 3) Menu: prices for online orders are always taken from here, never from the customer's browser
------------------------------------------------------------
create table if not exists public.menu (
  id         text primary key,
  name       text not null,
  cat        text not null check (cat in ('yum', 'tea')),
  price      numeric(10,2) not null,
  available  boolean not null default true,
  sort       integer not null default 0
);
insert into public.menu (id, name, cat, price, sort) values
  ('crab',      'ปูอัด',              'yum', 10, 1),
  ('red',       'ไส้กรอกแดง',         'yum', 10, 2),
  ('lava',      'ไส้กรอกชีสลาวา',     'yum', 10, 3),
  ('pork',      'ลูกชิ้นหมู',          'yum', 10, 4),
  ('chicken',   'ลูกชิ้นไก่',          'yum', 10, 5),
  ('fishball',  'ลูกชิ้นปลา',          'yum', 10, 6),
  ('thaitea',   'ชาไทย',              'tea', 30, 7),
  ('thaitea-lemon', 'ชาไทยมะนาว',     'tea', 10, 8),
  ('thaitea-honey', 'ชาไทยน้ำผึ้งมะนาว', 'tea', 10, 9)
on conflict (id) do update set name = excluded.name, cat = excluded.cat, price = excluded.price, sort = excluded.sort;
-- Remove old menu items
delete from public.menu where id in ('jasmine', 'honey');
alter table public.menu enable row level security;
drop policy if exists "anyone reads menu" on public.menu;
drop policy if exists "staff edits menu" on public.menu;
create policy "anyone reads menu" on public.menu for select to anon, authenticated using (true);
create policy "staff edits menu"  on public.menu for update to authenticated using (public.is_staff()) with check (public.is_staff());
grant select on public.menu to anon, authenticated;
grant update on public.menu to authenticated;

------------------------------------------------------------
-- 4) Customer places an online order (checks open switch, hours, prices, queue number)
------------------------------------------------------------
create or replace function public.place_online_order(
  p_items  jsonb,
  p_pickup text,
  p_name   text,
  p_phone  text,
  p_note   text default '',
  p_spice  text default ''
) returns table (out_id uuid, out_queue integer, out_total numeric, out_pickup text)
language plpgsql security definer set search_path = public as $$
declare
  v_now   timestamp := (now() at time zone 'Asia/Bangkok');
  v_date  text := to_char(v_now, 'YYYY-MM-DD');
  v_set   public.settings%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_sub   numeric := 0;
  v_count integer := 0;
  v_hasyum boolean := false;
  v_q     integer;
  v_id    uuid;
  v_open_orders integer;
  r record; m record;
begin
  select * into v_set from public.settings where id = 1;
  if not coalesce(v_set.online_open, false) then raise exception 'SHOP_CLOSED'; end if;
  if p_pickup is null or p_pickup !~ '^\d{2}:\d{2}$'
     or p_pickup < v_set.open_from or p_pickup > v_set.open_until then raise exception 'BAD_TIME'; end if;
  if p_pickup < to_char(v_now + interval '10 minutes', 'HH24:MI') then raise exception 'TIME_PASSED'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 or coalesce(p_phone, '') !~ '^0\d{8,9}$' then raise exception 'BAD_CONTACT'; end if;

  -- simple spam guard: at most 3 unpaid online orders per phone per day
  select count(*) into v_open_orders from public.orders o
   where o.date = v_date and o.source = 'online' and o.customer_phone = p_phone and o.status = 'open';
  if v_open_orders >= 3 then raise exception 'TOO_MANY'; end if;

  for r in select * from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb)) as x(id text, qty integer) loop
    select * into m from public.menu where public.menu.id = r.id and available;
    if not found or r.qty is null or r.qty < 1 or r.qty > 50 then raise exception 'BAD_ITEM'; end if;
    v_items := v_items || jsonb_build_object('id', m.id, 'name', m.name, 'cat', m.cat, 'price', m.price, 'qty', r.qty);
    v_sub := v_sub + m.price * r.qty;
    v_count := v_count + 1;
    if m.cat = 'yum' then v_hasyum := true; end if;
  end loop;
  if v_count = 0 then raise exception 'EMPTY'; end if;

  perform pg_advisory_xact_lock(hashtext('online-queue-' || v_date));
  select coalesce(max(o.queue), 100) + 1 into v_q from public.orders o where o.date = v_date and o.source = 'online';
  if v_q > 999 then raise exception 'QUEUE_FULL'; end if;

  insert into public.orders (queue, date, status, source, items, spice, note, subtotal, discount, total,
                             pickup_time, customer_name, customer_phone, created_by)
  values (v_q, v_date, 'open', 'online', v_items,
          case when v_hasyum then left(coalesce(p_spice, ''), 20) else '' end,
          left(coalesce(p_note, ''), 120), v_sub, 0, v_sub,
          p_pickup, left(trim(p_name), 40), p_phone, null)
  returning id into v_id;

  return query select v_id, v_q, v_sub, p_pickup;
end $$;

------------------------------------------------------------
-- 5) Customer checks their own order (needs the order id, which only they have)
------------------------------------------------------------
drop function if exists public.get_online_order(uuid);
create or replace function public.get_online_order(p_id uuid)
returns table (out_queue integer, out_status text, out_pickup text, out_total numeric,
               out_items jsonb, out_ready boolean, out_date text, out_name text, out_claimed boolean)
language sql security definer set search_path = public as $$
  select o.queue, o.status, o.pickup_time, o.total, o.items, o.ready_at is not null, o.date, o.customer_name, o.customer_paid_at is not null
  from public.orders o where o.id = p_id and o.source = 'online';
$$;

------------------------------------------------------------
-- 5b) Customer taps "โอนแล้ว" after paying by QR (staff still check the bank app before closing the bill)
------------------------------------------------------------
drop function if exists public.mark_online_paid(uuid);
create or replace function public.mark_online_paid(p_id uuid, p_receipt_path text)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_receipt_path is null or split_part(p_receipt_path, '/', 1) <> p_id::text then
    raise exception 'RECEIPT_REQUIRED';
  end if;
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'payment-receipts' and name = p_receipt_path
  ) then
    raise exception 'RECEIPT_NOT_FOUND';
  end if;
  update public.orders
     set customer_paid_at = coalesce(customer_paid_at, now()), receipt_path = p_receipt_path
   where id = p_id and source = 'online' and status = 'open';
  return found;
end $$;

revoke all on function public.mark_online_paid(uuid, text) from public;
grant execute on function public.mark_online_paid(uuid, text) to anon, authenticated;
revoke all on function public.place_online_order(jsonb, text, text, text, text, text) from public;
revoke all on function public.get_online_order(uuid) from public;
grant execute on function public.place_online_order(jsonb, text, text, text, text, text) to anon, authenticated;
grant execute on function public.get_online_order(uuid) to anon, authenticated;

------------------------------------------------------------
-- 6) Realtime: POS sees new orders and the open/close switch instantly
------------------------------------------------------------
do $$ begin
  begin alter publication supabase_realtime add table public.orders;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when duplicate_object then null; end;
end $$;

------------------------------------------------------------
-- 7) Daily report view
------------------------------------------------------------
create or replace view public.daily_sales with (security_invoker = true) as
select date,
       count(*)                                         as bills,
       sum(total)                                       as net_sales,
       sum(total) filter (where source = 'online')      as online_sales,
       sum(total) filter (where source <> 'online')     as walkin_sales,
       sum(discount)                                    as discounts
from public.orders
where status = 'paid'
group by date
order by date;
