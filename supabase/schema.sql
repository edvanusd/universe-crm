-- =====================================================================
--  Universe CRM — skema database Supabase
--  Cara pakai: Supabase Dashboard → SQL Editor → New query →
--  tempel seluruh isi file ini → Run. Aman dijalankan ulang.
--
--  Isi:
--   1. Karyawan (profiles) + login dengan username
--   2. Data master: pelanggan, produk
--   3. CRM: leads, peluang (P0–P7)
--   4. Penjualan: quotation / sales order, baris, riwayat, aktivitas
--   5. Aturan PRD yang dijaga di server (nomor SO, kunci SO, alur status,
--      giro untuk TOP, persetujuan kirim ulang, syarat BAST)
--   6. Row Level Security: hanya karyawan aktif yang bisa membaca/menulis
--   7. Realtime: perubahan langsung terlihat di semua pengguna
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Karyawan
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null unique check (username ~ '^[a-z0-9._-]{2,32}$'),
  full_name   text not null check (length(trim(full_name)) > 0),
  role        text not null default 'Sales' check (role in ('Sales','Manager','Cluster','Admin')),
  email       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.my_name() returns text
language sql stable security definer set search_path = public as $$
  select full_name from public.profiles where id = auth.uid()
$$;

create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active)
$$;

-- Profil dibuat otomatis setiap ada user baru di Supabase Auth.
-- Hanya akun dari create_employee (ditandai di app_metadata, yang tidak bisa diisi sendiri
-- oleh pendaftar) yang langsung aktif. Akun lain masuk sebagai Sales nonaktif sampai
-- diaktifkan Manager/Admin di halaman Karyawan.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  invited boolean := coalesce((new.raw_app_meta_data->>'crm_invited')::boolean, false);
  u text := lower(regexp_replace(coalesce(nullif(new.raw_user_meta_data->>'username',''), split_part(new.email,'@',1)), '[^a-zA-Z0-9._-]', '', 'g'));
  r text := case when invited then coalesce(nullif(new.raw_user_meta_data->>'role',''), 'Sales') else 'Sales' end;
begin
  if length(u) < 2 then u := 'user' || substr(replace(new.id::text,'-',''),1,6); end if;
  u := left(u, 32);
  if exists (select 1 from public.profiles where username = u) then
    u := left(u, 27) || '-' || substr(replace(new.id::text,'-',''),1,4);
  end if;
  if r not in ('Sales','Manager','Cluster','Admin') then r := 'Sales'; end if;
  insert into public.profiles (id, username, full_name, role, email, active)
  values (new.id, u, coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'),''), u), r, lower(new.email), invited)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Login memakai username: cari email karyawan (dipanggil sebelum login)
create or replace function public.login_lookup(p_username text)
returns table (email text, active boolean)
language sql stable security definer set search_path = public as $$
  select p.email, p.active from public.profiles p
  where p.username = lower(trim(p_username)) limit 1
$$;

-- Tambah karyawan (Manager/Admin dari aplikasi, atau dari SQL Editor)
create or replace function public.create_employee(
  p_username text, p_full_name text, p_role text, p_email text, p_password text)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := gen_random_uuid();
  u text := lower(trim(p_username));
  e text := lower(trim(p_email));
begin
  if auth.uid() is not null and coalesce(public.my_role(), '') not in ('Manager','Admin') then
    raise exception 'Hanya Manager atau Admin yang bisa menambah karyawan.' using errcode = '42501';
  end if;
  if u !~ '^[a-z0-9._-]{2,32}$' then
    raise exception 'Username hanya boleh huruf kecil, angka, titik, minus atau garis bawah (2–32 karakter).';
  end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Nama lengkap wajib diisi.'; end if;
  if p_role not in ('Sales','Manager','Cluster','Admin') then
    raise exception 'Peran harus Sales, Manager, Cluster atau Admin.';
  end if;
  if e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Format email tidak valid.'; end if;
  if coalesce(length(p_password), 0) < 8 then raise exception 'Password minimal 8 karakter.'; end if;
  if exists (select 1 from public.profiles where username = u) then
    raise exception 'Username % sudah dipakai.', u;
  end if;
  if exists (select 1 from auth.users where lower(email) = e) then
    raise exception 'Email % sudah terdaftar.', e;
  end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', e,
          extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"],"crm_invited":true}'::jsonb,
          jsonb_build_object('username', u, 'full_name', trim(p_full_name), 'role', p_role),
          now(), now(), '', '', '', '');

  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text,
          jsonb_build_object('sub', uid::text, 'email', e, 'email_verified', true, 'phone_verified', false),
          'email', now(), now(), now());
  return uid;
