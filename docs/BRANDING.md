# Update branding DEWA pada instalasi yang sudah berjalan

Nama runtime, halaman login/sidebar, favicon, splash light/dark, serta ikon aplikasi menggunakan DEWA. Logo diambil dari `frontend/public/logo.svg` pada proyek DEWA lama dan disimpan utuh pada `branding/source/logo.svg`. Tidak ada logo baru yang dibuat. Ikon memakai bidang gelap agar glyph putih tetap terlihat pada light/dark theme, sedangkan splash memiliki varian sesuai tema. Animasi logo lama tidak digunakan agar loading tidak menambah gerakan.

Image turunan tetap memakai Open WebUI **v0.13.3**, seperti instalasi yang sudah berhasil. Semua chat, akun, grup, Knowledge, indeks, upload, serta cache tetap pada PVC `open-webui-data`. Koneksi Alibaba, URL publik, cookie HTTPS, dan key enkripsi tetap memakai ConfigMap/Secret live yang sama. Script branding tidak menerapkan ulang manifest instalasi atau merotasi secret.

## Cakupan dan lisensi

Deployment internal ini dinyatakan memiliki kurang dari 50 pengguna. LICENSE v0.13.3 mengizinkan pengecualian perubahan branding untuk tidak lebih dari 50 individu dengan akses langsung dalam periode berjalan 30 hari. Jika jumlah pengguna bertambah melampaui batas itu, tinjau izin tertulis/lisensi enterprise sebelum melanjutkan branding. Ini bukan pengecualian umum untuk setiap pengguna paket ini.

License, license history dan notice upstream disertakan tanpa perubahan pada `branding/licenses/` dan image turunan. Detail versi/sumber upstream serta halaman dokumentasi/administrasi dapat tetap menyebut Open WebUI. Adapter menyamakan title HTML awal dengan nama runtime sebelum frontend bootstrap selesai. Paket tidak memodifikasi bundle frontend atau menyembunyikan pemberitahuan lisensi.

