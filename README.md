# Open WebUI di cluster Kubernetes Nutanix (deploy manual)

Paket ini berdiri sendiri di namespace `open-webui`. Tidak diikutkan ke Kustomize DEWA atau Flux. Semua perintah di bawah dijalankan manual dari mesin yang punya akses cluster; contoh shell memakai Bash di Linux/WSL.

**Mulai di [panduan deploy dari awal sampai bisa diakses](docs/DEPLOY.md).** Panduan tersebut mencakup clone repo, file yang perlu diisi, konfigurasi Harbor/Kommander/StorageClass, menjalankan script, login, tes Alibaba dan dokumen, serta akses lewat Cloudflare Tunnel.

```bash
git clone https://github.com/avecenabasuni/open-webui-ntnx.git
cd open-webui-ntnx
```

Untuk repository private, gunakan akun GitHub yang memiliki akses saat clone.

## Jalur deploy mengikuti DEWA

Gua menyesuaikan paket ini dari file deployment DEWA, bukan dari hasil inspeksi cluster hidup:

| Bukti di repo DEWA | Penyesuaian Open WebUI |
| --- | --- |
| `k8s/harbor-deploy.sh`: build/push ke Harbor, buat pull Secret, apply berurutan, tunggu rollout | Script dengan flag `--push`, `--deploy`, `--all`, `--create-secret`; cukup mirror image resmi, tanpa build aplikasi |
| Registry `registry.bercalab.my.id`, project Harbor `chatbot` | Repository baru `registry.bercalab.my.id/chatbot/open-webui:v0.13.3` |
| `k8s/00-namespace.yaml`: Kommander Project di `kommander`, workspace `kommander-workspace`, placement `host-cluster` | Project terpisah `open-webui` melalui `project.example.yaml`; nilai workspace/placement wajib dicocokkan |
| Script lama mendeteksi StorageClass default atau menerima `STORAGE_CLASS_NAME` dan menolak bucket class | Script baru melakukan pemeriksaan yang sama dan memasukkan class ke PVC render |
| Config Cloudflare lama merutekan hostname ke Service DNS Kubernetes | Hostname baru diarahkan ke `http://open-webui.open-webui.svc.cluster.local:80` |
| Overlay prod memakai PostgreSQL eksternal dan Nutanix Objects | Uji awal memakai PVC baru untuk SQLite/Chroma/upload; tidak memakai database atau bucket DEWA |
| Workflow GitHub Actions dan `flux/clusters/prod/sync.yaml` menunjuk overlay DEWA | Paket ini tetap manual di folder terpisah; tidak perlu push repo DEWA atau reconcile Flux |

Repo memuat jalur manual dan GitOps. Jalur mana yang sedang aktif di cluster belum diverifikasi. Overlay production menghapus cloudflared dari hasil render; keberadaan ConfigMap tunnel di repo tidak membuktikan bahwa itulah konfigurasi connector yang sedang berjalan.

### Cara utama: Harbor lalu deploy

Salin folder ini ke mesin deploy, masuk ke folder tersebut. Butuh Bash, Docker (saat mirror/pembuatan registry Secret), dan kubectl. Project Harbor `chatbot` harus tersedia dan akun lu punya izin push repository baru.

```bash
cp secret.env.example secret.env
chmod 600 secret.env
# Edit secret.env: key Alibaba, WEBUI_SECRET_KEY, email/password admin.

export HARBOR_URL=registry.bercalab.my.id
export HARBOR_PROJECT=chatbot
export IMAGE_TAG=v0.13.3
export HARBOR_USER='ISI_USERNAME_HARBOR'
read -rsp 'Harbor password: ' HARBOR_PASSWORD; echo
export HARBOR_PASSWORD

kubectl config current-context
kubectl get storageclass
# Jika ingin class tertentu, set persis seperti hasil cluster:
# export STORAGE_CLASS_NAME=nutanix-volume-v2

# Cocokkan project.example.yaml dengan workspace dan placement DEWA.
export NAMESPACE_MODE=kommander
bash harbor-deploy.sh --all
unset HARBOR_PASSWORD
```