end $$;

-- Ganti password: Manager/Admin untuk siapa saja, karyawan untuk dirinya sendiri
create or replace function public.set_employee_password(p_id uuid, p_password text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if auth.uid() is not null and auth.uid() <> p_id and coalesce(public.my_role(), '') not in ('Manager','Admin') then
    raise exception 'Hanya Manager atau Admin yang bisa mengganti password karyawan lain.' using errcode = '42501';
  end if;
  if coalesce(length(p_password), 0) < 8 then raise exception 'Password minimal 8 karakter.'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
  where id = p_id;
  if not found then raise exception 'Karyawan tidak ditemukan.'; end if;
end $$;

-- Hanya Manager/Admin yang boleh mengubah peran atau status aktif
create or replace function public.profiles_guard() returns trigger
language plpgsql as $$
begin
  if auth.uid() is null then return new; end if;
  if coalesce(public.my_role(), '') not in ('Manager','Admin') then
    raise exception 'Hanya Manager atau Admin yang bisa mengubah data karyawan.' using errcode = '42501';
  end if;
  if new.id = auth.uid() and (new.active is distinct from old.active or new.role is distinct from old.role) then
    raise exception 'Anda tidak bisa menonaktifkan atau mengubah peran akun sendiri.';
  end if;
  new.id := old.id; new.email := old.email; new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

-- ---------------------------------------------------------------------
-- Kolom audit (dipakai semua tabel data)
-- ---------------------------------------------------------------------
create or replace function public.touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  if tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  else
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 2. Data master
-- ---------------------------------------------------------------------
create sequence if not exists public.customer_seq;

create table if not exists public.customers (
  id             uuid primary key default gen_random_uuid(),
  partner_id     text not null unique default ('CUST-' || lpad(nextval('public.customer_seq')::text, 4, '0')),
  name           text not null check (length(trim(name)) > 0),
  type           text not null default 'Company' check (type in ('Company','Individual')),
  address        text,
  phone          text,
  mobile         text,
  email          text,
  tags           text[] not null default '{}',
  npwp           text,
  provision_pct  numeric(6,2) not null default 0 check (provision_pct >= 0),
  cod_pct        numeric(6,2) not null default 0 check (cod_pct >= 0),
  top_pct        numeric(6,2) not null default 0 check (top_pct >= 0),
  trading_pct    numeric(6,2) not null default 0 check (trading_pct >= 0),
  contact        text,
  job            text,
  ar_account     text,
  ap_account     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid,
  updated_by     uuid
);

create or replace function public.customers_keep_partner_id() returns trigger
language plpgsql as $$
begin
  new.partner_id := old.partner_id;
  return new;
end $$;

create table if not exists public.products (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique check (length(trim(code)) > 0),
  name         text not null check (length(trim(name)) > 0),
  category     text,
  uom          text not null default 'unit',
  cogs         numeric(16,2) not null check (cogs > 0),
  description  text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid
);

-- ---------------------------------------------------------------------
-- 3. CRM
-- ---------------------------------------------------------------------
create table if not exists public.leads (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(trim(name)) > 0),
  probability  numeric(5,2) not null default 10 check (probability between 0 and 100),
  customer_id  uuid references public.customers(id) on delete set null,
  company      text,
  address      text,
  website      text,
  language     text,
  contact      text,
  email        text,
  email_cc     text,
  job          text,
  phone        text,
  mobile       text,
  salesperson  text,
  team         text,
  priority     text not null default 'Normal' check (priority in ('Low','Normal','High','Very High')),
  tags         text[] not null default '{}',
  description  text,
  campaign     text,
  medium       text,
  source       text,
  referred_by  text,
  status       text not null default 'Baru' check (status in ('Baru','Dikonversi')),
  opp_id       uuid,
  created_on   date not null default current_date,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid
);

