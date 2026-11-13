# Deploy Open WebUI ke cluster Kubernetes Nutanix

Panduan ini mengikuti pola deployment DEWA yang ada di repo lama: mirror image ke Harbor, Kommander Project, Secret registry, PVC, lalu workload. Open WebUI memakai namespace dan data sendiri. Deploy dilakukan manual dari mesin yang mempunyai akses cluster.

Jika aplikasi sudah terpasang dan ingin memakai nama/logo DEWA, gunakan [panduan update branding](BRANDING.md), bukan instalasi ulang di bawah.

Semua perintah memakai Bash di Linux/WSL. Paket sudah diuji render dan simulasi lokal; belum diverifikasi pada cluster hidup.

## 1. Clone repo pada mesin deploy

```bash
git clone https://github.com/avecenabasuni/open-webui-ntnx.git
cd open-webui-ntnx
```

Jika repo private, gunakan akun GitHub yang memiliki akses. Jalankan perintah selanjutnya dari folder ini.

Mesin deploy membutuhkan Git, Bash, kubectl dengan dukungan Kustomize, OpenSSL, dan Docker untuk mirror image serta membuat registry Secret. Periksa:

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass
docker info
```

Gunakan context cluster Nutanix yang benar. Mesin mirror harus bisa mengakses GHCR dan Harbor; node harus bisa menarik image dari Harbor. Pod perlu akses Alibaba serta Hugging Face dan host download modelnya saat unduhan embedding pertama.

## 2. File yang perlu disiapkan

| File | Tindakan sebelum deploy |
| --- | --- |
| `secret.env` | Wajib dibuat dari `secret.env.example`, lalu isi empat credential |
| `project.example.yaml` | Periksa namespace Project, workspace, dan placement sesuai DEWA |
| `configmap.yaml` | Periksa URL Alibaba; tambahkan URL publik setelah tes awal |
| `pvc.yaml` | Opsional: ubah kapasitas awal 20 GiB sebelum PVC dibuat |
| `deployment.yaml` | Opsional: sesuaikan request/limit CPU dan RAM |
| `harbor-deploy.sh` | Tidak perlu diedit; konfigurasi lewat environment |
| `ingress.example.yaml` | Tidak diperlukan jika Cloudflare langsung menuju Service |

Jangan commit `secret.env`, password Harbor, key Alibaba, atau YAML Secret hasil render. File credential `.env` sudah masuk `.gitignore`.

## 3. Cocokkan Kommander Project

Pada context management yang dipakai DEWA:

```bash
kubectl get projects.workspaces.kommander.mesosphere.io -A
# Sesuaikan namespace/nama Project jika hasil daftar berbeda:
kubectl -n kommander get project chatbot-prod -o yaml
nano project.example.yaml
```

Template baru:

```yaml
metadata:
  name: open-webui
  namespace: kommander
spec:
  workspaceRef:
    name: kommander-workspace
  namespaceName: open-webui
  placement:
    clusters:
      - name: host-cluster
