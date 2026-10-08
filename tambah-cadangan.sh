#!/usr/bin/env bash
# =============================================================================
#  tambah-cadangan.sh
#  Menambah menu admin "Backup & Restore" (menu sendiri di sidebar, tepat di atas Bulk Document, hanya tampil untuk admin):
#   - Backup DATABASE + DOKUMEN menjadi satu berkas ZIP (satu klik)
#   - Unduh berkas backup ke komputer Anda
#   - Unggah berkas backup (mis. dari server lama) lalu RESTORE
#   - Restore dari backup yang tersimpan di server (dengan konfirmasi "RESTORE")
#   - Perintah terminal:  php artisan sia:cadangan [--simpan=7]   dan   php artisan sia:pulihkan BERKAS.zip
#
#  Isi cadangan: seluruh tabel aplikasi (Kriteria, narasi, dokumen, Data Induk, LKPS, pengguna) +
#  seluruh isi storage/app (dokumen Kriteria, Data Induk, lampiran LKPS, gambar narasi).
#  .env TIDAK ikut (berisi kata sandi); simpan terpisah. Bekerja di MySQL/MariaDB dan SQLite.
#
#  AMAN:
#   - Tidak ada migrasi dan tidak ada perubahan data saat dipasang. Halaman hanya untuk ADMIN.
#   - Restore: backup pengaman otomatis dibuat dulu; database diganti dalam SATU transaksi
#     (gagal di tengah = tidak ada perubahan); berkas ZIP diperiksa (sidik SHA-256, jalur aman,
#     skrip .php/.sh dan symlink tidak pernah dipulihkan).
#   - Berkas yang diubah dicadangkan *.bak19. Aman dijalankan ulang.
#  Pakai (di root proyek Laravel):  bash tambah-cadangan.sh
# =============================================================================
set -u
if [ ! -f artisan ]; then echo "Error: jalankan di root proyek Laravel."; exit 1; fi
for f in routes/web.php resources/views/layout.blade.php app/Http/Middleware/HanyaAdmin.php; do
  [ -f "$f" ] || { echo "Error: $f tidak ada. Pasang aplikasi dasar (dengan Kelola Pengguna) lebih dulu."; exit 1; }
done
MARK="CADANGAN-PEMULIHAN"
R=routes/web.php
L=resources/views/layout.blade.php

tulis() {   # tulis <path> (isi dari stdin): menimpa hanya berkas bertanda; cadangan *.bak19
  local f="$1" tmp; tmp=$(mktemp); cat > "$tmp"
  if [ -f "$f" ] && grep -q "$MARK" "$f" && cmp -s "$tmp" "$f"; then rm -f "$tmp"; chmod 644 "$f" 2>/dev/null || true; echo "  (sudah terbaru) $f"; return 0; fi
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ] && ! grep -q "$MARK" "$f"; then cp "$f" "$f.bak19"; fi
  cp "$tmp" "$f"; rm -f "$tmp"; chmod 644 "$f" 2>/dev/null || true
  echo "  OK  $f"
}

echo "[1/5] Menulis kelas cadangan, controller, perintah artisan, dan tampilan..."

tulis app/Support/CadanganSia.php <<'EOFCB1'
<?php
// CADANGAN-PEMULIHAN

namespace App\Support;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Cadangan & pemulihan Sistem Informasi Akreditasi.
 *
 * Satu berkas cadangan = satu ZIP berisi:
 *   manifest.json   : keterangan cadangan (format, tanggal, isi, jumlah baris per tabel, sidik SHA-256 database)
 *   database.jsonl  : isi tabel aplikasi (format JSON per baris; tanpa mysqldump, jalan di MySQL maupun SQLite)
 *   berkas/...      : seluruh isi storage/app (dokumen Kriteria, Data Induk, lampiran LKPS, gambar narasi),
 *                     kecuali folder cadangan itu sendiri.
 * .env TIDAK dimasukkan (berisi kata sandi); simpan terpisah.
 *
 * Pemulihan: struktur tabel mengikuti migrasi aplikasi yang sudah terpasang; isi tabel diganti dengan isi cadangan
 * dalam SATU transaksi (gagal di tengah = database tidak berubah). Berkas ditimpa bila namanya sama; berkas lain
 * dibiarkan. Sebelum memulihkan selalu dibuat cadangan pengaman otomatis.
 */
class CadanganSia
{
    public const FORMAT = 1;
    public const APLIKASI = 'SIA-AKREDITASI';
    /** Tabel yang tidak dicadangkan dan tidak pernah disentuh saat pemulihan. */
    public const ABAIKAN_TABEL = ['migrations', 'sessions', 'cache', 'cache_locks', 'jobs', 'job_batches', 'failed_jobs', 'password_reset_tokens'];
    /** Folder di storage/app yang tidak ikut dicadangkan. */
    public const ABAIKAN_DIR = ['cadangan', 'cadangan-sistem'];
    /** Ekstensi yang tidak pernah dipulihkan dari cadangan (mencegah skrip tersusupi lewat folder yang dapat diakses web). */
    public const TERLARANG = ['php', 'phtml', 'phar', 'pht', 'phps', 'php3', 'php4', 'php5', 'php7', 'php8', 'sh', 'bash', 'exe', 'bat', 'cmd', 'com', 'cgi', 'pl', 'py', 'htaccess', 'htpasswd', 'ini'];

    /** Pengganti lokasi storage/app (untuk uji). */
    public static ?string $akar = null;

    public static function akar(): string
    {
        return rtrim(self::$akar ?? storage_path('app'), '/\\');
    }

    public static function dir(): string
    {
        return self::akar() . '/cadangan-sistem';
    }

    // ------------------------------------------------------------------ kesiapan

    /** Pesan masalah bila lingkungan tidak mendukung; null bila siap. */
    public static function masalah(): ?string
    {
        if (! class_exists(\ZipArchive::class)) {
            return 'Ekstensi PHP "zip" belum aktif. Aktifkan ekstensi zip (Ubuntu: sudo apt install php-zip; cPanel: Select PHP Version, centang zip).';
        }
        $d = DB::connection()->getDriverName();
        if (! in_array($d, ['mysql', 'mariadb', 'sqlite'], true)) {
            return 'Database "' . $d . '" belum didukung (hanya MySQL/MariaDB dan SQLite).';
        }

        return null;
    }

    public static function ukuran(int $b): string
    {
        if ($b < 1024) {
            return $b . ' B';
        }
        $sat = ['KB', 'MB', 'GB', 'TB'];
        $v = $b / 1024;
        $i = 0;
        while ($v >= 1024 && $i < 3) {
            $v /= 1024;
            $i++;
        }

        return number_format($v, 1, ',', '.') . ' ' . $sat[$i];
    }

