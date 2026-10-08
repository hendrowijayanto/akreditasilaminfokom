# Pedoman Instalasi dengan Apache + phpMyAdmin

Sistem Informasi Akreditasi Prodi TI, Sekolah Vokasi Universitas Tiga Serangkai (Laravel 11).
Pedoman ini melengkapi `README.md` (yang memakai Nginx). Di sini web server-nya **Apache** dan basis datanya dikelola lewat **phpMyAdmin**.

Isi:
- Bagian A: Ubuntu Server (Apache + MySQL + phpMyAdmin)
- Bagian B: Windows dengan XAMPP (paling mudah, sudah berisi Apache + MySQL/MariaDB + phpMyAdmin)
- Bagian C: Windows dengan Laragon (alternatif)
- Bagian D: Pemasangan aplikasi (sama untuk semua jalur)
- Bagian E: Pemecahan masalah

Catatan penting: folder yang dilayani web server harus **`public/`** milik Laravel, bukan folder proyeknya.

---

## A. Ubuntu Server 22.04 / 24.04

### A1. Paket dasar
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y apache2 mysql-server unzip git curl perl
```

### A2. PHP 8.2 atau lebih baru
Ubuntu 24.04 sudah membawa PHP 8.3, langsung pakai:
```bash
sudo apt install -y php libapache2-mod-php php-mysql php-sqlite3 php-mbstring php-xml \
  php-curl php-zip php-gd php-intl php-bcmath
```
Ubuntu 22.04 hanya punya PHP 8.1, jadi tambahkan PPA dulu:
```bash
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:ondrej/php
sudo apt update
sudo apt install -y php8.3 libapache2-mod-php8.3 php8.3-mysql php8.3-sqlite3 php8.3-mbstring \
  php8.3-xml php8.3-curl php8.3-zip php8.3-gd php8.3-intl php8.3-bcmath
```
Cek: `php -v` (harus 8.2+) dan `php -m | grep -E "mbstring|xml|curl|zip|pdo_mysql"`.

### A3. Composer
```bash
curl -sS https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
composer --version
```

### A4. Amankan MySQL dan buat database
```bash
sudo mysql_secure_installation
sudo mysql
```
Di prompt MySQL (ganti sandi):
```sql
CREATE DATABASE akreditasi CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'akreditasi'@'localhost' IDENTIFIED BY 'SandiKuat_Ganti123!';
GRANT ALL PRIVILEGES ON akreditasi.* TO 'akreditasi'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```
Gunakan pengguna khusus ini (bukan `root`) untuk aplikasi dan untuk login phpMyAdmin. Pada Ubuntu, `root` MySQL memakai `auth_socket` sehingga umumnya tidak bisa login lewat phpMyAdmin.

### A5. Pasang phpMyAdmin
```bash
sudo apt install -y phpmyadmin
```
Saat dialog muncul:
1. Pilih server web **apache2** (tekan **Spasi** untuk menandai tanda `*`, lalu Enter).
2. "Configure database for phpmyadmin with dbconfig-common?" pilih **Yes**.
3. Isi sandi aplikasi phpMyAdmin (boleh kosongkan agar dibuat acak).

Jika dialog tidak menandai Apache, jalankan:
```bash
sudo ln -s /etc/phpmyadmin/apache.conf /etc/apache2/conf-available/phpmyadmin.conf
sudo a2enconf phpmyadmin
```
Aktifkan modul dan muat ulang:
```bash
sudo phpenmod mbstring
sudo a2enmod rewrite headers ssl
sudo systemctl restart apache2
```
Uji: buka `http://IP-SERVER/phpmyadmin`, login dengan pengguna `akreditasi`.

### A6. Siapkan folder aplikasi
```bash
cd /var/www
sudo composer create-project "laravel/laravel:^11.0" akreditasi
sudo chown -R $USER:www-data /var/www/akreditasi
```