```

Sesuaikan `metadata.namespace`, `workspaceRef.name`, dan nama cluster `placement` dengan konfigurasi DEWA pada cluster. Pertahankan nama Project dan `namespaceName` sebagai `open-webui`.

Pilih mode deployment:

- `NAMESPACE_MODE=kommander`: script membuat Project dan menunggu namespace; untuk context yang dapat mengelola Project sekaligus workload, mengikuti asumsi script lama.
- `NAMESPACE_MODE=existing`: namespace sudah dibuat oleh Project. Jika management dan workload memakai context berbeda, apply `project.example.yaml` pada management terlebih dahulu, kemudian pindah ke workload context dan gunakan mode ini.
- `NAMESPACE_MODE=namespace`: hanya untuk cluster yang sengaja memakai Namespace biasa tanpa Kommander.

Contoh jika context terpisah, ganti placeholder dengan nama context yang benar:

```bash
kubectl --context=CONTEXT_MANAGEMENT apply -f project.example.yaml
kubectl config use-context CONTEXT_WORKLOAD
kubectl get namespace open-webui
export NAMESPACE_MODE=existing
```

Tunggu penempatan Project selesai jika namespace belum tersedia. Jangan menjalankan mode Kommander pada workload context yang tidak memiliki CRD Project.

## 4. Isi Secret aplikasi

```bash
cp secret.env.example secret.env
chmod 600 secret.env
openssl rand -hex 32
nano secret.env
```

Ganti semua placeholder dengan nilai asli:

```dotenv
OPENAI_API_KEY=KEY_ALIBABA_ASLI
WEBUI_SECRET_KEY=HASIL_OPENSSL_TADI
WEBUI_ADMIN_EMAIL=EMAIL_ADMIN
WEBUI_ADMIN_PASSWORD=PASSWORD_ADMIN_YANG_KUAT
```

Nilai ditulis satu baris tanpa quote pembungkus. Key Alibaba hanya berisi key, tanpa awalan `Bearer` atau `API-Key:`. Simpan `WEBUI_SECRET_KEY` untuk backup/restore dan jangan menggantinya setiap deploy.

Admin otomatis dibuat hanya pada database kosong. Mengubah password dalam Secret setelah akun dibuat tidak mereset password akun; gunakan UI untuk mengganti password.

## 5. Periksa Alibaba, embedding, dan kapasitas

```bash
nano configmap.yaml
```

Endpoint workspace yang telah disiapkan:

```yaml
OPENAI_API_BASE_URL: "https://ws-86ipn63on3u7czuo.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
```

Pastikan key cocok dengan workspace dan region tersebut. Kegagalan `401` yang pernah terjadi belum terbukti selesai. Endpoint harus berakhir pada `/v1`, tanpa menambahkan `/chat/completions`.

Embedding sudah memakai CPU lokal; pengaturan ini dapat dibiarkan:

```yaml
RAG_EMBEDDING_ENGINE: ""
RAG_EMBEDDING_MODEL: "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
```

Model diunduh saat pertama diperlukan dan disimpan dalam PVC. Tidak perlu key embedding Alibaba, Ollama, atau GPU. Dokumen dan vektor berada di cluster, tetapi pertanyaan dan potongan dokumen untuk menjawab tetap dikirim ke Alibaba.

`pvc.yaml` meminta 20 GiB. Ubah `spec.resources.requests.storage` sebelum deploy pertama jika perlu kapasitas lain. Pod meminta 0.5 CPU/2 GiB RAM dan dibatasi 2 CPU/4 GiB; sesuaikan `deployment.yaml` dengan kapasitas node dan hasil uji ingestion. Tetap satu replica dengan strategi Recreate karena memakai SQLite/Chroma embedded.

## 6. Set Harbor, mode namespace, dan StorageClass

Pastikan project Harbor `chatbot` tersedia dan akun mempunyai izin push repository `open-webui`:

```bash
export HARBOR_URL=registry.bercalab.my.id
export HARBOR_PROJECT=chatbot
export IMAGE_TAG=v0.13.3
export HARBOR_USER='USERNAME_HARBOR'
read -rsp 'Harbor password: ' HARBOR_PASSWORD; echo
export HARBOR_PASSWORD
```

Jika memakai context yang sama seperti alur DEWA lama:

```bash
export NAMESPACE_MODE=kommander
```

Jika namespace sudah dibuat dari management context, tetap gunakan `existing` dari langkah 3.

```bash
kubectl get storageclass
```

Pilih class filesystem/block yang tersedia. Contoh ini hanya berlaku jika nama class memang ada pada cluster:

```bash
export STORAGE_CLASS_NAME=nutanix-volume-v2
```

Jangan gunakan class object bucket. Script akan memasukkan class ke manifest PVC saat render. Jika tidak mengisi variabel, mode deploy mendeteksi satu default StorageClass; mode render lokal memerlukan class eksplisit.

## 7. Render dan jalankan deploy

Dengan `STORAGE_CLASS_NAME` sudah diisi, periksa hasil render:

```bash
bash harbor-deploy.sh --render > rendered.yaml
less rendered.yaml
```

Periksa namespace `open-webui`, nama StorageClass, dan image Harbor. Jalankan:

```bash
bash harbor-deploy.sh --all
unset HARBOR_PASSWORD
```

Script menjalankan login Harbor, pull/tag/push image resmi, penyiapan Project/namespace, pembuatan `harbor-secret`, validasi StorageClass dan server dry-run, Secret aplikasi, apply workload, restart, lalu menunggu rollout.

Tidak ada build source aplikasi. Image tujuan default adalah `registry.bercalab.my.id/chatbot/open-webui:v0.13.3`. Unduhan embedding pertama dapat memperpanjang startup; startup probe dan rollout diberi waktu sekitar 30 menit.

Jika mesin mirror dan mesin cluster berbeda, gunakan `--push` pada mesin mirror, lalu `--deploy` pada mesin cluster dengan konfigurasi registry/tag yang sama. Mesin cluster perlu `harbor-secret` di namespace baru; buat menggunakan `--create-secret` dari mesin yang memiliki Docker, credential Harbor, dan akses cluster bila belum tersedia.

## 8. Cek workload dan buka akses sementara

```bash
kubectl -n open-webui get pods,pvc,svc
```

Target: pod `1/1 Running` dan PVC `Bound`. Jika gagal:

```bash
kubectl -n open-webui logs deployment/open-webui --tail=150
kubectl -n open-webui describe pod -l app.kubernetes.io/name=open-webui
kubectl -n open-webui describe pvc open-webui-data
```

Jalankan pada mesin deploy:

```bash
kubectl -n open-webui port-forward service/open-webui 3001:80
```

Jika browser ada di laptop lain, buka terminal laptop dan jalankan, mengganti USER/MESIN_DEPLOY:

```bash
ssh -N -L 3001:127.0.0.1:3001 USER@MESIN_DEPLOY
```

Biarkan kedua proses berjalan. Buka [http://localhost:3001](http://localhost:3001), login memakai email/password admin dari `secret.env`.

## 9. Tes chat Alibaba dan Knowledge

1. Buka **Admin Panel → Settings → Connections**. Periksa koneksi OpenAI-compatible ke URL Alibaba dan key yang benar. Tes koneksi, lalu pilih model yang tersedia pada akun/workspace.
2. Kirim chat pendek; pastikan streaming dan riwayat bekerja.
3. Di **Settings → Documents**, pastikan embedding **Default / SentenceTransformers** dengan model multilingual pada langkah 5.
4. Buka **Workspace → Knowledge**, buat koleksi **Dokumen Perusahaan**, upload TXT atau PDF berbasis teks, tunggu pemrosesan selesai dan periksa teks ekstraksinya.
5. Lampirkan koleksi dalam chat melalui pemilih Knowledge/`#`, gunakan focused retrieval/RAG, lalu tanyakan fakta spesifik. Periksa jawaban dan sumber dokumennya.
6. Buat user/grup dan batasi akses Knowledge. Uji dengan akun yang berhak dan akun yang tidak berhak sebelum memasukkan dokumen perusahaan lebih banyak.