    private static function kunci()
    {
        if (! is_dir(self::dir())) {
            @mkdir(self::dir(), 0775, true);
        }
        self::lindungi();
        $f = @fopen(self::dir() . '/.kunci', 'c');
        if (! $f || ! flock($f, LOCK_EX | LOCK_NB)) {
            throw new \RuntimeException('Proses cadangan atau pemulihan lain sedang berjalan. Tunggu sampai selesai.');
        }

        return $f;
    }

    /** Folder cadangan tidak boleh dapat dibuka lewat web (selain itu ia memang di luar folder public). */
    private static function lindungi(): void
    {
        $d = self::dir();
        if (! is_file($d . '/.htaccess')) {
            @file_put_contents($d . '/.htaccess', "Require all denied\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n");
        }
        if (! is_file($d . '/index.html')) {
            @file_put_contents($d . '/index.html', '');
        }
    }

    private static function lepas($f): void
    {
        if (is_resource($f)) {
            flock($f, LOCK_UN);
            fclose($f);
        }
    }

    private static function bebas(): void
    {
        @set_time_limit(0);
        @ignore_user_abort(true);
        if ((int) ini_get('memory_limit') !== -1 && (int) ini_get('memory_limit') < 256) {
            @ini_set('memory_limit', '256M');
        }
    }

    // ------------------------------------------------------------------ daftar tabel / berkas

    public static function tabel(): array
    {
        $out = [];
        foreach (Schema::getTableListing() as $t) {
            $t = (string) $t;
            if (str_starts_with($t, 'sqlite_') || in_array($t, self::ABAIKAN_TABEL, true)) {
                continue;
            }
            $out[] = $t;
        }
        sort($out);

        return $out;
    }

    /** Daftar berkas yang akan dicadangkan: [relatif => mutlak]. */
    public static function berkas(): array
    {
        $akar = self::akar();
        if (! is_dir($akar)) {
            return [];
        }
        $out = [];
        $it = new \RecursiveIteratorIterator(
            new \RecursiveCallbackFilterIterator(
                new \RecursiveDirectoryIterator($akar, \FilesystemIterator::SKIP_DOTS),
                function (\SplFileInfo $f, $k, $iter) use ($akar) {
                    if ($f->isLink() || str_starts_with($f->getFilename(), '.')) {
                        return false;
                    }
                    $rel = ltrim(substr($f->getPathname(), strlen($akar)), '/\\');
                    $atas = explode('/', str_replace('\\', '/', $rel))[0];

                    return ! in_array($atas, self::ABAIKAN_DIR, true);
                }
            )
        );
        foreach ($it as $f) {
            if ($f->isFile() && ! str_ends_with($f->getFilename(), '.part')) {
                $out[str_replace('\\', '/', ltrim(substr($f->getPathname(), strlen($akar)), '/\\'))] = $f->getPathname();
            }
        }
        ksort($out);

        return $out;
    }

    public static function ringkasan(): array
    {
        $b = self::berkas();
        $uk = 0;
        foreach ($b as $p) {
            $uk += (int) @filesize($p);
        }
        $tbl = 0;
        $baris = 0;
        foreach (self::tabel() as $t) {
            $tbl++;
            $baris += (int) DB::table($t)->count();
        }
        $dir = is_dir(self::dir()) ? self::dir() : self::akar();

        return ['tabel' => $tbl, 'baris' => $baris, 'berkas' => count($b), 'ukuran' => $uk, 'bebas' => (int) @disk_free_space($dir)];
    }

    // ------------------------------------------------------------------ membuat cadangan

    private static function enc($v)
    {
        if ($v === null || is_int($v) || is_float($v)) {
            return $v;
        }
        if (is_bool($v)) {
            return (int) $v;
        }
        $v = (string) $v;

        return mb_check_encoding($v, 'UTF-8') ? $v : ['$b' => base64_encode($v)];
    }

    private static function dek($v)
    {
        return (is_array($v) && isset($v['$b'])) ? base64_decode((string) $v['$b'], true) : $v;
    }

    /** Tulis isi database ke berkas JSON-lines; mengembalikan jumlah baris per tabel. */
    private static function tulisDb(string $file): array
    {
        $fh = fopen($file, 'wb');
        if (! $fh) {
            throw new \RuntimeException('Tidak dapat menulis berkas sementara di ' . self::dir() . '. Periksa izin folder storage.');
        }
        $hitung = [];
        $opt = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES;
        foreach (self::tabel() as $t) {
            $kol = Schema::getColumnListing($t);
            if (! $kol) {
                continue;
            }
            $total = (int) DB::table($t)->count();
            fwrite($fh, json_encode(['tabel' => $t, 'kolom' => $kol, 'n' => $total], $opt) . "\n");
            $urut = in_array('id', $kol, true) ? 'id' : $kol[0];
            $n = 0;
            for ($o = 0; $o < $total; $o += 500) {
                $batch = [];
                $bytes = 0;
                foreach (DB::table($t)->orderBy($urut)->offset($o)->limit(500)->get() as $r) {
                    $baris = [];
                    foreach ($kol as $c) {
                        $baris[] = self::enc($r->$c ?? null);
                    }
                    $batch[] = $baris;
                    $n++;
                    $bytes += strlen(json_encode($baris, $opt));
                    if ($bytes > 1_000_000) {
                        fwrite($fh, json_encode(['t' => $t, 'r' => $batch], $opt) . "\n");
                        $batch = [];
                        $bytes = 0;
                    }
                }
                if ($batch) {
                    fwrite($fh, json_encode(['t' => $t, 'r' => $batch], $opt) . "\n");
                }
            }
            $hitung[$t] = $n;
        }
        fclose($fh);

        return $hitung;
    }