create table if not exists public.opportunities (
  id                uuid primary key default gen_random_uuid(),
  name              text not null check (length(trim(name)) > 0),
  revenue           numeric(18,2) not null default 0 check (revenue >= 0),
  probability       numeric(5,2) not null default 10 check (probability between 0 and 100),
  customer_id       uuid references public.customers(id) on delete set null,
  email             text,
  phone             text,
  salesperson       text,
  team              text,
  expected_closing  date,
  priority          text not null default 'Normal' check (priority in ('Low','Normal','High','Very High')),
  tags              text[] not null default '{}',
  description       text,
  company           text,
  address           text,
  website           text,
  language          text,
  contact           text,
  job               text,
  mobile            text,
  campaign          text,
  medium            text,
  source            text,
  days_assign       numeric(8,2) not null default 0,
  days_close        numeric(8,2) not null default 0,
  days_to_opp       numeric(8,2) not null default 0,
  referred_by       text,
  stage             smallint not null default 0 check (stage between 0 and 7),
  lead_id           uuid references public.leads(id) on delete set null,
  created_on        date not null default current_date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid,
  updated_by        uuid
);

do $$ begin
  alter table public.leads add constraint leads_opp_id_fkey
    foreign key (opp_id) references public.opportunities(id) on delete set null;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- 4. Penjualan
-- ---------------------------------------------------------------------
create table if not exists public.so_counters (
  period   text primary key,          -- 'YYYY/MM', nomor direset tiap bulan
  last_no  integer not null
);

create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  number          text unique,
  customer_id     uuid not null references public.customers(id),
  invoice_addr    text,
  delivery_addr   text,
  expiration      date,
  pricelist       text,
  order_date      date not null default current_date,
  payment_term    text not null,
  payment_method  text not null check (payment_method in ('GIRO','Transfer')),
  payment_type    text not null check (payment_type in ('CBD','COD','TOP')),
  delivery_type   text not null check (delivery_type in ('Self pick-up','Supplier delivery')),
  service_type    text not null check (service_type in ('Express','Normal')),
  salesperson     text,
  team            text,
  source          text,
  customer_ref    text,
  status          text not null default 'Quotation' check (status in
                    ('Quotation','Quotation Sent','Giro Receipt','Giro OK','Giro Reject','Pro Forma INV Sent','Sales Order','BAST')),
  giro            jsonb,
  bast            jsonb not null default '{}'::jsonb,
  approval        jsonb,
  sent_count      integer not null default 0,
  delivered       boolean not null default false,
  opp_id          uuid references public.opportunities(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid,
  updated_by      uuid,
  constraint orders_top_needs_giro check (not (payment_type = 'TOP' and payment_method = 'Transfer'))
);
create index if not exists orders_customer_idx on public.orders(customer_id);
create index if not exists orders_opp_idx on public.orders(opp_id);