### A7. Virtual host Apache
```bash
sudo nano /etc/apache2/sites-available/akreditasi.conf
```
Isi (ganti `ServerName`):
```apache
<VirtualHost *:80>
    ServerName akreditasi.contoh.ac.id
    DocumentRoot /var/www/akreditasi/public

    <Directory /var/www/akreditasi/public>
        AllowOverride All
        Options -Indexes +FollowSymLinks
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/akreditasi-error.log
    CustomLog ${APACHE_LOG_DIR}/akreditasi-access.log combined
</VirtualHost>
```
Aktifkan:
```bash
sudo a2dissite 000-default.conf
sudo a2ensite akreditasi.conf
sudo apache2ctl configtest      # harus "Syntax OK"
sudo systemctl reload apache2
```
`AllowOverride All` wajib agar `public/.htaccess` Laravel berjalan (tanpanya semua halaman selain beranda berstatus 404).
Jika tanpa nama domain, hapus baris `ServerName` dan akses lewat IP.

phpMyAdmin tetap tersedia di `http://domain-Anda/phpmyadmin` karena konfigurasinya memakai `Alias`.

### A8. Atur `.env` lalu jalankan installer
```bash
cd /var/www/akreditasi
nano .env
```
Ubah bagian ini:
```
APP_NAME="Sistem Akreditasi"
APP_URL=http://akreditasi.contoh.ac.id
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=akreditasi
DB_USERNAME=akreditasi
DB_PASSWORD=SandiKuat_Ganti123!
```
Salin `akreditasi-lengkap.sh` ke folder itu, lalu:
```bash
bash akreditasi-lengkap.sh --produksi
```

### A9. Izin folder (untuk Apache = `www-data`)
```bash
cd /var/www/akreditasi
sudo chown -R www-data:www-data storage bootstrap/cache
sudo chmod -R 775 storage bootstrap/cache
sudo find app resources routes config database public -type f -exec chmod 644 {} \;
```
Jika muncul "Permission denied" saat membuka halaman, 99% penyebabnya ada di langkah ini.

### A10. HTTPS (disarankan)
```bash
sudo apt install -y certbot python3-certbot-apache
sudo certbot --apache -d akreditasi.contoh.ac.id
```
Setelah itu ubah `APP_URL` di `.env` menjadi `https://...` lalu `php artisan config:clear`.

### A11. Mengamankan phpMyAdmin (sangat disarankan di server publik)
Ganti alamat bawaan `/phpmyadmin` dan batasi akses:
```bash
sudo nano /etc/apache2/conf-available/phpmyadmin.conf
```
Ubah baris `Alias /phpmyadmin ...` menjadi, misalnya, `Alias /dbadmin-x7k2 /usr/share/phpmyadmin`, lalu di dalam `<Directory /usr/share/phpmyadmin>` tambahkan pembatasan IP (ganti dengan IP kampus/rumah Anda):
```apache
    Require ip 203.0.113.10 192.168.0.0/24
```
Terapkan: `sudo systemctl reload apache2`. Alternatif: tambahkan Basic Auth (`AuthType Basic`, `htpasswd`) atau pasang `ufw` yang hanya membuka port 80/443.

---

## B. Windows dengan XAMPP

### B1. Pasang XAMPP
1. Unduh XAMPP versi **PHP 8.2 atau lebih baru** dari apachefriends.org, pasang ke `C:\xampp` (hindari `C:\Program Files`).
2. Buka **XAMPP Control Panel** → Start **Apache** dan **MySQL**.
3. Jika port 80 bentrok (Skype, IIS, World Wide Web Publishing), hentikan layanan itu atau ubah port Apache di `Config > httpd.conf` (`Listen 8080`).
4. Uji: `http://localhost` (halaman XAMPP) dan `http://localhost/phpmyadmin`.

### B2. Daftarkan PHP ke PATH
1. Start → ketik "environment variables" → **Edit the system environment variables** → **Environment Variables**.
2. Pada `Path` (System) tambahkan `C:\xampp\php`.
3. Buka terminal baru, cek `php -v`.

### B3. Aktifkan ekstensi PHP
Buka `C:\xampp\php\php.ini`, pastikan baris berikut **tanpa tanda `;` di depan**:
```
extension=curl
extension=fileinfo
extension=gd
extension=intl
extension=mbstring
extension=openssl
extension=pdo_mysql
extension=pdo_sqlite
extension=zip
```
Dan naikkan batas unggah:
```
upload_max_filesize = 20M
post_max_size = 25M
max_execution_time = 120
memory_limit = 512M
```
Lalu **Stop → Start** Apache di Control Panel.