    /**
     * Membuat cadangan.
     * @return array{nama:string,path:string,ukuran:int,tabel:int,baris:int,berkas:int}
     */
    public static function buat(string $label = 'manual', bool $db = true, bool $berkas = true): array
    {
        if ($m = self::masalah()) {
            throw new \RuntimeException($m);
        }
        if (! $db && ! $berkas) {
            throw new \RuntimeException('Pilih minimal satu isi cadangan: database atau dokumen.');
        }
        self::bebas();
        $kunci = self::kunci();
        $dir = self::dir();
        $tmpDb = $dir . '/.db-' . bin2hex(random_bytes(4)) . '.jsonl';
        $part = null;
        try {
            $label = trim((string) preg_replace('/[^a-z0-9]+/', '-', strtolower($label)), '-') ?: 'manual';
            $nama = 'sia-' . substr($label, 0, 30) . '-' . date('Ymd-His');
            for ($i = 2; is_file("$dir/$nama.zip"); $i++) {
                $nama = 'sia-' . substr($label, 0, 30) . '-' . date('Ymd-His') . '-' . $i;
            }
            $hitung = [];
            $sidik = null;
            if ($db) {
                $hitung = self::tulisDb($tmpDb);
                $sidik = hash_file('sha256', $tmpDb);
            }
            $daftar = $berkas ? self::berkas() : [];
            $ukBerkas = 0;
            foreach ($daftar as $p) {
                $ukBerkas += (int) @filesize($p);
            }
            $manifest = [
                'format'   => self::FORMAT,
                'aplikasi' => self::APLIKASI,
                'dibuat'   => date('c'),
                'label'    => $label,
                'laravel'  => self::versiLaravel(),
                'driver'   => DB::connection()->getDriverName(),
                'isi'      => ['database' => $db, 'berkas' => $berkas],
                'tabel'    => $hitung,
                'berkas'   => count($daftar),
                'ukuran_berkas' => $ukBerkas,
                'sha256_database' => $sidik,
            ];
            $part = "$dir/$nama.zip.part";
            $z = new \ZipArchive();
            if ($z->open($part, \ZipArchive::CREATE | \ZipArchive::OVERWRITE) !== true) {
                throw new \RuntimeException('Tidak dapat membuat berkas ZIP di ' . $dir . '. Periksa izin folder storage.');
            }
            $z->addFromString('manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
            if ($db) {
                $z->addFile($tmpDb, 'database.jsonl');
            }
            foreach ($daftar as $rel => $abs) {
                $z->addFile($abs, 'berkas/' . $rel);
            }
            if (! $z->close()) {
                throw new \RuntimeException('Gagal menyelesaikan berkas ZIP (ruang disk mungkin penuh).');
            }
            if (! @rename($part, "$dir/$nama.zip")) {
                throw new \RuntimeException('Gagal menyimpan berkas cadangan.');
            }
            @chmod("$dir/$nama.zip", 0640);
            $part = null;
            self::catat('Cadangan dibuat: ' . $nama);

            return ['nama' => $nama . '.zip', 'path' => "$dir/$nama.zip", 'ukuran' => (int) filesize("$dir/$nama.zip"),
                'tabel' => count($hitung), 'baris' => array_sum($hitung), 'berkas' => count($daftar)];
        } finally {
            @unlink($tmpDb);
            if ($part) {
                @unlink($part);
            }
            self::lepas($kunci);
        }
    }

    private static function versiLaravel(): string
    {
        try {
            return (string) app()->version();
        } catch (\Throwable $e) {
            return '';
        }
    }

    private static function catat(string $t): void
    {
        try {
            \Illuminate\Support\Facades\Log::info('[cadangan] ' . $t);
        } catch (\Throwable $e) {
            // abaikan
        }
    }

    // ------------------------------------------------------------------ daftar & berkas cadangan

    /** Nama berkas yang sah: sia-...zip. Mengembalikan jalan mutlak atau null. */
    public static function jalan(string $nama): ?string
    {
        if (! preg_match('/^sia-[a-z0-9-]{1,90}\.zip$/', $nama)) {
            return null;
        }
        $p = self::dir() . '/' . $nama;

        return is_file($p) ? $p : null;
    }

    /** Baca dan periksa manifest sebuah ZIP; melempar RuntimeException bila bukan cadangan SIA yang sah. */
    public static function periksa(string $path): array
    {
        if (! class_exists(\ZipArchive::class)) {
            throw new \RuntimeException(self::masalah());
        }
        $z = new \ZipArchive();
        if (! is_file($path) || $z->open($path) !== true) {
            throw new \RuntimeException('Berkas bukan arsip ZIP yang valid.');
        }
        try {
            $st = $z->statName('manifest.json');
            if (! $st || $st['size'] > 2_000_000) {
                throw new \RuntimeException('Bukan berkas cadangan SIA (manifest.json tidak ada).');
            }
            $m = json_decode((string) $z->getFromName('manifest.json'), true);
            if (! is_array($m) || ($m['aplikasi'] ?? '') !== self::APLIKASI) {
                throw new \RuntimeException('Bukan berkas cadangan SIA Akreditasi.');
            }
            if ((int) ($m['format'] ?? 0) !== self::FORMAT) {
                throw new \RuntimeException('Versi format cadangan tidak dikenali (' . (int) ($m['format'] ?? 0) . '). Perbarui aplikasi lebih dulu.');
            }
            if (! empty($m['isi']['database']) && ! $z->statName('database.jsonl')) {
                throw new \RuntimeException('Cadangan rusak: database.jsonl tidak ada di dalam arsip.');
            }

            return $m;
        } finally {
            $z->close();
        }
    }

    public static function daftar(): array
    {
        $out = [];
        foreach (glob(self::dir() . '/sia-*.zip') ?: [] as $p) {
            $row = ['nama' => basename($p), 'ukuran' => (int) @filesize($p), 'waktu' => (int) @filemtime($p), 'sah' => false,
                'label' => '', 'database' => false, 'berkas' => false, 'tabel' => 0, 'baris' => 0, 'jumlah_berkas' => 0, 'dibuat' => null, 'pesan' => null];
            try {
                $m = self::periksa($p);
                $row['sah'] = true;
                $row['label'] = (string) ($m['label'] ?? '');
                $row['database'] = ! empty($m['isi']['database']);
                $row['berkas'] = ! empty($m['isi']['berkas']);
                $row['tabel'] = count((array) ($m['tabel'] ?? []));
                $row['baris'] = (int) array_sum((array) ($m['tabel'] ?? []));
                $row['jumlah_berkas'] = (int) ($m['berkas'] ?? 0);
                $row['dibuat'] = $m['dibuat'] ?? null;
            } catch (\Throwable $e) {
                $row['pesan'] = $e->getMessage();
            }
            $out[] = $row;
        }
        usort($out, fn ($a, $b) => $b['waktu'] <=> $a['waktu']);

        return $out;
    }

    public static function hapus(string $nama): bool
    {
        $p = self::jalan($nama);

        return $p ? @unlink($p) : false;
    }

    /** Hapus cadangan berlabel $label yang lebih lama dari $simpan terbaru. Mengembalikan jumlah yang dihapus. */
    public static function pangkas(string $label, int $simpan): int
    {
        if ($simpan < 1) {
            return 0;
        }
        $n = 0;
        $i = 0;
        foreach (self::daftar() as $d) {
            if ($d['label'] !== $label) {
                continue;
            }
            if (++$i > $simpan && self::hapus($d['nama'])) {
                $n++;
            }
        }

        return $n;
    }

    /** Terima ZIP unggahan: periksa lalu simpan di folder cadangan. Mengembalikan nama berkas. */
    public static function terima(string $tmpPath, int $maks = 0): string
    {
        self::periksa($tmpPath);
        if (! is_dir(self::dir())) {
            @mkdir(self::dir(), 0775, true);
        }
        self::lindungi();
        $nama = 'sia-unggahan-' . date('Ymd-His') . '-' . bin2hex(random_bytes(2)) . '.zip';
        $tujuan = self::dir() . '/' . $nama;
        if (! @copy($tmpPath, $tujuan)) {
            throw new \RuntimeException('Gagal menyimpan berkas unggahan di folder cadangan.');
        }
        @chmod($tujuan, 0640);
        self::catat('Cadangan diunggah: ' . $nama);

        return $nama;
    }

    // ------------------------------------------------------------------ pemulihan

    /** Nama relatif aman di dalam berkas/ ? Mengembalikan jalan relatif bersih atau null bila harus dilewati. */
    public static function relAman(string $nama): ?string
    {
        if (! str_starts_with($nama, 'berkas/') || str_ends_with($nama, '/') || str_contains($nama, "\0") || str_contains($nama, '\\')) {
            return null;
        }
        $rel = substr($nama, 7);
        $seg = explode('/', $rel);
        foreach ($seg as $s) {
            if ($s === '' || $s === '.' || $s === '..' || str_starts_with($s, '.')) {
                return null;
            }
        }
        if (in_array($seg[0], self::ABAIKAN_DIR, true)) {
            return null;
        }
        $bagian = explode('.', strtolower((string) end($seg)));
        array_shift($bagian);   // nama dasar bukan ekstensi
        foreach ($bagian as $b) {
            if (in_array($b, self::TERLARANG, true)) {
                return null;
            }
        }
        if (strtolower((string) end($seg)) === 'web.config') {
            return null;
        }

        return implode('/', $seg);
    }

    /**
     * Memulihkan dari ZIP. Selalu membuat cadangan pengaman dulu.
     * @return array{database:?array,berkas:?array,pengaman:?string}
     */
    public static function pulihkan(string $path, bool $db = true, bool $berkas = true): array
    {
        if ($m = self::masalah()) {
            throw new \RuntimeException($m);
        }
        $man = self::periksa($path);
        $db = $db && ! empty($man['isi']['database']);
        $berkas = $berkas && ! empty($man['isi']['berkas']);
        if (! $db && ! $berkas) {
            throw new \RuntimeException('Cadangan ini tidak berisi bagian yang Anda pilih untuk dipulihkan.');
        }
        self::bebas();
        // cadangan pengaman (memegang kunci sendiri), lalu kunci untuk pemulihan
        $pengaman = self::buat('sebelum-pulih', true, true);
        $kunci = self::kunci();
        $tmp = null;
        try {
            $hasil = ['database' => null, 'berkas' => null, 'pengaman' => $pengaman['nama']];
            $z = new \ZipArchive();
            if ($z->open($path) !== true) {
                throw new \RuntimeException('Berkas ZIP tidak dapat dibuka.');
            }
            try {
                if ($db) {
                    $tmp = self::dir() . '/.pulih-' . bin2hex(random_bytes(4)) . '.jsonl';
                    self::ekstrakDb($z, $tmp, (string) ($man['sha256_database'] ?? ''));
                    $hasil['database'] = self::muatDb($tmp);
                }
                if ($berkas) {
                    $hasil['berkas'] = self::muatBerkas($z);
                }
            } finally {
                $z->close();
            }
            try {
                \Illuminate\Support\Facades\Artisan::call('optimize:clear');
            } catch (\Throwable $e) {
                // abaikan
            }
            self::catat('Pemulihan selesai dari ' . basename($path) . '; pengaman: ' . $pengaman['nama']);

            return $hasil;
        } finally {
            if ($tmp) {
                @unlink($tmp);
            }
            self::lepas($kunci);
        }
    }

    private static function ekstrakDb(\ZipArchive $z, string $tujuan, string $sidik): void
    {
        $in = $z->getStream('database.jsonl');
        $out = fopen($tujuan, 'wb');
        if (! $in || ! $out) {
            throw new \RuntimeException('Tidak dapat membaca database.jsonl dari cadangan.');
        }
        $h = hash_init('sha256');
        while (! feof($in)) {
            $b = fread($in, 1 << 20);
            if ($b === false) {
                break;
            }
            hash_update($h, $b);
            fwrite($out, $b);
        }
        fclose($in);
        fclose($out);
        if ($sidik !== '' && ! hash_equals($sidik, hash_final($h))) {
            throw new \RuntimeException('Cadangan rusak atau diubah: sidik SHA-256 database tidak cocok. Pemulihan dibatalkan; data tidak berubah.');
        }
    }

    /** Muat database.jsonl ke tabel (dalam satu transaksi). */
    private static function muatDb(string $file): array
    {
        $drv = DB::connection()->getDriverName();
        $fh = fopen($file, 'rb');
        $lap = ['tabel' => 0, 'baris' => 0, 'dilewati' => []];
        if (in_array($drv, ['mysql', 'mariadb'], true)) {
            DB::statement('SET FOREIGN_KEY_CHECKS=0');
        } elseif ($drv === 'sqlite') {
            DB::statement('PRAGMA foreign_keys=OFF');
        }
        try {
            DB::beginTransaction();
            $tabel = null;
            $kolomDump = [];
            $mapIdx = [];
            $lewati = false;
            $ukuranBatch = 1;
            while (($baris = fgets($fh)) !== false) {
                $baris = trim($baris);
                if ($baris === '') {
                    continue;
                }
                $j = json_decode($baris, true);
                if (! is_array($j)) {
                    throw new \RuntimeException('Isi database.jsonl tidak dapat dibaca (baris rusak).');
                }
                if (isset($j['tabel'])) {
                    $tabel = (string) $j['tabel'];
                    $lewati = in_array($tabel, self::ABAIKAN_TABEL, true) || ! Schema::hasTable($tabel);
                    if ($lewati) {
                        $lap['dilewati'][] = $tabel;
                        continue;
                    }
                    $kolomDump = (array) $j['kolom'];
                    $ada = Schema::getColumnListing($tabel);
                    $mapIdx = [];
                    foreach ($kolomDump as $i => $c) {
                        if (in_array($c, $ada, true)) {
                            $mapIdx[$i] = $c;
                        }
                    }
                    DB::table($tabel)->delete();
                    $lap['tabel']++;
                    $ukuranBatch = max(1, intdiv(800, max(1, count($mapIdx))));
                    continue;
                }
                if (isset($j['t'])) {
                    if ($lewati || $tabel !== $j['t'] || ! $mapIdx) {
                        continue;
                    }
                    $paket = [];
                    foreach ((array) $j['r'] as $r) {
                        $a = [];
                        foreach ($mapIdx as $i => $c) {
                            $a[$c] = self::dek($r[$i] ?? null);
                        }
                        $paket[] = $a;
                        if (count($paket) >= $ukuranBatch) {
                            DB::table($tabel)->insert($paket);
                            $lap['baris'] += count($paket);
                            $paket = [];
                        }
                    }
                    if ($paket) {
                        DB::table($tabel)->insert($paket);
                        $lap['baris'] += count($paket);
                    }
                }
            }
            DB::commit();
        } catch (\Throwable $e) {
            try {
                DB::rollBack();
            } catch (\Throwable $x) {
                // abaikan
            }
            throw new \RuntimeException('Pemulihan database gagal dan dibatalkan (data tidak berubah): ' . mb_substr($e->getMessage(), 0, 300));
        } finally {
            fclose($fh);
            if (in_array($drv, ['mysql', 'mariadb'], true)) {
                DB::statement('SET FOREIGN_KEY_CHECKS=1');
            } elseif ($drv === 'sqlite') {
                DB::statement('PRAGMA foreign_keys=ON');
            }
        }

        return $lap;
    }

    /** Ekstrak berkas/ ke storage/app dengan pemeriksaan jalur dan ekstensi. */
    private static function muatBerkas(\ZipArchive $z): array
    {
        $akar = self::akar();
        @mkdir($akar, 0775, true);
        $akarNyata = realpath($akar);
        $lap = ['dipulihkan' => 0, 'dilewati' => 0];
        for ($i = 0; $i < $z->numFiles; $i++) {
            $st = $z->statIndex($i);
            $nama = (string) ($st['name'] ?? '');
            if (! str_starts_with($nama, 'berkas/') || str_ends_with($nama, '/')) {
                continue;
            }
            $rel = self::relAman($nama);
            $z->getExternalAttributesIndex($i, $os, $attr);
            $symlink = $os === \ZipArchive::OPSYS_UNIX && ((($attr >> 16) & 0170000) === 0120000);
            if ($rel === null || $symlink) {
                $lap['dilewati']++;
                continue;
            }
            $tujuan = $akar . '/' . $rel;
            $dirTujuan = dirname($tujuan);
            if (! is_dir($dirTujuan) && ! @mkdir($dirTujuan, 0775, true) && ! is_dir($dirTujuan)) {
                $lap['dilewati']++;
                continue;
            }
            $nyata = realpath($dirTujuan);
            if ($akarNyata === false || $nyata === false || ! str_starts_with($nyata . '/', $akarNyata . '/')) {
                $lap['dilewati']++;
                continue;
            }
            $in = $z->getStream($nama);
            $tmp = $tujuan . '.part';
            $out = $in ? @fopen($tmp, 'wb') : false;
            if (! $in || ! $out) {
                $lap['dilewati']++;
                if ($in) {
                    fclose($in);
                }
                continue;
            }
            stream_copy_to_stream($in, $out);
            fclose($in);
            fclose($out);
            if (@rename($tmp, $tujuan)) {
                @chmod($tujuan, 0664);
                $lap['dipulihkan']++;
            } else {
                @unlink($tmp);
                $lap['dilewati']++;
            }
        }

        return $lap;
    }
}
EOFCB1

tulis app/Http/Controllers/CadanganController.php <<'EOFCB2'
<?php
// CADANGAN-PEMULIHAN

namespace App\Http\Controllers;

use App\Support\CadanganSia;
use Illuminate\Http\Request;

/** Hanya admin (middleware HanyaAdmin pada route). */
class CadanganController extends Controller
{
    public function index()
    {
        $masalah = CadanganSia::masalah();
        $ring = null;
        try {
            $ring = $masalah ? null : CadanganSia::ringkasan();
        } catch (\Throwable $e) {
            report($e);
            $masalah = 'Ringkasan data tidak dapat dibaca: ' . mb_substr($e->getMessage(), 0, 200);
        }

        return view('cadangan.index', [
            'masalah' => $masalah,
            'ring'    => $ring,
            'daftar'  => $masalah ? [] : CadanganSia::daftar(),
            'maksUnggah' => min($this->bytes(ini_get('upload_max_filesize')), $this->bytes(ini_get('post_max_size'))),
        ]);
    }