Script `--all`: login Harbor menggunakan stdin, pull/tag/push image resmi, buat Kommander Project, tunggu namespace, buat `harbor-secret`, deteksi/validasi StorageClass, server dry-run manifest, buat Secret aplikasi, apply, restart untuk membaca environment terbaru, lalu tunggu rollout. Credential Docker sementara dihapus saat script keluar; script tidak mencetak password/key.

Untuk mesin mirror dan mesin cluster yang berbeda, jalankan `--push` pada mesin Docker yang bisa akses sumber image dan Harbor. Jalankan `--deploy` pada mesin cluster. Jika `harbor-secret` sudah dibuat di namespace baru, mesin cluster tidak perlu Docker atau credential Harbor. Jika belum, buat dulu dengan `--create-secret` di mesin yang punya Docker dan akses cluster.

Jika management dan workload cluster terpisah, apply `project.example.yaml` pada context management terlebih dahulu. Setelah Project menempatkan namespace pada target yang benar, pindah kubectl ke workload context dan gunakan `NAMESPACE_MODE=existing`. Script default mengasumsikan Project dan workload dapat dikelola dari context yang sama, seperti script DEWA lama.

Jika cluster memang tidak memakai Kommander, gunakan `NAMESPACE_MODE=namespace`. Jika namespace sudah dikelola Project yang dibuat sebelumnya, gunakan `NAMESPACE_MODE=existing`. Script tidak otomatis mengganti mode ketika Kommander tidak ditemukan.

Render lokal tanpa menyentuh cluster atau memuat credential:

```bash
STORAGE_CLASS_NAME=CLASS_LU bash harbor-deploy.sh --render > rendered.yaml
# Periksa image, namespace, dan class sebelum apply dari mesin cluster.
```

Untuk deploy ulang, gunakan parameter registry/tag/class yang sama dan `bash harbor-deploy.sh --deploy`. Untuk upgrade versi, set `SOURCE_IMAGE` ke image resmi versi tujuan dan `IMAGE_TAG` ke tag tujuan Harbor; mengubah `IMAGE_TAG` saja hanya mengganti tag tujuan mirror. Perubahan koneksi Alibaba yang tersimpan di UI tetap mengikuti aturan persistent config di bawah. Jangan menjalankan `kubectl apply -k .` setelah render dengan override custom karena root Kustomize memakai default Harbor dan default StorageClass; gunakan script yang sama agar nilainya konsisten.

## Isi dan batas awal

| Komponen | Konfigurasi |
| --- | --- |
| Open WebUI | Image resmi `v0.13.3` dimirror ke Harbor, image lengkap tanpa Ollama/CUDA |
| Chat | Alibaba Model Studio Singapore, endpoint workspace dari chat sebelumnya |
| Embedding | SentenceTransformers lokal CPU, `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` |
| Penyimpanan | PVC RWO 20 GiB: SQLite, Chroma embedded, upload, cache model |
| Pod | 1 replica, strategi Recreate; request 0.5 CPU / 2 GiB, limit 2 CPU / 4 GiB |
| Akses awal | ClusterIP + port-forward localhost; Ingress HTTPS opsional |
| Login | Admin otomatis dari Secret saat database kosong; pendaftaran umum mati |

Ini konfigurasi uji awal dengan downtime saat restart, bukan HA. Jangan menambah replica dengan SQLite/Chroma embedded. Kapasitas dan kualitas retrieval perlu diuji memakai dokumen representatif.

Dokumen, vektor, dan proses embedding berada di cluster. **Pertanyaan serta potongan dokumen yang diambil untuk jawaban dikirim ke Alibaba.** Fitur full-context dapat mengirim seluruh dokumen. Pilih dokumen yang boleh diproses provider tersebut untuk pengujian. Tidak ada migrasi database, user, atau dokumen DEWA dalam paket ini.