### B4. Pasang Composer dan Git
- Composer: unduh `Composer-Setup.exe` dari getcomposer.org (arahkan ke `C:\xampp\php\php.exe`).
- Git for Windows dari git-scm.com. Ini membawa **Git Bash** dan `perl` yang dibutuhkan installer `.sh`.

### B5. Buat database lewat phpMyAdmin
1. Buka `http://localhost/phpmyadmin` (default: pengguna `root`, sandi kosong).
2. Tab **Databases** → nama `akreditasi`, collation `utf8mb4_unicode_ci` → **Create**.
3. (Disarankan) tab **User accounts → Add user account**: nama `akreditasi`, host `localhost`, sandi bebas, centang "Grant all privileges on database akreditasi". Untuk pemakaian lokal, `root` tanpa sandi juga boleh.

### B6. Buat proyek Laravel
Buka **Git Bash**:
```bash
cd /c/xampp/htdocs
composer create-project "laravel/laravel:^11.0" akreditasi
```

### B7. Virtual host (agar alamatnya `http://akreditasi.test`)
1. Buka Notepad **sebagai Administrator**, buka `C:\Windows\System32\drivers\etc\hosts`, tambahkan baris:
   ```
   127.0.0.1   akreditasi.test
   ```
2. Buka `C:\xampp\apache\conf\extra\httpd-vhosts.conf`, tambahkan di bagian bawah:
   ```apache
   <VirtualHost *:80>
       ServerName akreditasi.test
       DocumentRoot "C:/xampp/htdocs/akreditasi/public"
       <Directory "C:/xampp/htdocs/akreditasi/public">
           AllowOverride All
           Require all granted
       </Directory>
   </VirtualHost>

   <VirtualHost *:80>
       ServerName localhost
       DocumentRoot "C:/xampp/htdocs"
   </VirtualHost>
   ```
   Blok kedua menjaga `http://localhost` (dan `/phpmyadmin`) tetap bekerja.
3. Pastikan di `C:\xampp\apache\conf\httpd.conf` baris ini aktif (tanpa `#`):
   ```
   LoadModule rewrite_module modules/mod_rewrite.so
   Include conf/extra/httpd-vhosts.conf
   ```
4. **Stop → Start** Apache.

Tanpa virtual host, alternatifnya akses `http://localhost/akreditasi/public`, tetapi tautan dan aset bisa salah. Virtual host lebih dianjurkan.

### B8. Atur `.env` dan jalankan installer
Edit `C:\xampp\htdocs\akreditasi\.env`:
```
APP_URL=http://akreditasi.test
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=akreditasi
DB_USERNAME=root
DB_PASSWORD=
```
(Isi `DB_USERNAME`/`DB_PASSWORD` sesuai pengguna yang Anda buat di B5.)

Salin `akreditasi-lengkap.sh` ke folder proyek, buka **Git Bash** di folder itu:
```bash
cd /c/xampp/htdocs/akreditasi
bash akreditasi-lengkap.sh
```
Buka `http://akreditasi.test` dan login (lihat Bagian D).

---

## C. Windows dengan Laragon (alternatif)

1. Unduh **Laragon Full** (sudah berisi Apache, MySQL, PHP, Composer, Git). Pasang di `C:\laragon`.
2. Menu Laragon → **Apache** dan **MySQL** (bukan Nginx): `Menu > Preferences > Services & Ports` centang Apache dan MySQL, lalu **Start All**.
3. Pilih PHP 8.2+: `Menu > PHP > Version`. Ekstensi: `Menu > PHP > Extensions` (aktifkan `mbstring`, `curl`, `zip`, `gd`, `intl`, `pdo_mysql`, `fileinfo`, `openssl`).
4. phpMyAdmin: bila belum ada, `Menu > Tools > Quick add` (jika ada pilihan phpMyAdmin), atau unduh phpMyAdmin dari phpmyadmin.net lalu ekstrak ke `C:\laragon\etc\apps\phpMyAdmin`. Alternatif bawaan Laragon adalah HeidiSQL (`Menu > Database`).
5. Buat proyek: `Menu > Quick app > Laravel` (nama `akreditasi`), atau lewat terminal Laragon:
   ```bash
   cd C:\laragon\www
   composer create-project "laravel/laravel:^11.0" akreditasi
   ```
