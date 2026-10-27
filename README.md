# Universe CRM

CRM berbahasa Indonesia berdasarkan PRD CRM Universe (implementasi Odoo). Halaman ini statis dan bisa langsung di-hosting di GitHub Pages. Datanya tersimpan di **Supabase** (PostgreSQL), lengkap dengan login karyawan.

- **Tanpa `config.js` terisi**, aplikasi berjalan sebagai **demo**: data contoh disimpan di browser dan kembali seperti semula saat halaman dimuat ulang.
- **Dengan `config.js` terisi**, aplikasi menyimpan semua data ke Supabase. Data bisa dipakai bersama oleh seluruh tim, dan perubahan dari pengguna lain langsung muncul.

## Fitur

- **Dasbor**: kubus 3D Universe, tim sales, expected revenue per tim, revenue per tahap, KPI dari PRD (Leads, % Opportunities, Expected/Prorated Revenue, Days to Assign/Opportunity/Close), statistik mingguan/bulanan, daftar "Perlu tindakan", pipeline 3D P0–P7, agenda mingguan, peluang teratas, dan aktivitas.
- **Leads**: buat lead lalu konversi menjadi peluang di P0.
- **Peluang (P0–P7)**: kanban dengan drag and drop, tersambung ke pipeline 3D.
- **Quotation & Sales Order**:
  - Alur status: Quotation → Quotation Sent → Giro Receipt → Giro OK / Giro Reject → Pro Forma INV Sent → Sales Order → BAST.
  - Pembayaran TOP wajib lewat Giro; Transfer hanya untuk CBD/COD.
  - Kirim ulang quotation butuh persetujuan Manager + Cluster.
  - Nomor `SO/YYYY/MM/XXXX` direset tiap bulan.
  - Sales Order terkunci setelah disubmit; tab BAST terbuka setelah pengiriman selesai.
  - Pratinjau cetak Quotation, Pro Forma Invoice dan BAST.
- **Pelanggan / Produk**: data master; pricing rules pelanggan otomatis masuk ke baris order.
- **Laporan CRM**: analisis peluang per tahap, salesperson, tim, medium, source atau prioritas.
- **Karyawan** (Manager/Admin): tambah akun, ubah peran, aktif/nonaktifkan, ganti password.

## Backend (Supabase)

Semua aturan penting dijaga di database, bukan hanya di tampilan:

| Aturan | Dijaga oleh |
|---|---|
| Hanya karyawan aktif yang bisa membaca/menulis data | Row Level Security |
| Login dengan username | fungsi `login_lookup` |
| Akun baru hanya dari Manager/Admin; pendaftaran mandiri otomatis nonaktif | `create_employee`, trigger `handle_new_user` |
| Nomor SO berurutan dan aman dipakai banyak orang sekaligus | `next_so_number` + tabel `so_counters` |
| Alur status, Giro untuk TOP, Transfer hanya CBD/COD | trigger `orders_guard`, constraint |
| Persetujuan kirim ulang hanya oleh Manager dan Cluster | trigger `orders_guard` |
| Sales Order dan barisnya terkunci, BAST final | trigger `orders_guard`, `order_lines_guard` |
| Riwayat dan aktivitas tidak bisa diubah atau dihapus | hak akses tabel |
| Quotation + baris + riwayat tersimpan dalam satu transaksi | fungsi `save_order` |

File di folder `supabase/`:

- `schema.sql`: tabel, aturan, keamanan dan realtime. Aman dijalankan ulang.
- `seed.sql`: data contoh (8 pelanggan, 10 produk, 8 leads, 18 peluang, 8 quotation/SO). Opsional.
- `employees.sql`: akun karyawan awal.

## Cara memasang

1. **Buat proyek** di [supabase.com](https://supabase.com/dashboard). Pilih region Southeast Asia (Singapore).
2. **Jalankan SQL**: buka **SQL Editor → New query**, tempel isi `supabase/schema.sql`, lalu klik **Run**. Lakukan hal yang sama untuk `supabase/seed.sql` (kalau mau data contoh) dan `supabase/employees.sql`. Minimal harus ada satu akun **Manager** atau **Admin**.
3. **Matikan pendaftaran publik**: buka **Authentication → Sign In / Providers**, lalu matikan **Allow new users to sign up**. Akun cukup dibuat dari halaman Karyawan.
4. **Isi `config.js`** dengan **Project URL** dan **publishable/anon key** dari **Project Settings → API**. Commit ke branch `main`, dan GitHub Pages akan memperbarui situs dalam 1–2 menit.

```js
window.UNIVERSE_CONFIG = {
  supabaseUrl: 'https://xxxxxxxxxxxx.supabase.co',
  supabaseAnonKey: 'sb_publishable_...'
};
```

Publishable/anon key memang dirancang untuk dipasang di website. Jangan pernah memasang `service_role` / secret key atau password database di repo ini.

## Mengelola karyawan

- **Dari aplikasi**: login sebagai Manager/Admin, buka menu **Karyawan** (ikon kartu nama di sidebar), lalu klik **Karyawan baru**.
- **Dari SQL Editor**:

  ```sql
  select public.create_employee('rina', 'Rina Kartika', 'Sales', 'rina@universedigital.id', 'PasswordAwal123');
  ```

- Setiap karyawan bisa mengganti password sendiri lewat ikon kunci di sidebar.
- Karyawan yang dinonaktifkan tidak bisa login dan tidak bisa melihat data.

## Menghapus data contoh

Jalankan di SQL Editor saat siap memakai data asli. Akun karyawan tidak ikut terhapus.

```sql
truncate public.activity, public.order_log, public.order_lines, public.orders,
         public.opportunities, public.leads, public.customers, public.products;
delete from public.so_counters;
select setval('public.customer_seq', 1, false);
```

## Catatan

- Belum tersambung ke Odoo. Status "Tersimpan" menunjukkan data sudah masuk ke Supabase.
- Layout cetak Quotation, Pro Forma Invoice dan BAST masih contoh sampai desain resmi Universe tersedia.
- Halaman pencarian username (`login_lookup`) memberi tahu email dari sebuah username. Ini wajar untuk CRM internal. Kalau tidak diinginkan, login bisa diubah memakai email.
- Library dari CDN: Three.js r128 (cdnjs) dan supabase-js 2.117.3 (jsDelivr). Font dari Google Fonts.

## Menjalankan di komputer

```bash
python3 -m http.server 8000
# buka http://localhost:8000
```