## 1. Detail pemeriksaan cluster dan storage

Salin seluruh folder ini ke mesin deploy, lalu masuk ke folder tersebut. Semua perintah berikut dijalankan dari dalam folder ini, tanpa memerlukan repository DEWA:

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass
kubectl get ingressclass
```

Pastikan context menunjuk cluster Nutanix yang dimaksud. `pvc.yaml` memakai StorageClass default. Jika tidak ada default, isi `spec.storageClassName` dengan class filesystem/RWO yang sudah teruji di cluster. Manifest DEWA menyebut `nutanix-volume-v2`; cocokkan dengan hasil cluster, jangan menganggap nama itu pasti tersedia. Tentukan ukuran sebelum PVC dibuat.

Mesin mirror perlu bisa pull image GHCR; node cluster menarik image Open WebUI dari Harbor. Pod perlu HTTPS keluar ke endpoint Alibaba dan Hugging Face beserta host download yang dirujuknya untuk unduhan model pertama. `RAG_EMBEDDING_MODEL_AUTO_UPDATE=false` menghindari update otomatis, tetapi cache kosong tetap memerlukan download pertama. Ini bukan deployment air-gapped. Pastikan kebijakan jaringan cluster mengizinkan DNS dan egress tersebut.

Kustomize root sudah mengarahkan image ke Harbor dan Deployment sudah memakai `imagePullSecrets: harbor-secret`. Script merender registry/project/tag sesuai environment tanpa mengubah file sumber. Jika GHCR diblokir di mesin deploy, mirror dari mesin lain dengan `--push`. Secret registry harus dibuat di namespace `open-webui`; Secret namespace DEWA tidak otomatis tersedia.

## 2. Alternatif apply manual: namespace dan Secret

Bagian ini untuk apply tanpa script deploy. Untuk pola Kommander seperti DEWA, apply `project.example.yaml` pada management context dan tunggu namespace target tersedia. Gunakan `namespace.yaml` hanya jika sengaja memakai Namespace biasa. Sebelum apply workload, mirror image memakai `bash harbor-deploy.sh --push`, lalu buat `harbor-secret` di namespace baru:

```bash
# NAMESPACE_MODE=existing jika namespace sudah dibuat Kommander.
NAMESPACE_MODE=existing bash harbor-deploy.sh --create-secret
```

Perintah di atas memerlukan `HARBOR_USER`/`HARBOR_PASSWORD` dan Docker. Lanjutkan pembuatan Secret aplikasi berikut; script `--deploy` sudah mengotomasi langkah ini.

```bash
# Jika memakai Namespace biasa (bukan Project):
# kubectl apply -f ./namespace.yaml
cp ./secret.env.example ./secret.env
chmod 600 ./secret.env
```

Edit `secret.env` memakai editor di mesin deploy, ganti semua `REPLACE_WITH_...`:

- `OPENAI_API_KEY`: key Alibaba Singapore yang valid untuk workspace tersebut. Isi hanya key, tanpa `Bearer` atau `API-Key:`.
- `WEBUI_SECRET_KEY`: nilai acak dari `openssl rand -hex 32`. Simpan nilainya untuk backup/restore; jangan mengganti saat setiap deploy karena dipakai untuk sesi dan enkripsi data sensitif.
- `WEBUI_ADMIN_EMAIL`: email admin yang akan dipakai login.
- `WEBUI_ADMIN_PASSWORD`: password unik dan kuat. Gunakan satu baris tanpa quote pembungkus; `kubectl --from-env-file` membaca nilai literal, bukan ekspansi shell.

`secret.env` diabaikan oleh aturan `*.env` di `.gitignore` paket ini. Jangan commit file credential atau YAML hasil render Secret.

```bash
kubectl -n open-webui create secret generic open-webui-secrets \
  --from-env-file=./secret.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