create table if not exists public.order_lines (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  sort           integer not null default 0,
  product_id     uuid not null references public.products(id),
  description    text,
  cogs           numeric(16,2) not null check (cogs > 0),
  provision_pct  numeric(6,2) not null default 0,
  cod_pct        numeric(6,2) not null default 0,
  top_pct        numeric(6,2) not null default 0,
  trading_pct    numeric(6,2) not null default 0,
  qty            numeric(14,2) not null check (qty > 0),
  price          numeric(16,2) not null check (price > 0),
  tax_pct        numeric(5,2) not null default 11 check (tax_pct in (0, 11)),
  disc_pct       numeric(5,2) not null default 0 check (disc_pct between 0 and 100),
  manual_price   boolean not null default false
);
create index if not exists order_lines_order_idx on public.order_lines(order_id);

create table if not exists public.order_log (
  id        uuid primary key default gen_random_uuid(),
  order_id  uuid not null references public.orders(id) on delete cascade,
  at        timestamptz not null default now(),
  by_name   text,
  text      text not null,
  status    text,
  synced    boolean not null default false
);
create index if not exists order_log_order_idx on public.order_log(order_id, at desc);

create table if not exists public.activity (
  id         uuid primary key default gen_random_uuid(),
  at         timestamptz not null default now(),
  by_name    text,
  text       text not null,
  ref_model  text check (ref_model in ('order','opp','lead','customer','product')),
  ref_id     uuid,
  synced     boolean not null default false
);
create index if not exists activity_at_idx on public.activity(at desc);

-- ---------------------------------------------------------------------
-- 5. Aturan PRD di server
-- ---------------------------------------------------------------------

-- Nomor SO/YYYY/MM/XXXX, direset tiap bulan, aman untuk banyak pengguna sekaligus
create or replace function public.next_so_number(d date) returns text
language plpgsql security definer set search_path = public as $$
declare k text := to_char(d, 'YYYY/MM'); n integer;
begin
  insert into public.so_counters (period, last_no) values (k, 1)
  on conflict (period) do update set last_no = public.so_counters.last_no + 1
  returning last_no into n;
  return 'SO/' || k || '/' || lpad(n::text, 4, '0');
end $$;

create or replace function public.orders_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    if new.status <> 'Quotation' then raise exception 'Dokumen baru harus berstatus Quotation.'; end if;
    new.sent_count := 0; new.delivered := false; new.approval := null; new.giro := null; new.number := null;
  end if;
  if coalesce(new.number, '') = '' then
    new.number := public.next_so_number(coalesce(new.order_date, current_date));
  end if;
  return new;
end $$;

create or replace function public.orders_guard() returns trigger
language plpgsql as $$
declare
  r        text := coalesce(public.my_role(), '');
  is_top   boolean := new.payment_type = 'TOP';
  oa       jsonb := old.approval;
  na       jsonb := new.approval;
  oa_done  boolean := coalesce(old.approval->>'manager','') <> '' and coalesce(old.approval->>'cluster','') <> '';
  allowed  text[];