6. Laragon membuat host `http://akreditasi.test` otomatis (reload Apache bila perlu). Pastikan DocumentRoot menunjuk ke `...\akreditasi\public`.
7. Buat database `akreditasi`, atur `.env` seperti B8 (pengguna `root`, sandi kosong), lalu dari Git Bash/terminal Laragon:
   ```bash
   cd /c/laragon/www/akreditasi
   bash akreditasi-lengkap.sh
   ```

---

## D. Setelah terpasang

1. Buka alamat aplikasi, login: `admin@example.com` / `GantiSandiIni123`. **Segera ganti sandi.**
2. Cek **Analitik**, **LKPS**, dan unggah satu lampiran uji.
3. Di phpMyAdmin, buka database `akreditasi` dan pastikan tabel `kriteria`, `lkps_*`, dan lainnya sudah ada.
4. **Cadangan lewat phpMyAdmin:** pilih database → **Export** → metode *Quick*, format SQL → **Export**. Untuk memulihkan: **Import** pada database kosong. Berkas unggahan ada di `storage/app/public`, salin juga folder itu.
5. Batas unggah: bila phpMyAdmin Import gagal untuk berkas besar, naikkan `upload_max_filesize` dan `post_max_size` di `php.ini` (Ubuntu: `/etc/php/8.x/apache2/php.ini`, lalu `sudo systemctl restart apache2`).

---

## E. Pemecahan masalah

| Gejala | Penyebab umum | Solusi |
|---|---|---|
| Beranda tampil, halaman lain 404 | `AllowOverride None` atau `mod_rewrite` mati | Pakai `AllowOverride All`; Ubuntu: `sudo a2enmod rewrite`; XAMPP: aktifkan `LoadModule rewrite_module`. Restart Apache. |
| Muncul daftar folder / kode PHP tampil | DocumentRoot bukan `public/` atau PHP belum aktif | Arahkan ke `.../public`; Ubuntu: `sudo a2enmod php8.x` lalu restart. |
| `Permission denied` / error 500 | Izin `storage`, `bootstrap/cache`, atau file 0600 | Ubuntu: lihat A9. Bila perlu `chmod 644` pada file yang ditolak. |
| `could not find driver` | `pdo_mysql` belum aktif | Ubuntu: `sudo apt install php-mysql`; Windows: aktifkan `extension=pdo_mysql` lalu restart Apache. |
| `Access denied for user` | Pengguna/sandi `.env` salah | Samakan dengan pengguna di phpMyAdmin, lalu `php artisan config:clear`. |
| phpMyAdmin: `Access denied for user 'root'` (Ubuntu) | `root` memakai `auth_socket` | Login memakai pengguna `akreditasi` (A4). |
| phpMyAdmin 404 | Konfigurasi belum aktif | `sudo a2enconf phpmyadmin && sudo systemctl reload apache2`. |
| `AH00558` / `Could not reliably determine the server's name` | Hanya peringatan | Tambah `ServerName localhost` di `/etc/apache2/conf-available/servername.conf` lalu `sudo a2enconf servername`. |
| Apache XAMPP tidak mau start | Port 80/443 dipakai program lain | Matikan Skype/IIS atau ganti `Listen` di `httpd.conf`. |
| `akreditasi.test` tidak terbuka | Baris `hosts` belum ada atau Apache belum direstart | Cek B7, jalankan `ipconfig /flushdns`. |
| Aset (CSS) tidak termuat | `APP_URL` tidak sama dengan alamat yang dipakai | Samakan `APP_URL` di `.env`, lalu `php artisan config:clear`. |

Perintah berguna:
```bash
php artisan optimize:clear          # bersihkan semua cache
tail -f storage/logs/laravel.log    # lihat galat aplikasi
sudo tail -f /var/log/apache2/akreditasi-error.log   # galat Apache (Ubuntu)
```
Log Apache XAMPP: `C:\xampp\apache\logs\error.log`.

### Keamanan singkat
- Ganti sandi admin awal dan sandi database.
- Set `APP_ENV=production` dan `APP_DEBUG=false` di server publik (`--produksi` melakukannya).
- Jangan buka port 3306 (MySQL) ke internet. Batasi phpMyAdmin (A11) atau matikan bila tidak dipakai: `sudo a2disconf phpmyadmin`.