Admin bootstrap hanya dibuat jika database belum berisi user. Mengubah password di Secret setelah itu tidak mereset password akun; ubah dari UI. Simpan credential di password manager.

## 3. Render, validasi, deploy

```bash
kubectl kustomize . > /tmp/open-webui.yaml
kubectl apply --dry-run=server -f /tmp/open-webui.yaml
kubectl apply -k .
kubectl -n open-webui get pvc,pods,svc
kubectl -n open-webui rollout status deployment/open-webui --timeout=1800s
```

PVC harus `Bound`, pod harus `1/1 Running`. Startup probe memberi waktu hingga sekitar 30 menit untuk startup dan unduhan pertama. Jika timeout, lihat log sebelum restart:

```bash
kubectl -n open-webui logs deployment/open-webui --tail=150
kubectl -n open-webui describe pod -l app.kubernetes.io/name=open-webui
kubectl -n open-webui describe pvc open-webui-data
```

## 4. Login dan konfigurasi Alibaba

```bash
kubectl -n open-webui port-forward service/open-webui 3001:80
```

Buka `http://localhost:3001`, login memakai admin di Secret. Jika browser berada di laptop lain, dari laptop buat SSH local forward ke mesin deploy:

```bash
ssh -L 3001:127.0.0.1:3001 USER@MESIN_DEPLOY
```

Biarkan kedua proses forward berjalan. Port-forward default hanya mendengarkan localhost.

Di **Admin Panel → Settings → Connections**, periksa koneksi OpenAI-compatible:

```text
URL: https://ws-86ipn63on3u7czuo.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1
API key: key Alibaba Singapore untuk workspace tersebut
```

Gunakan URL sampai `/v1`, tanpa menambahkan `/chat/completions`. Koneksi ini menuju Alibaba walaupun field UI bernama OpenAI. Ollama dinonaktifkan.

Tes koneksi, lalu pilih model chat yang tersedia dan diizinkan untuk akun/workspace. Jangan menganggap semua model Alibaba tersedia pada key ini. Bila `/models` tidak didukung tetapi model chat sudah diketahui, isi model ID secara manual di konfigurasi koneksi dan uji chat. Kirim pesan pendek, pastikan jawaban streaming dan tersimpan di riwayat.

Untuk diagnosis dari dalam pod tanpa mencetak key:

```bash
kubectl -n open-webui exec -i deployment/open-webui -- python - <<'PY'
import os
import urllib.error
import urllib.request
url = os.environ['OPENAI_API_BASE_URL'].rstrip('/') + '/models'
request = urllib.request.Request(url, headers={
    'Authorization': 'Bearer ' + os.environ['OPENAI_API_KEY'],
})
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        print('GET /models HTTP', response.status)
except urllib.error.HTTPError as error:
    print('GET /models HTTP', error.code)
except urllib.error.URLError:
    print('Koneksi gagal: periksa DNS, egress, proxy, dan CA di pod.')
PY
```

Tes ini membaca environment pod, bukan konfigurasi yang kemudian disimpan di UI. `200` membuktikan endpoint model-list menerima key, bukan bahwa semua model bisa dipanggil. `401` pada chat sebelumnya belum terbukti selesai: periksa key aktif, workspace, region, dan jenis paket. Endpoint umum Singapore untuk diagnosis adalah `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`; jangan mencampur key Standard dengan endpoint Coding Plan. Ganti URL dan key sebagai pasangan.

### Prioritas konfigurasi dan rotasi key

`ENABLE_PERSISTENT_CONFIG=true`: environment memberi nilai awal, lalu pengaturan tersimpan di database/UI dapat mengalahkannya. **Cara yang disarankan setelah instalasi: ubah URL/key di Connections, simpan, tes, lalu restart untuk memastikan tersimpan.** Samakan `secret.env` dan `configmap.yaml` dengan nilai terbaru untuk instalasi ulang/backup.