    private function bytes($v): int
    {
        $v = trim((string) $v);
        $n = (int) $v;
        switch (strtolower(substr($v, -1))) {
            case 'g': $n *= 1024;
            // no break
            case 'm': $n *= 1024;
            // no break
            case 'k': $n *= 1024;
        }

        return $n;
    }

    public function buat(Request $r)
    {
        $db = $r->boolean('database');
        $bk = $r->boolean('berkas');
        if (! $db && ! $bk) {
            return back()->withErrors(['cadangan' => 'Pilih minimal satu isi backup: Database atau Dokumen.']);
        }
        try {
            $h = CadanganSia::buat('manual', $db, $bk);
        } catch (\RuntimeException $e) {
            return back()->withErrors(['cadangan' => $e->getMessage()]);
        } catch (\Throwable $e) {
            report($e);

            return back()->withErrors(['cadangan' => 'Backup gagal dibuat: ' . mb_substr($e->getMessage(), 0, 200) . ' (detail di storage/logs/laravel.log)']);
        }

        return redirect()->route('cadangan.index')->with('ok', 'Backup dibuat: ' . $h['nama'] . ' (' . CadanganSia::ukuran($h['ukuran']) . ', ' . $h['tabel'] . ' tabel, ' . $h['baris'] . ' baris, ' . $h['berkas'] . ' berkas). Klik Unduh untuk menyimpannya di komputer Anda.');
    }