Referensi yang menentukan: [LICENSE v0.13.3](https://github.com/open-webui/open-webui/blob/v0.13.3/LICENSE).

## 1. Selesaikan indexing dan ambil kode terbaru

Tunggu file Excel yang masih Processing selesai terlebih dahulu, karena rollout menghentikan aplikasi sementara. Jangan mulai saat ada upload/processing/chat yang perlu diselesaikan.

Pada bastion:

```bash
cd /home/ubuntu/open-webui-ntnx
git status --short
git pull --ff-only
kubectl config current-context
kubectl -n open-webui get pods,pvc
df -h /tmp .
```

Pod aplikasi harus Ready, replica satu, dan PVC Bound. Jika `git pull` melaporkan konflik, simpan perubahan lokal dan selesaikan konfliknya; jangan menimpa config/credential dengan checkout/reset. Perubahan branding berada pada file baru dan tidak mengganti file `configmap.yaml` atau `project.example.yaml` yang sudah disesuaikan.

Sediakan ruang untuk dua arsip: image tidak terkompresi di direktori sementara saat publish, dan backup data PVC terkompresi di bastion. Ukur sesuai isi PVC, bukan hanya file Excel. Backup mencakup credential dan harus disimpan privat; direktori `backups/` diabaikan Git. Bila perlu, set `BACKUP_ROOT` ke disk lain dengan ruang cukup.

## 2. Build image turunan pada bastion

Tidak perlu rebuild frontend atau download ulang embedding. Ganti tag bila membuat revisi berikutnya agar tidak memakai cache image dengan tag lama.

```bash
export DEWA_IMAGE=registry.bercalab.my.id/chatbot/open-webui:v0.13.3-dewa1
export BASE_IMAGE=ghcr.io/open-webui/open-webui:v0.13.3
bash branding/build.sh
```

Build hanya menyalin launcher, aset dan lisensi ke image versi sama. Base image GHCR di atas sudah pernah dipull ketika instalasi awal. Kalau menggunakan base mirror lain, pastikan isinya versi 0.13.3 yang sama; launcher menolak versi lain.

`.dockerignore` membatasi build context pada file branding yang dibutuhkan. `secret.env`, file konfigurasi cluster, dan backup tidak dikirim ke build context.

## 3. Publish ke Harbor self-signed

Kasus bastion ini: Docker login berhasil tetapi push gagal di token endpoint, dan Skopeo bawaan terlalu tua untuk Docker daemon API. Script publish memakai **docker save → docker-archive → Skopeo**, sehingga kedua jalur bermasalah itu dilewati.

```bash
export HARBOR_URL=registry.bercalab.my.id
export HARBOR_TLS_VERIFY=false
bash branding/publish.sh
```

Isi username/password Harbor saat Skopeo meminta. Bypass TLS hanya dipakai pada koneksi Skopeo ke Harbor sesuai pilihan deployment ini; default script tetap memverifikasi TLS. Credential dan arsip image sementara dihapus saat script berakhir. Publish ini tidak mengubah cluster.

## 4. Backup konsisten dan rollout image

Pilih waktu tidak ada Processing atau chat aktif. Simpan backup di disk bastion yang cukup besar:

```bash
# Opsional; default ./backups pada root repo:
# export BACKUP_ROOT=/path/disk-backup/dewa
bash branding/rollout.sh
```

Urutan script:

1. Memeriksa satu replica Ready, strategi Recreate, dan referensi PVC yang diharapkan.
2. Menyimpan metadata Deployment, ConfigMap, Secret aplikasi, Secret Harbor, dan PVC ke direktori backup privat.
3. Scale aplikasi ke 0 dan menunggu pod berhenti. Ada downtime mulai tahap ini.
4. Membuat pod backup sementara pada worker yang sama, memakai image lama yang sudah tersedia dan mount PVC read-only.
5. Menyalin **seluruh isi PVC** ke `data.tar.gz` pada bastion, membaca ulang arsip untuk memeriksa integritas, dan membuat checksum SHA-256.
6. Menghapus pod backup, mengganti hanya image container `open-webui`, lalu scale kembali ke 1 dan menunggu rollout.

Script tidak menghapus/membuat ulang namespace, PVC, database, user, Knowledge, ConfigMap, atau Secret. Jika proses gagal setelah aplikasi dihentikan, trap mencoba menghapus pod backup dan memulihkan image serta replica lama. Kalau penghapusan helper gagal, aplikasi dibiarkan berhenti agar PVC tidak dipakai bersamaan; periksa pesan dan helper yang disebutkan sebelum melanjutkan. Untuk proses yang dihentikan paksa/mesin mati, jalankan pemulihan manual di bagian rollback.

Backup lengkap berada pada path yang dicetak script, bukan hanya metadata Kubernetes. Lindungi `app-secret.yaml`, `harbor-secret.yaml`, dan arsip datanya; jangan upload ke repo/chat. Pemeriksaan arsip membuktikan arsip terbaca, bukan pengganti uji restore pada namespace terpisah.

## 5. Verifikasi melalui hostname yang sudah berjalan

Buka https://openwebui.bercalab.my.id dan lakukan hard refresh (Ctrl+Shift+R). Jika favicon lama tersimpan di browser atau cache Cloudflare, hapus cache untuk aset `/static/favicon*`, `/static/splash*`, dan `/static/logo.png`; tidak perlu menghapus data situs atau chat server.

Periksa:

- Login menampilkan DEWA dan logo lama.
- Sidebar, tab browser, splash light/dark, favicon, serta ikon aplikasi memakai DEWA.
- Login, daftar user/grup, chat lama dan koleksi dokumen tetap tersedia.
- Chat Alibaba masih streaming dan RAG pada koleksi lama masih mengembalikan sumber yang benar.
- Tema light dan dark, layar ponsel, serta keyboard login tetap bekerja.

Dari bastion, tanpa mencetak credential:

```bash
kubectl -n open-webui get pods,pvc
kubectl -n open-webui logs deployment/open-webui --tail=80
curl -fsS https://openwebui.bercalab.my.id/api/config \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])'
```

Hasil nama yang diharapkan: `DEWA`. Jika Cloudflare Access mengharuskan autentikasi, lakukan cek API melalui browser yang sudah login. Route Cloudflare dan hostname tidak perlu diganti.

## Rollback image tanpa mengganti data

Jika script selesai tetapi ada masalah saat pemeriksaan UI, ambil image lama dari `old-image.txt` dalam folder backup yang dicetak. Ganti path berikut dengan path backup yang benar:

```bash
BACKUP_DIR=/path/backup/branding-TIMESTAMP.SUFFIX
OLD_IMAGE=$(cat "$BACKUP_DIR/old-image.txt")
kubectl -n open-webui set image deployment/open-webui "open-webui=$OLD_IMAGE"
kubectl -n open-webui scale deployment/open-webui --replicas=1
kubectl -n open-webui rollout status deployment/open-webui --timeout=1800s
```

Pastikan pod helper backup sudah terhapus sebelum scale ke 1 jika sebelumnya ada kegagalan cleanup. Rollback ini memakai data yang sama, dengan aplikasi versi 0.13.3 yang sama. Tidak perlu restore database hanya untuk membatalkan perubahan nama/logo.

Setelah branding, gunakan jalur ini untuk revisi branding. Script instalasi lama `harbor-deploy.sh --all`/`--deploy` dan root `kubectl apply -k .` masih menunjuk image upstream awal; menjalankannya dapat mengembalikan branding atau konfigurasi dari file lokal. Jangan gunakan jalur instalasi ulang untuk update branding.

## Implementasi dan hasil pemeriksaan

- `dewa_app.py` mengatur nama sebelum config/main upstream dimuat, sehingga API config, judul runtime, login dan manifest memakai DEWA tanpa suffix. Wrapper ASGI menyamakan title HTML awal; API JSON, WebSocket dan streaming chat diteruskan tanpa transformasi. Ia tidak menulis ulang source upstream, CSS atau bundle frontend.
- Logo disalin ke **build/static**, karena config upstream menyinkronkan file dari sana ke direktori static runtime setiap startup. Mengganti file runtime saja tidak cukup.
- Launcher tetap satu worker, memakai Secret yang sudah ada, proxy headers dan WebSocket seperti launcher upstream. Jalur ini khusus image CPU standar pada deployment ini; setup Ollama/CUDA/Playwright/Spaces dari launcher upstream tidak dijalankan.
- Aset raster dihasilkan dari SVG lama dengan `@resvg/resvg-js` 2.6.2. Regenerasi opsional: `npm ci --prefix branding` lalu `npm run render --prefix branding`. Node tidak diperlukan untuk build image/deploy karena aset hasil render sudah masuk repo.
- Pemeriksaan lokal: sintaks shell/Python, hash SVG asli, ukuran ikon/ICO, link dokumentasi dan kontras glyph 17.93:1 lolos. Sepuluh tes lolos, mencakup identitas, title HTML streaming, pass-through SSE/WebSocket, urutan backup sebelum ganti image, penolakan mount yang salah, serta pemulihan saat backup/rollout gagal. Jalankan ulang dengan `python3 -m unittest discover -s branding/tests -v`.
- Delivery gate untuk scope branding: PASS aset berasal dari logo yang diberikan; PASS tidak menambah kontrol/layout/animasi; PASS source upstream/CSS/bundle tidak ditulis ulang; PASS alur data diuji melalui simulasi. Sesuai instruksi operator, verifikasi Docker/image dan UI container diserahkan ke bastion; build, login, tema, tampilan mobile/keyboard, dan tes chat/RAG nyata belum dinyatakan lulus.