Mengubah Secret saja tidak menjamin key tersimpan di UI ikut berubah. Untuk menerapkan environment baru ke pod:

```bash
kubectl -n open-webui create secret generic open-webui-secrets \
  --from-env-file=./secret.env \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k .
kubectl -n open-webui rollout restart deployment/open-webui
kubectl -n open-webui rollout status deployment/open-webui --timeout=1800s
```

Tetap perbarui Connections jika nilainya sudah tersimpan. Jangan menghapus PVC untuk merotasi key. Bila ingin seluruh setting dikontrol manifest, gunakan `ENABLE_PERSISTENT_CONFIG=false`, tetapi semua perubahan setting melalui UI akan hilang setelah restart; pilihan ini juga memengaruhi setting lain, bukan hanya provider.

## 5. Periksa embedding lokal dan Knowledge

Di **Admin Panel → Settings → Documents**, pastikan:

| Setting | Nilai awal |
| --- | --- |
| Embedding engine | Default / SentenceTransformers (environment berupa string kosong) |
| Embedding model | `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` |
| Chunk size / overlap | 400 / 80 karakter |
| Top K | 5 |
| Hybrid search | Mati untuk uji awal |

Model ini multilingual, menghasilkan 384 dimensi, dan memiliki batas 128 token per input. Chunk 400 karakter merupakan titik awal konservatif, bukan jaminan tidak terpotong untuk semua bahasa. Evaluasi retrieval; jika berganti model, chunking, atau dimensi, indeks ulang dokumen. Tidak perlu API key embedding Alibaba, Ollama, atau GPU. Cache model ikut PVC.

1. Buka **Workspace → Knowledge**, buat koleksi **Dokumen Perusahaan**.
2. Upload satu dokumen TXT atau PDF berbasis teks dahulu. Tunggu pemrosesan selesai, lalu periksa teks hasil ekstraksi/preview.
3. Buka chat baru, pilih model Alibaba, lampirkan koleksi melalui pemilih Knowledge/`#`. Gunakan focused retrieval/RAG untuk uji ini, bukan entire-document/full-context.
4. Tanyakan fakta spesifik yang ada dalam dokumen. Periksa jawaban, sumber, dan isi kutipannya. Uji juga pertanyaan yang jawabannya tidak ada.
5. Opsional: buat model preset **Asisten Perusahaan** di Workspace → Models, pilih model Alibaba sebagai basis dan kaitkan koleksi Knowledge. Instruksikan menjawab dari sumber dan menyatakan jika sumber tidak cukup.
6. Buat user dan grup lewat Admin Panel, lalu atur akses Knowledge dan preset model untuk grup yang berhak. Untuk dokumen internal, gunakan akses terbatas; uji dengan akun biasa yang berhak dan yang tidak berhak.

PDF scan memerlukan OCR; OCR tambahan belum disediakan paket ini. Tabel kompleks dan Excel perlu diuji karena retrieval teks tidak menjamin perhitungan agregat benar.

## 6. Akses lewat Cloudflare Tunnel seperti DEWA

Gunakan hostname baru, misalnya `openwebui.bercalab.my.id`, setelah memastikan hostname itu tersedia dan domainnya lu kelola. Semua UI/API Open WebUI lewat satu Service; tidak perlu hostname frontend dan backend terpisah.

Sebelum memilih cara konfigurasi, dari mesin cluster periksa connector lama:

```bash
kubectl -n cloudflare-tunnel get deployment cloudflared
kubectl -n cloudflare-tunnel get deployment cloudflared -o jsonpath='{.spec.template.spec.containers[0].args}'
kubectl -n cloudflare-tunnel get deployment cloudflared -o jsonpath='{.spec.template.spec.containers[0].command}'
kubectl -n cloudflare-tunnel get configmap cloudflared-config -o yaml
```