    public function unduh(string $nama)
    {
        $p = CadanganSia::jalan($nama);
        abort_if(! $p, 404);

        return response()->download($p, $nama, ['Content-Type' => 'application/zip', 'Cache-Control' => 'no-store']);
    }

    public function hapus(Request $r)
    {
        $nama = (string) $r->input('nama');
        if (! CadanganSia::hapus($nama)) {
            return back()->withErrors(['cadangan' => 'Berkas backup tidak ditemukan.']);
        }

        return redirect()->route('cadangan.index')->with('ok', 'Backup dihapus: ' . $nama);
    }

    public function unggah(Request $r)
    {
        $r->validate(['berkas_zip' => 'required|file'], ['berkas_zip.required' => 'Pilih berkas backup (.zip) lebih dulu.', 'berkas_zip.file' => 'Unggahan gagal; ukuran berkas mungkin melebihi batas server (lihat upload_max_filesize).']);
        $f = $r->file('berkas_zip');
        if (strtolower((string) $f->getClientOriginalExtension()) !== 'zip') {
            return back()->withErrors(['cadangan' => 'Berkas harus berekstensi .zip.']);
        }
        try {
            $nama = CadanganSia::terima($f->getRealPath());
        } catch (\RuntimeException $e) {
            return back()->withErrors(['cadangan' => $e->getMessage()]);
        }

        return redirect()->route('cadangan.index')->with('ok', 'Backup diunggah sebagai ' . $nama . '. Klik Restore pada barisnya bila ingin memakainya.');
    }