PDF scan memerlukan OCR tambahan yang belum disediakan paket ini. Mengganti model embedding atau chunking memerlukan indeks ulang dokumen.

`ENABLE_PERSISTENT_CONFIG=true`: setting yang disimpan melalui UI dapat mengalahkan environment. Setelah instalasi pertama, perubahan URL/key dilakukan pada Connections, disimpan dan dites; samakan file lokal untuk kebutuhan reinstall. Mengubah `secret.env` dan restart saja belum tentu mengganti koneksi yang sudah tersimpan.

## 10. Tambahkan hostname Cloudflare

Contoh hostname: `openwebui.bercalab.my.id`. Gunakan hostname baru yang tersedia dan domain yang dikelola organisasi. Semua UI/API Open WebUI menuju satu Service.

Periksa connector lama dari mesin cluster:

```bash
kubectl -n cloudflare-tunnel get deployment cloudflared
kubectl -n cloudflare-tunnel get configmap cloudflared-config -o yaml
```

Jika resource tidak ada, temukan connector yang sebenarnya. Repo DEWA mempunyai file tunnel, tetapi prod overlay menghapusnya dari render; pastikan konfigurasi aktif sebelum mengubah route. Periksa command/args deployment di mesin sendiri untuk menentukan apakah connector membaca ConfigMap lokal atau konfigurasi remote; jangan membagikan token.