Periksa args/command di mesin lu; jangan membagikan output kalau mengandung token literal. Cocokkan connector dengan tunnel aktif di dashboard. Jika resource/namespacenya berbeda atau tidak ada, temukan deployment connector aktual. Karena prod overlay DEWA menghapus resource tunnel, jangan apply ulang manifest tunnel lama hanya karena file itu ada di repo.

Untuk **remotely managed tunnel** yang sudah tersambung ke cluster, tambahkan satu published application route pada tunnel tersebut di dashboard Cloudflare:

```text
Public hostname: openwebui.bercalab.my.id  (contoh; pilih hostname lu)
Service URL:    http://open-webui.open-webui.svc.cluster.local:80
```

Untuk **locally managed tunnel** yang benar-benar membaca ConfigMap, tambahkan rule berikut ke konfigurasi aktif sebelum catch-all `http_status:404`. Pertahankan route DEWA dan pengaturan lainnya:

```yaml
- hostname: openwebui.bercalab.my.id
  service: http://open-webui.open-webui.svc.cluster.local:80
  originRequest:
    connectTimeout: 30s
    keepAliveTimeout: 90s
```

Buat DNS hostname baru ke tunnel yang sesuai melalui mekanisme Cloudflare yang dipakai. Apply melalui sumber konfigurasi pemiliknya (repo GitOps jika resource dikelola Flux), lalu restart connector hanya jika diperlukan agar file konfigurasi dimuat ulang. Perubahan connector bersama dapat memutus sesi aktif sementara; paket Open WebUI ini tidak mengubah connector tersebut secara otomatis. Connector harus dapat resolve Service DNS dan mencapai namespace `open-webui`, termasuk jika ada NetworkPolicy lintas namespace.

Set `WEBUI_URL` di `configmap.yaml` ke URL HTTPS hostname lu, lalu deploy ulang. Setelah uji port-forward selesai, aktifkan cookie secure seperti langkah di bawah. HTTPS publik diakhiri di Cloudflare dan origin Service memakai HTTP di dalam cluster. Tidak perlu Ingress/sertifikat origin untuk jalur langsung ini. Uji login, upload, streaming, dan riwayat di hostname baru; route DEWA harus tetap bekerja. Untuk rollback publikasi, hapus hanya route/DNS hostname Open WebUI, bukan tunnel bersama.