    public function pulihkan(Request $r)
    {
        if (strtoupper(trim((string) $r->input('konfirmasi'))) !== 'RESTORE') {
            return back()->withErrors(['cadangan' => 'Konfirmasi salah. Ketik RESTORE untuk melanjutkan.']);
        }
        $p = CadanganSia::jalan((string) $r->input('nama'));
        if (! $p) {
            return back()->withErrors(['cadangan' => 'Berkas backup tidak ditemukan.']);
        }
        if (! $r->boolean('database') && ! $r->boolean('berkas')) {
            return back()->withErrors(['cadangan' => 'Pilih minimal satu bagian untuk di-restore.']);
        }
        try {
            $h = CadanganSia::pulihkan($p, $r->boolean('database'), $r->boolean('berkas'));
        } catch (\RuntimeException $e) {
            return back()->withErrors(['cadangan' => $e->getMessage()]);
        } catch (\Throwable $e) {
            report($e);

            return back()->withErrors(['cadangan' => 'Restore gagal: ' . mb_substr($e->getMessage(), 0, 200) . ' (detail di storage/logs/laravel.log)']);
        }
        $ps = [];
        if ($h['database']) {
            $ps[] = $h['database']['tabel'] . ' tabel dan ' . $h['database']['baris'] . ' baris database di-restore';
        }
        if ($h['berkas']) {
            $ps[] = $h['berkas']['di-restore'] . ' berkas di-restore' . ($h['berkas']['dilewati'] ? ' (' . $h['berkas']['dilewati'] . ' dilewati karena tidak aman/tidak valid)' : '');
        }
        $msg = 'Restore selesai: ' . implode('; ', $ps) . '. Backup pengaman sebelum restore: ' . $h['pengaman'] . '.';
        if ($h['database']) {
            $msg .= ' Akun pengguna ikut kembali ke kondisi backup; bila diminta, masuk ulang.';
        }

        return redirect()->route('cadangan.index')->with('ok', $msg);
    }
}
EOFCB2

tulis app/Console/Commands/CadanganBuatCommand.php <<'EOFCB3'
<?php
// CADANGAN-PEMULIHAN

namespace App\Console\Commands;

use App\Support\CadanganSia;
use Illuminate\Console\Command;

class CadanganBuatCommand extends Command
{
    protected $signature = 'sia:cadangan {--label=otomatis : label pada nama berkas} {--tanpa-db : jangan sertakan database} {--tanpa-berkas : jangan sertakan dokumen} {--simpan=0 : simpan hanya N cadangan terbaru berlabel sama (0 = tidak menghapus)}';
    protected $description = 'Buat cadangan database + dokumen (storage/app/cadangan-sistem/sia-*.zip)';

    public function handle(): int
    {
        try {
            $h = CadanganSia::buat((string) $this->option('label'), ! $this->option('tanpa-db'), ! $this->option('tanpa-berkas'));
        } catch (\RuntimeException $e) {
            $this->error($e->getMessage());

            return self::FAILURE;
        }
        $this->info('Cadangan dibuat: ' . $h['path'] . ' (' . CadanganSia::ukuran($h['ukuran']) . ', ' . $h['tabel'] . ' tabel, ' . $h['baris'] . ' baris, ' . $h['berkas'] . ' berkas)');
        $n = CadanganSia::pangkas(trim((string) preg_replace('/[^a-z0-9]+/', '-', strtolower((string) $this->option('label'))), '-') ?: 'manual', (int) $this->option('simpan'));
        if ($n > 0) {
            $this->line("$n cadangan lama dihapus.");
        }

        return self::SUCCESS;
    }
}
EOFCB3

tulis app/Console/Commands/CadanganPulihCommand.php <<'EOFCB4'
<?php
// CADANGAN-PEMULIHAN

namespace App\Console\Commands;

use App\Support\CadanganSia;
use Illuminate\Console\Command;

class CadanganPulihCommand extends Command
{
    protected $signature = 'sia:pulihkan {berkas : nama berkas di storage/app/cadangan-sistem, atau jalan lengkap ke .zip} {--tanpa-db : jangan pulihkan database} {--tanpa-berkas : jangan pulihkan dokumen} {--yes : tanpa konfirmasi}';
    protected $description = 'Pulihkan database + dokumen dari berkas cadangan SIA (cadangan pengaman dibuat otomatis lebih dulu)';