Untuk **remotely managed tunnel** yang sudah tersambung ke cluster, tambahkan published application route pada dashboard Cloudflare:

```text
Hostname:    openwebui.bercalab.my.id
Service URL: http://open-webui.open-webui.svc.cluster.local:80
```

Untuk **locally managed tunnel** yang benar-benar membaca file konfigurasi/ConfigMap, tambahkan rule berikut sebelum catch-all, sambil mempertahankan route DEWA:

```yaml
- hostname: openwebui.bercalab.my.id
  service: http://open-webui.open-webui.svc.cluster.local:80
  originRequest:
    connectTimeout: 30s
    keepAliveTimeout: 90s
```

Pastikan DNS hostname baru menuju tunnel yang benar. Terapkan perubahan melalui sumber konfigurasi pemiliknya; jika dikelola GitOps, ubah sumber GitOps. Reload/restart connector sesuai mekanismenya jika diperlukan. Script Open WebUI tidak mengubah tunnel bersama secara otomatis.

Connector harus dapat resolve DNS Service dan mencapai namespace `open-webui`, termasuk jika ada NetworkPolicy. Jalur langsung Tunnel → Service tidak memerlukan Ingress atau sertifikat origin tambahan. Lihat [panduan Cloudflare Kubernetes](https://developers.cloudflare.com/tunnel/guides/kubernetes/) dan [routing aplikasi](https://developers.cloudflare.com/tunnel/concepts/routing/).

## 11. Set URL publik dan tes akhir

Tambahkan pada bagian `data:` di `configmap.yaml`, sesuaikan hostname:

```yaml
WEBUI_URL: "https://openwebui.bercalab.my.id"
WEBUI_SESSION_COOKIE_SECURE: "true"
WEBUI_AUTH_COOKIE_SECURE: "true"
```

Gunakan environment registry/tag/class/mode namespace yang sama, kemudian:

```bash
bash harbor-deploy.sh --deploy
```

Setelah cookie secure aktif, login melalui hostname HTTPS publik. Uji login, chat streaming, upload, sumber jawaban, dan riwayat. Pastikan hostname DEWA tetap bekerja. Untuk membatalkan publikasi, hapus hanya route/DNS hostname Open WebUI, bukan tunnel bersama.

## 12. Deploy ulang dan troubleshooting

Untuk update manifest/config, jalankan `--deploy` dengan parameter yang sama. Jika perlu memperbarui credential Harbor, isi lagi environment password secara interaktif. Untuk upgrade image, atur **SOURCE_IMAGE dan IMAGE_TAG** ke versi tujuan, backup data dan secret dahulu, lalu jalankan `--all`. Mengubah IMAGE_TAG saja hanya mengganti tag tujuan mirror.

| Gejala | Yang diperiksa |
| --- | --- |
| Project/namespace tidak muncul | Management context, CRD, workspace dan placement |
| ImagePullBackOff | Image di Harbor, izin akun, DNS/CA Harbor pada node, harbor-secret di namespace open-webui |
| PVC Pending | Nama/provisioner StorageClass, event CSI dan kapasitas; WaitForFirstConsumer bisa menunggu pod dijadwalkan |
| Startup lama | Log download embedding, egress Hugging Face, CA dan kapasitas cache |
| OOMKilled | Memori parsing/embedding, ukuran dokumen, limit dan kapasitas node |
| Alibaba 401 | Pasangan key/workspace/region/endpoint dan nilai tersimpan pada Connections |
| Cloudflare 502 | Kesehatan pod/Service, route origin, DNS dan akses connector lintas namespace |
| Jawaban tidak menemukan dokumen | Koleksi dilampirkan, indeks selesai, teks ekstraksi dan akses user |

Jangan menghapus namespace/PVC untuk memperbaiki key atau koneksi. PVC memuat user, riwayat, upload, indeks dan cache model. Detail backup serta batas single-instance tersedia di [README](../README.md).