Referensi: [Cloudflare Tunnel di Kubernetes](https://developers.cloudflare.com/tunnel/guides/kubernetes/) dan [routing aplikasi](https://developers.cloudflare.com/tunnel/concepts/routing/).

### Alternatif: Ingress HTTPS

`ingress.example.yaml` sengaja tidak masuk `kustomization.yaml`. Setelah port-forward berhasil:

1. Ganti `openwebui.example.com` dengan hostname baru yang lu kelola, terpisah dari DEWA.
2. Sesuaikan `ingressClassName` dari `kubectl get ingressclass`; `kommander-traefik` mengikuti contoh repo, belum diverifikasi di cluster.
3. Siapkan DNS ke ingress controller dan Secret TLS bernama `open-webui-tls` di namespace `open-webui` melalui mekanisme sertifikat cluster. Contoh jika punya berkas sertifikat:

   ```bash
   kubectl -n open-webui create secret tls open-webui-tls \
     --cert=/path/fullchain.pem --key=/path/privkey.pem
   ```

4. Set `WEBUI_URL: "https://HOSTNAME_LU"` di `configmap.yaml`, apply Kustomize dan restart pod. Jika cookie hanya akan dipakai lewat HTTPS, set juga `WEBUI_SESSION_COOKIE_SECURE: "true"` dan `WEBUI_AUTH_COOKIE_SECURE: "true"`; login lewat HTTP port-forward tidak lagi cocok untuk cookie secure.
5. Apply dan cek:

   ```bash
   kubectl apply -f ./ingress.example.yaml
   kubectl -n open-webui get ingress
   ```

Uji login, upload, streaming, dan riwayat melalui hostname HTTPS. Proxy/WAF di jalurnya harus mengizinkan streaming SSE/WebSocket serta ukuran upload yang dibutuhkan.

## 7. Verifikasi dan pemeliharaan

- Chat Alibaba streaming berhasil dan riwayat tetap ada setelah login ulang.
- Satu dokumen berhasil diindeks lokal; pertanyaan spesifik mengembalikan sumber yang cocok.
- Akun tanpa akses tidak dapat membuka koleksi atau mengambil isinya.
- Restart deployment, tunggu ready, pastikan user, riwayat, dokumen, dan Knowledge tetap tersedia.
- Catat pemakaian RAM/CPU/PVC sebelum menambah dokumen; naikkan limit jika `OOMKilled` dan kapasitas node mencukupi.

Backup: untuk snapshot konsisten SQLite dan Chroma, jadwalkan downtime, scale deployment ke 0, tunggu pod berhenti, ambil snapshot/backup PVC dengan fasilitas CSI/Nutanix yang tersedia, lalu scale kembali ke 1. Simpan juga Secret `WEBUI_SECRET_KEY` dan credential melalui secret manager terpisah. Snapshot PVC bergantung dukungan cluster dan belum disediakan manifest ini. Uji restore di namespace percobaan sebelum upgrade image; rollback image saja belum tentu kompatibel setelah migrasi database.

Menghapus deployment tidak menghapus PVC. Menghapus PVC atau namespace dapat menghilangkan data, tergantung reclaim policy PV. Jangan memakai penghapusan namespace sebagai langkah troubleshooting.

| Gejala | Pemeriksaan |
| --- | --- |
| PVC Pending | StorageClass default/nama class, kapasitas, event CSI; WaitForFirstConsumer dapat menunggu penjadwalan pod |
| ImagePullBackOff | Akses GHCR, tag image, mirror Harbor dan imagePullSecret di namespace ini |
| Startup lama | Log download Hugging Face, DNS/egress/CA, kapasitas cache; jangan aktifkan offline sebelum cache siap |
| Permission denied di PVC | UID/GID image dan izin filesystem CSI; sesuaikan securityContext dengan kebijakan cluster |
| Alibaba 401 | Key aktif dan pasangan workspace/region/plan/URL; cek nilai yang tersimpan di Connections |
| Model list kosong/404 | Dukungan `/models`, izin model; coba model ID yang diketahui lewat chat |
| Pod OOMKilled | Memori saat parsing/embedding, ukuran/jumlah dokumen, limit dan kapasitas node |
| Jawaban tidak menemukan isi | Koleksi terlampir, status indeks, teks ekstraksi, chunk/model embedding, akses user |

## Referensi dan status validasi

- [Release v0.13.3](https://github.com/open-webui/open-webui/releases/tag/v0.13.3)
- [Environment Open WebUI, termasuk persistent config dan bootstrap admin](https://docs.openwebui.com/reference/env-configuration/)
- [Knowledge dan akses koleksi](https://docs.openwebui.com/features/workspace/knowledge/)
- [Model embedding multilingual](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2)
- [Endpoint Alibaba dan pasangan key](https://www.alibabacloud.com/help/en/model-studio/base-url)

Validasi lokal: Bash syntax dan help berhasil; render dengan override StorageClass menghasilkan image Harbor, pull Secret, dan namespace yang sesuai. Simulasi deploy memakai kubectl tiruan memverifikasi mode namespace existing/Kommander, urutan server dry-run sebelum Secret aplikasi/apply workload, penolakan bucket StorageClass, dan penolakan perubahan class PVC existing. Ini tidak membuktikan konektivitas atau provisioning nyata.

Belum dijalankan di cluster Nutanix; validasi server nyata, Kommander placement, login/push Harbor, provisioning PVC, startup/download model, key Alibaba, streaming, RAG, dan akses grup perlu dijalankan dari mesin deploy.