    public function handle(): int
    {
        $b = (string) $this->argument('berkas');
        $p = CadanganSia::jalan($b) ?: (is_file($b) ? $b : null);
        if (! $p) {
            $this->error('Berkas tidak ditemukan: ' . $b);

            return self::FAILURE;
        }
        try {
            $m = CadanganSia::periksa($p);
        } catch (\RuntimeException $e) {
            $this->error($e->getMessage());

            return self::FAILURE;
        }
        $this->line('Cadangan: ' . basename($p) . ' dibuat ' . ($m['dibuat'] ?? '?') . '; database: ' . (! empty($m['isi']['database']) ? 'ya' : 'tidak') . ', dokumen: ' . (! empty($m['isi']['berkas']) ? 'ya' : 'tidak'));
        if (! $this->option('yes') && ! $this->confirm('Isi database dan dokumen saat ini akan DIGANTI oleh cadangan ini. Lanjutkan?', false)) {
            $this->line('Dibatalkan.');

            return self::SUCCESS;
        }
        try {
            $h = CadanganSia::pulihkan($p, ! $this->option('tanpa-db'), ! $this->option('tanpa-berkas'));
        } catch (\RuntimeException $e) {
            $this->error($e->getMessage());

            return self::FAILURE;
        }
        if ($h['database']) {
            $this->info('Database: ' . $h['database']['tabel'] . ' tabel, ' . $h['database']['baris'] . ' baris.');
        }
        if ($h['berkas']) {
            $this->info('Dokumen: ' . $h['berkas']['dipulihkan'] . ' dipulihkan, ' . $h['berkas']['dilewati'] . ' dilewati.');
        }
        $this->line('Cadangan pengaman: ' . $h['pengaman']);

        return self::SUCCESS;
    }
}
EOFCB4

tulis resources/views/cadangan/index.blade.php <<'EOFCB5'
{{-- CADANGAN-PEMULIHAN --}}
@extends('layout')
@section('title', 'Backup & Restore')
@section('content')
<div class="mb-3">
  <h1 class="mb-0">Backup &amp; Restore</h1>
  <div class="text-muted small">Backup database dan dokumen ke satu berkas ZIP, unduh ke komputer, atau restore dari berkas backup (mis. saat pindah server)</div>
</div>

@if($masalah)
  <div class="alert alert-danger">{{ $masalah }}</div>
@else
<div class="row g-3 mb-4">
  <div class="col-12 col-lg-7">
    <div class="card card-body h-100">
      <h5>Backup</h5>
      <form method="post" action="{{ route('cadangan.buat') }}" onsubmit="this.querySelector('button').disabled=true;this.querySelector('button').textContent='Membuat backup...';">
        @csrf
        <div class="form-check"><input class="form-check-input" type="checkbox" name="database" value="1" id="cbdb" checked><label class="form-check-label" for="cbdb">Database <span class="text-muted small">({{ $ring['tabel'] }} tabel, {{ number_format($ring['baris'], 0, ',', '.') }} baris: kriteria, narasi, data induk, LKPS, pengguna)</span></label></div>
        <div class="form-check mb-3"><input class="form-check-input" type="checkbox" name="berkas" value="1" id="cbbk" checked><label class="form-check-label" for="cbbk">Dokumen &amp; berkas unggahan <span class="text-muted small">({{ number_format($ring['berkas'], 0, ',', '.') }} berkas, {{ \App\Support\CadanganSia::ukuran($ring['ukuran']) }}: dokumen Kriteria, Data Induk, lampiran LKPS, gambar narasi)</span></label></div>
        <button class="btn btn-primary">Backup sekarang</button>
        <span class="text-muted small ms-2">Ruang disk tersedia: {{ \App\Support\CadanganSia::ukuran($ring['bebas']) }}</span>
      </form>
      <div class="small text-muted mt-3">File <code>.env</code> (kata sandi database dan <code>APP_KEY</code>) <b>tidak</b> ikut di-backup; simpan terpisah. Backup berisi data pengguna dan hash kata sandi: simpan di tempat aman.</div>
    </div>
  </div>
  <div class="col-12 col-lg-5">
    <div class="card card-body h-100">
      <h5>Unggah berkas backup</h5>
      <form method="post" action="{{ route('cadangan.unggah') }}" enctype="multipart/form-data">
        @csrf
        <input type="file" name="berkas_zip" accept=".zip,application/zip" class="form-control mb-2" required>
        <button class="btn btn-outline-primary">Unggah</button>
      </form>
      <div class="small text-muted mt-2">Untuk restore di server baru. Batas unggah server saat ini: <b>{{ \App\Support\CadanganSia::ukuran((int) $maksUnggah) }}</b>. Bila backup lebih besar, salin berkasnya lewat FTP/SCP ke <code>storage/app/cadangan-sistem/</code>; ia akan muncul di daftar di bawah.</div>
    </div>
  </div>
</div>

<div class="card mb-4">
  <div class="card-body pb-2"><h5 class="mb-0">Daftar backup</h5><div class="text-muted small">Backup disimpan di server pada <code>storage/app/cadangan-sistem/</code> (tidak dapat dibuka lewat web). Unduh salinannya ke komputer Anda secara berkala.</div></div>
  <div class="table-responsive"><table class="table align-middle mb-0">
    <thead><tr><th>Berkas</th><th>Dibuat</th><th>Isi</th><th>Ukuran</th><th class="text-end">Aksi</th></tr></thead>
    <tbody>
    @forelse($daftar as $d)
      <tr>
        <td><code>{{ $d['nama'] }}</code>@if($d['label'] === 'sebelum-pulih') <span class="badge text-bg-secondary">pengaman</span>@endif</td>
        <td class="small">{{ \Illuminate\Support\Carbon::createFromTimestamp($d['waktu'])->format('d/m/Y H:i') }}</td>
        <td class="small">
          @if($d['sah'])
            {{ $d['database'] ? 'Database ('.$d['tabel'].' tabel, '.number_format($d['baris'], 0, ',', '.').' baris)' : '' }}{{ $d['database'] && $d['berkas'] ? ' + ' : '' }}{{ $d['berkas'] ? number_format($d['jumlah_berkas'], 0, ',', '.').' berkas' : '' }}
          @else
            <span class="text-danger">Tidak valid: {{ $d['pesan'] }}</span>
          @endif
        </td>
        <td class="small">{{ \App\Support\CadanganSia::ukuran($d['ukuran']) }}</td>
        <td class="text-end text-nowrap">
          <a class="btn btn-sm btn-outline-secondary" href="{{ route('cadangan.unduh', $d['nama']) }}">Unduh</a>
          @if($d['sah'])<a class="btn btn-sm btn-outline-danger" href="#p{{ $loop->index }}" onclick="var e=document.getElementById('p{{ $loop->index }}');e.open=true;">Restore</a>@endif
          <form method="post" action="{{ route('cadangan.hapus') }}" class="d-inline" onsubmit="return confirm('Hapus berkas backup ini dari server?')">@csrf<input type="hidden" name="nama" value="{{ $d['nama'] }}"><button class="btn btn-sm btn-outline-secondary">Hapus</button></form>
        </td>
      </tr>
      @if($d['sah'])
      <tr><td colspan="5" class="p-0 border-0">
        <details id="p{{ $loop->index }}" class="px-3 py-2 bg-light border-bottom">
          <summary class="small text-muted" style="cursor:pointer">Opsi restore untuk {{ $d['nama'] }}</summary>
          <form method="post" action="{{ route('cadangan.pulihkan') }}" class="mt-2" onsubmit="return confirm('Isi database dan dokumen saat ini akan diganti oleh backup ini. Backup pengaman dibuat otomatis lebih dulu. Lanjutkan?')">
            @csrf
            <input type="hidden" name="nama" value="{{ $d['nama'] }}">
            <div class="alert alert-warning py-2 small mb-2"><b>Perhatian:</b> isi tabel database saat ini <b>diganti</b> oleh isi backup (termasuk akun pengguna), dan berkas dengan nama sama <b>ditimpa</b>. Berkas lain di server dibiarkan. Backup pengaman otomatis dibuat sebelum restore dimulai.</div>
            <div class="d-flex flex-wrap gap-3 align-items-center">
              @if($d['database'])<label class="small"><input type="checkbox" name="database" value="1" checked> Database</label>@endif
              @if($d['berkas'])<label class="small"><input type="checkbox" name="berkas" value="1" checked> Dokumen</label>@endif
              <input type="text" name="konfirmasi" class="form-control form-control-sm" style="max-width:220px" placeholder="Ketik RESTORE" autocomplete="off" required>
              <button class="btn btn-sm btn-danger">Restore sekarang</button>
            </div>
          </form>
        </details>
      </td></tr>
      @endif
    @empty
      <tr><td colspan="5" class="text-center text-muted py-4">Belum ada backup. Klik <b>Backup sekarang</b>.</td></tr>
    @endforelse
    </tbody>
  </table></div>
</div>

<div class="card card-body small text-muted">
  <b class="text-body">Backup otomatis dan perintah terminal</b>
  <div class="mt-1">Backup: <code>php artisan sia:cadangan --simpan=7</code> &nbsp; Restore: <code>php artisan sia:pulihkan NAMA-BERKAS.zip</code></div>
  <div>Jadwal harian (crontab): <code>30 1 * * * cd /path/proyek &amp;&amp; php artisan sia:cadangan --simpan=7</code>. Untuk berkas besar, perintah terminal lebih andal daripada tombol di halaman ini (tidak terkena batas waktu web).</div>
</div>
@endif
@endsection
EOFCB5


echo "[2/5] Route (hanya admin)..."
if grep -q "CadanganController" "$R"; then
  if grep -q "prefix('cadangan')" "$R"; then
    cp "$R" "$R.bak19"; sed -i "s#->prefix('cadangan')#->prefix('backup-restore')#" "$R"
    if php -l "$R" >/dev/null 2>&1; then echo "  OK  alamat halaman diubah menjadi /backup-restore"; else cp "$R.bak19" "$R"; echo "  PERINGATAN: alamat lama dipertahankan (/cadangan)."; fi
  else
    echo "  (route sudah ada, dilewati)"
  fi
else
  cp "$R" "$R.bak19"
  cat >> "$R" <<'EOFROUTE'

// ===== Backup & Restore (khusus admin) =====
Route::middleware(['auth', \App\Http\Middleware\HanyaAdmin::class])->prefix('backup-restore')->name('cadangan.')->group(function () {
    Route::get('/', [\App\Http\Controllers\CadanganController::class, 'index'])->name('index');
    Route::post('/buat', [\App\Http\Controllers\CadanganController::class, 'buat'])->middleware('throttle:6,1')->name('buat');
    Route::post('/unggah', [\App\Http\Controllers\CadanganController::class, 'unggah'])->middleware('throttle:6,1')->name('unggah');
    Route::get('/unduh/{nama}', [\App\Http\Controllers\CadanganController::class, 'unduh'])->where('nama', 'sia-[a-z0-9-]+\.zip')->name('unduh');
    Route::post('/hapus', [\App\Http\Controllers\CadanganController::class, 'hapus'])->name('hapus');
    Route::post('/pulihkan', [\App\Http\Controllers\CadanganController::class, 'pulihkan'])->middleware('throttle:3,1')->name('pulihkan');
});
EOFROUTE
  if php -l "$R" >/dev/null 2>&1; then echo "  OK  $R"; else cp "$R.bak19" "$R"; echo "GAGAL: routes/web.php tidak valid, dipulihkan dari $R.bak19"; exit 1; fi
fi

echo "[3/5] Menu sidebar (Backup & Restore, tepat di atas Bulk Document)..."
M=$(cat <<'EOF2'
      @if(Route::has('cadangan.index') && auth()->check() && \App\Http\Middleware\HanyaAdmin::adalahAdmin(auth()->user()))
      <a class="mi {{ request()->routeIs('cadangan.*') ? 'on' : '' }}" href="{{ route('cadangan.index') }}">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="10" cy="5" rx="7" ry="2.8"/><path d="M3 5v5c0 1.5 3.1 2.8 7 2.8"/><path d="M3 10v5c0 1.5 3.1 2.8 7 2.8"/><path d="M21 12a6 6 0 1 0-1.8 4.3"/><path d="M21 7.5V12h-4.5"/></svg>Backup &amp; Restore
      </a>
      @endif
EOF2
)
export M
PM=$(mktemp); LN=$(mktemp)
cat > "$PM" <<'EOFPERL'
undef $/;
my $t = <STDIN>;
my $m = $ENV{M};
# bersihkan pemasangan lama (tautan kecil di bawah Administrasi / blok sebelumnya), lalu pasang di posisi baru
$t =~ s/^[ \t]*\@if\(Route::has\('cadangan\.index'\).*?\@endif\n//ms;
unless ($t =~ s/(^[ \t]*\@if\(Route::has\('bulk\.index'\)\)\n)/$m\n$1/m) {
  $t =~ s/(^[ \t]*<\/div>\n[ \t]*<div class="sfoot">)/$m\n$1/m;
}
print $t;
EOFPERL
perl "$PM" < "$L" > "$LN"
if cmp -s "$LN" "$L"; then
  if grep -q "route('cadangan.index')" "$L"; then echo "  (menu Backup & Restore sudah di posisinya, dilewati)"; else echo "  PERINGATAN: menu tidak terpasang (pola layout berbeda). Halaman tetap dapat dibuka di /backup-restore."; fi
elif grep -q "route('cadangan.index')" "$LN"; then
  cp "$L" "$L.bak19"; cp "$LN" "$L"; chmod 644 "$L" 2>/dev/null || true
  echo "  OK  menu Backup & Restore (di atas Bulk Document)"
else
  echo "  PERINGATAN: menu tidak terpasang (pola layout berbeda). Halaman tetap dapat dibuka di /backup-restore."
fi
rm -f "$PM" "$LN"

echo "[4/5] Folder penyimpanan cadangan..."
mkdir -p storage/app/cadangan-sistem
printf 'Require all denied\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n' > storage/app/cadangan-sistem/.htaccess
: > storage/app/cadangan-sistem/index.html
chmod 775 storage/app/cadangan-sistem 2>/dev/null || true
php -m 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx zip || echo "  PERINGATAN: ekstensi PHP 'zip' belum aktif; aktifkan (Ubuntu: sudo apt install php-zip; cPanel: Select PHP Version > zip)."
echo "  OK  storage/app/cadangan-sistem (tidak dapat dibuka lewat web)"

echo "[5/5] Memeriksa dan membersihkan cache..."
GAGAL=0
for f in app/Support/CadanganSia.php app/Http/Controllers/CadanganController.php app/Console/Commands/CadanganBuatCommand.php app/Console/Commands/CadanganPulihCommand.php; do
  php -l "$f" >/dev/null 2>&1 || { echo "  GAGAL lint: $f"; GAGAL=1; }
done
php artisan optimize:clear >/dev/null 2>&1 || true
[ "$GAGAL" = "0" ] || exit 1
echo
echo "Selesai. Login sebagai admin, buka menu Backup & Restore di sidebar (tepat di atas Bulk Document; alamat: /backup-restore)."
echo "Terminal: php artisan sia:cadangan --simpan=7     |     php artisan sia:pulihkan NAMA-BERKAS.zip   (backup/restore dari terminal)"
echo "Cadangan otomatis (crontab):  30 1 * * * cd $(pwd) && php artisan sia:cadangan --simpan=7"