begin
  if auth.uid() is null then return new; end if;   -- admin / SQL Editor
  new.number := old.number;

  -- Sales Order terkunci
  if old.status in ('Sales Order','BAST') then
    if (new.customer_id, new.invoice_addr, new.delivery_addr, new.expiration, new.pricelist, new.order_date,
        new.payment_term, new.payment_method, new.payment_type, new.delivery_type, new.service_type,
        new.salesperson, new.team, new.source, new.customer_ref, new.giro, new.sent_count, new.approval, new.opp_id)
       is distinct from
       (old.customer_id, old.invoice_addr, old.delivery_addr, old.expiration, old.pricelist, old.order_date,
        old.payment_term, old.payment_method, old.payment_type, old.delivery_type, old.service_type,
        old.salesperson, old.team, old.source, old.customer_ref, old.giro, old.sent_count, old.approval, old.opp_id) then
      raise exception 'Sales Order sudah terkunci dan tidak bisa diedit.';
    end if;
    if old.status = 'BAST' and (new.status <> 'BAST' or new.bast is distinct from old.bast or new.delivered is distinct from old.delivered) then
      raise exception 'Dokumen sudah BAST dan tidak bisa diubah.';
    end if;
  end if;
  if old.delivered and not new.delivered then raise exception 'Status pengiriman tidak bisa dibatalkan.'; end if;
  if new.delivered and not old.delivered and new.status <> 'Sales Order' then
    raise exception 'Pengiriman hanya bisa ditandai pada Sales Order.';
  end if;
  if new.bast is distinct from old.bast and not new.delivered then
    raise exception 'Tab BAST baru bisa diisi setelah pengiriman selesai.';
  end if;

  -- Tipe dan metode pembayaran terkunci setelah quotation dikirim
  if old.status <> 'Quotation' and (new.payment_type <> old.payment_type or new.payment_method <> old.payment_method) then
    raise exception 'Payment Type dan Payment Method terkunci setelah quotation dikirim.';
  end if;

  -- Alur status sesuai PRD
  if new.status <> old.status then
    allowed := case old.status
      when 'Quotation'          then array['Quotation Sent']
      when 'Quotation Sent'     then case when is_top then array['Giro Receipt'] else array['Pro Forma INV Sent'] end
      when 'Giro Receipt'       then array['Giro OK','Giro Reject']
      when 'Giro Reject'        then array['Giro Receipt']
      when 'Giro OK'            then array['Pro Forma INV Sent']
      when 'Pro Forma INV Sent' then array['Sales Order']
      when 'Sales Order'        then array['BAST']
      else array[]::text[] end;
    if not (new.status = any(allowed)) then
      if old.status = 'Quotation Sent' and is_top and new.status = 'Pro Forma INV Sent' then
        raise exception 'Pembayaran TOP wajib Terima Giro dan berstatus Giro OK sebelum lanjut.';
      end if;
      raise exception 'Perubahan status dari % ke % tidak diizinkan.', old.status, new.status;
    end if;
    if new.status = 'Giro Receipt' and (coalesce(new.giro->>'no','') = '' or coalesce(new.giro->>'bank','') = ''
        or coalesce(new.giro->>'due','') = '' or coalesce((new.giro->>'amount')::numeric, 0) <= 0) then
      raise exception 'Data giro (nomor, bank, jatuh tempo, nominal) wajib diisi.';
    end if;
    if new.status = 'BAST' then
      if not new.delivered then raise exception 'BAST hanya bisa diterbitkan setelah pengiriman selesai.'; end if;
      if coalesce(new.bast->>'date','') = ''
         or coalesce(new.bast#>>'{p1,nama}','') = '' or coalesce(new.bast#>>'{p1,jabatan}','') = ''
         or coalesce(new.bast#>>'{p1,perusahaan}','') = '' or coalesce(new.bast#>>'{p1,alamat}','') = ''
         or coalesce(new.bast#>>'{p2,nama}','') = '' or coalesce(new.bast#>>'{p2,jabatan}','') = ''
         or coalesce(new.bast#>>'{p2,perusahaan}','') = '' or coalesce(new.bast#>>'{p2,alamat}','') = '' then
        raise exception 'Lengkapi data BAST (tanggal, Pihak Pertama dan Pihak Kedua).';
      end if;
    end if;
  end if;

  -- Jumlah pengiriman quotation
  if new.sent_count <> old.sent_count then
    if old.status = 'Quotation' and new.status = 'Quotation Sent' then
      new.sent_count := 1;
    elsif old.status = 'Quotation Sent' and new.status = 'Quotation Sent' and new.sent_count = old.sent_count + 1 then
      if not oa_done then raise exception 'Kirim ulang quotation butuh persetujuan Manager dan Cluster.'; end if;
    else
      raise exception 'Jumlah pengiriman quotation tidak bisa diubah langsung.';
    end if;
  elsif old.status = 'Quotation' and new.status = 'Quotation Sent' then
    new.sent_count := 1;
  end if;

  -- Persetujuan kirim ulang (Manager + Cluster)
  if na is distinct from oa then
    if oa is null then
      if new.status <> 'Quotation Sent' or coalesce(na->>'manager','') <> '' or coalesce(na->>'cluster','') <> '' then
        raise exception 'Permintaan kirim ulang tidak valid.';
      end if;
      new.approval := jsonb_build_object('by', public.my_name(), 'manager', '', 'cluster', '');
    elsif na is null then
      if new.sent_count = old.sent_count + 1 and oa_done then
        null;                                   -- dipakai untuk kirim ulang
      elsif r in ('Manager','Cluster','Admin') and not oa_done then
        null;                                   -- ditolak
      else
        raise exception 'Hanya Manager atau Cluster yang bisa menolak permintaan kirim ulang.';
      end if;
    else
      if na->>'by' is distinct from oa->>'by' then raise exception 'Pengaju kirim ulang tidak bisa diubah.'; end if;
      if coalesce(na->>'manager','') <> coalesce(oa->>'manager','') then
        if r not in ('Manager','Admin') or coalesce(oa->>'manager','') <> '' then
          raise exception 'Persetujuan Manager hanya bisa diberikan oleh Manager.';
        end if;
        na := jsonb_set(na, '{manager}', to_jsonb(public.my_name()));
      end if;
      if coalesce(na->>'cluster','') <> coalesce(oa->>'cluster','') then
        if r not in ('Cluster','Admin') or coalesce(oa->>'cluster','') <> '' then
          raise exception 'Persetujuan Cluster hanya bisa diberikan oleh Cluster.';
        end if;
        na := jsonb_set(na, '{cluster}', to_jsonb(public.my_name()));
      end if;
      new.approval := na;
    end if;
  end if;
  return new;
end $$;

create or replace function public.order_lines_guard() returns trigger
language plpgsql as $$
declare st text;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  select status into st from public.orders where id = coalesce(new.order_id, old.order_id);
  if st in ('Sales Order','BAST') then
    raise exception 'Sales Order sudah terkunci dan tidak bisa diedit.';
  end if;
  return coalesce(new, old);
end $$;

-- Simpan quotation/SO beserta baris dan riwayatnya dalam satu transaksi
create or replace function public.save_order(p jsonb) returns jsonb
language plpgsql set search_path = public as $$
declare
  x    jsonb := p->'order';
  oid  uuid := (p->'order'->>'id')::uuid;
  o    public.orders;
  isnew boolean;
begin
  isnew := not exists (select 1 from public.orders where id = oid);
  if isnew then
    insert into public.orders (id, customer_id, invoice_addr, delivery_addr, expiration, pricelist, order_date,
      payment_term, payment_method, payment_type, delivery_type, service_type, salesperson, team, source,
      customer_ref, status, giro, bast, approval, sent_count, delivered, opp_id)
    values (oid, (x->>'customer_id')::uuid, x->>'invoice_addr', x->>'delivery_addr', nullif(x->>'expiration','')::date,
      x->>'pricelist', coalesce(nullif(x->>'order_date','')::date, current_date),
      x->>'payment_term', x->>'payment_method', x->>'payment_type', x->>'delivery_type', x->>'service_type',
      x->>'salesperson', x->>'team', x->>'source', x->>'customer_ref', coalesce(nullif(x->>'status',''), 'Quotation'),
      nullif(x->'giro', 'null'::jsonb), coalesce(nullif(x->'bast', 'null'::jsonb), '{}'::jsonb),
      nullif(x->'approval', 'null'::jsonb), coalesce((x->>'sent_count')::int, 0),
      coalesce((x->>'delivered')::boolean, false), nullif(x->>'opp_id','')::uuid)
    returning * into o;
  else
    update public.orders set
      customer_id = (x->>'customer_id')::uuid, invoice_addr = x->>'invoice_addr', delivery_addr = x->>'delivery_addr',
      expiration = nullif(x->>'expiration','')::date, pricelist = x->>'pricelist',
      order_date = coalesce(nullif(x->>'order_date','')::date, order_date),
      payment_term = x->>'payment_term', payment_method = x->>'payment_method', payment_type = x->>'payment_type',
      delivery_type = x->>'delivery_type', service_type = x->>'service_type', salesperson = x->>'salesperson',
      team = x->>'team', source = x->>'source', customer_ref = x->>'customer_ref', status = x->>'status',
      giro = nullif(x->'giro', 'null'::jsonb), bast = coalesce(nullif(x->'bast', 'null'::jsonb), '{}'::jsonb),
      approval = nullif(x->'approval', 'null'::jsonb), sent_count = coalesce((x->>'sent_count')::int, sent_count),
      delivered = coalesce((x->>'delivered')::boolean, delivered), opp_id = nullif(x->>'opp_id','')::uuid
    where id = oid
    returning * into o;
  end if;
  if o.id is null then raise exception 'Dokumen tidak ditemukan atau Anda tidak punya akses.'; end if;

  if o.status not in ('Sales Order','BAST') then
    delete from public.order_lines
     where order_id = oid
       and id <> all (select (l->>'id')::uuid from jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) l);
    insert into public.order_lines (id, order_id, sort, product_id, description, cogs, provision_pct, cod_pct,
                                   top_pct, trading_pct, qty, price, tax_pct, disc_pct, manual_price)
    select (l->>'id')::uuid, oid, (t.ord - 1)::int, (l->>'product_id')::uuid, l->>'description',
           (l->>'cogs')::numeric, coalesce((l->>'provision_pct')::numeric, 0), coalesce((l->>'cod_pct')::numeric, 0),
           coalesce((l->>'top_pct')::numeric, 0), coalesce((l->>'trading_pct')::numeric, 0),
           (l->>'qty')::numeric, (l->>'price')::numeric, coalesce((l->>'tax_pct')::numeric, 11),
           coalesce((l->>'disc_pct')::numeric, 0), coalesce((l->>'manual_price')::boolean, false)
      from jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) with ordinality as t(l, ord)
    on conflict (id) do update set
      sort = excluded.sort, product_id = excluded.product_id, description = excluded.description, cogs = excluded.cogs,
      provision_pct = excluded.provision_pct, cod_pct = excluded.cod_pct, top_pct = excluded.top_pct,
      trading_pct = excluded.trading_pct, qty = excluded.qty, price = excluded.price, tax_pct = excluded.tax_pct,
      disc_pct = excluded.disc_pct, manual_price = excluded.manual_price
    where public.order_lines.order_id = oid;
  end if;

  insert into public.order_log (id, order_id, at, by_name, text, status, synced)
  select (g->>'id')::uuid, oid, coalesce(nullif(g->>'at','')::timestamptz, now()), g->>'by_name', g->>'text',
         nullif(g->>'status',''), coalesce((g->>'synced')::boolean, false)
    from jsonb_array_elements(coalesce(p->'log', '[]'::jsonb)) g
  on conflict (id) do nothing;

  return to_jsonb(o);
end $$;

-- Triggers
drop trigger if exists customers_touch on public.customers;
create trigger customers_touch before insert or update on public.customers for each row execute function public.touch();
drop trigger if exists customers_keep_partner on public.customers;
create trigger customers_keep_partner before update on public.customers for each row execute function public.customers_keep_partner_id();
drop trigger if exists products_touch on public.products;
create trigger products_touch before insert or update on public.products for each row execute function public.touch();
drop trigger if exists leads_touch on public.leads;
create trigger leads_touch before insert or update on public.leads for each row execute function public.touch();
drop trigger if exists opportunities_touch on public.opportunities;
create trigger opportunities_touch before insert or update on public.opportunities for each row execute function public.touch();
drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before insert or update on public.orders for each row execute function public.touch();
drop trigger if exists orders_before_insert on public.orders;
create trigger orders_before_insert before insert on public.orders for each row execute function public.orders_before_insert();
drop trigger if exists orders_guard on public.orders;
create trigger orders_guard before update on public.orders for each row execute function public.orders_guard();
drop trigger if exists order_lines_guard on public.order_lines;
create trigger order_lines_guard before insert or update or delete on public.order_lines for each row execute function public.order_lines_guard();

-- ---------------------------------------------------------------------
-- 6. Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.customers     enable row level security;
alter table public.products      enable row level security;
alter table public.leads         enable row level security;
alter table public.opportunities enable row level security;
alter table public.orders        enable row level security;
alter table public.order_lines   enable row level security;
alter table public.order_log     enable row level security;
alter table public.activity      enable row level security;
alter table public.so_counters   enable row level security;

do $$
declare t text;
begin
  -- Karyawan aktif: baca, tambah, ubah. Hapus: Manager/Admin.
  foreach t in array array['customers','products','leads','opportunities','orders'] loop
    execute format('drop policy if exists "staff read" on public.%I', t);
    execute format('drop policy if exists "staff insert" on public.%I', t);
    execute format('drop policy if exists "staff update" on public.%I', t);
    execute format('drop policy if exists "manager delete" on public.%I', t);
    execute format('create policy "staff read" on public.%I for select to authenticated using (public.is_active())', t);
    execute format('create policy "staff insert" on public.%I for insert to authenticated with check (public.is_active())', t);
    execute format('create policy "staff update" on public.%I for update to authenticated using (public.is_active()) with check (public.is_active())', t);
    execute format('create policy "manager delete" on public.%I for delete to authenticated using (public.my_role() in (''Manager'',''Admin''))', t);
  end loop;
end $$;

drop policy if exists "staff all" on public.order_lines;
create policy "staff all" on public.order_lines for all to authenticated
  using (public.is_active()) with check (public.is_active());

drop policy if exists "staff read" on public.order_log;
drop policy if exists "staff insert" on public.order_log;
create policy "staff read" on public.order_log for select to authenticated using (public.is_active());
create policy "staff insert" on public.order_log for insert to authenticated with check (public.is_active());

drop policy if exists "staff read" on public.activity;
drop policy if exists "staff insert" on public.activity;
create policy "staff read" on public.activity for select to authenticated using (public.is_active());
create policy "staff insert" on public.activity for insert to authenticated with check (public.is_active());

drop policy if exists "staff read" on public.profiles;
drop policy if exists "self read" on public.profiles;
drop policy if exists "manager update" on public.profiles;
create policy "staff read" on public.profiles for select to authenticated using (public.is_active());
create policy "self read" on public.profiles for select to authenticated using (id = auth.uid());
create policy "manager update" on public.profiles for update to authenticated
  using (public.my_role() in ('Manager','Admin')) with check (public.my_role() in ('Manager','Admin'));

drop policy if exists "staff read" on public.so_counters;
create policy "staff read" on public.so_counters for select to authenticated using (public.is_active());

-- Hak akses
grant usage on schema public to anon, authenticated;
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke insert, update, delete on public.so_counters from authenticated;
revoke update, delete on public.order_log, public.activity from authenticated;
revoke insert, delete on public.profiles from authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_lookup(text) to anon, authenticated;
grant execute on function public.my_role(), public.my_name(), public.is_active() to authenticated;
grant execute on function public.create_employee(text,text,text,text,text) to authenticated;
grant execute on function public.set_employee_password(uuid,text) to authenticated;
grant execute on function public.save_order(jsonb) to authenticated;
revoke execute on function public.next_so_number(date) from authenticated;

-- ---------------------------------------------------------------------
-- 7. Realtime
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['customers','products','leads','opportunities','orders','order_lines','order_log','activity','profiles'] loop
      begin
        execute format('alter publication supabase_realtime add table public.%I', t);
      exception when duplicate_object then null;
      end;
    end loop;
  end if;
end $$;
