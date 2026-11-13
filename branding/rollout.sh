#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DEWA_IMAGE=${DEWA_IMAGE:-registry.bercalab.my.id/chatbot/open-webui:v0.13.3-dewa1}
NAMESPACE=open-webui
BACKUP_ROOT=${BACKUP_ROOT:-$ROOT/backups}
umask 077
BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/branding-$(date +%Y%m%d-%H%M%S).XXXXXX" 2>/dev/null) || {
    mkdir -p "$BACKUP_ROOT"
    BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/branding-$(date +%Y%m%d-%H%M%S).XXXXXX")
}
HELPER="dewa-backup-$(date +%s)-$$"
RESTORE=false
SUCCESS=false
OLD_IMAGE=''
OLD_REPLICAS=1

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$RESTORE" == true ]]; then
        # The backup helper must release the PVC before the app starts again.
        if ! kubectl -n "$NAMESPACE" delete pod "$HELPER" --ignore-not-found --wait=true --timeout=300s; then
            echo "Could not remove backup helper. App remains stopped; inspect pod $HELPER before restoring." >&2
            exit 1
        fi
        if [[ "$SUCCESS" != true ]]; then
            echo "Restoring original image and replica count after failure. Backup: $BACKUP_DIR" >&2
            kubectl -n "$NAMESPACE" set image deployment/open-webui "open-webui=$OLD_IMAGE" || true
            kubectl -n "$NAMESPACE" scale deployment/open-webui --replicas="$OLD_REPLICAS" || true
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

echo "Context: $(kubectl config current-context)"
echo 'Finish any document Processing jobs before running this rollout.'
kubectl -n "$NAMESPACE" get deployment open-webui -o json > "$BACKUP_DIR/deployment.json"
kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=open-webui -o json > "$BACKUP_DIR/pods.json"
python3 - "$BACKUP_DIR" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
deployment = json.loads((root / 'deployment.json').read_text())
spec = deployment['spec']
assert spec.get('replicas', 1) == 1, 'Expected exactly one app replica.'
assert spec['strategy']['type'] == 'Recreate', 'Expected Recreate strategy.'
pod_spec = spec['template']['spec']
containers = [c for c in pod_spec['containers'] if c['name'] == 'open-webui']
assert len(containers) == 1, 'Missing open-webui container.'
assert any(v.get('persistentVolumeClaim', {}).get('claimName') == 'open-webui-data'
           for v in pod_spec['volumes']), 'Expected existing PVC open-webui-data.'
assert any(m['mountPath'] == '/app/backend/data' for m in containers[0]['volumeMounts']), 'Unexpected data mount.'
pods = json.loads((root / 'pods.json').read_text())['items']
pods = [p for p in pods if not p['metadata'].get('deletionTimestamp')
        and p['status'].get('phase') == 'Running'
        and any(c['name'] == 'open-webui' and c.get('ready')
                for c in p['status'].get('containerStatuses', []))]
assert len(pods) == 1, 'Expected one Ready app pod before backup.'
node = pods[0]['spec']['nodeName']
(root / 'old-image.txt').write_text(containers[0]['image'])
helper = {
    'apiVersion': 'v1', 'kind': 'Pod',
    'metadata': {'name': 'PLACEHOLDER', 'namespace': 'open-webui'},
    'spec': {
        'nodeSelector': {'kubernetes.io/hostname': node},
        'restartPolicy': 'Never', 'automountServiceAccountToken': False,
        'imagePullSecrets': pod_spec.get('imagePullSecrets', []),
        'containers': [{
            'name': 'backup', 'image': containers[0]['image'], 'imagePullPolicy': 'IfNotPresent',
            'command': ['python', '-c', 'import time; time.sleep(3600)'],
            'resources': {'requests': {'cpu': '50m', 'memory': '64Mi'},
                          'limits': {'cpu': '500m', 'memory': '512Mi'}},
            'volumeMounts': [{'name': 'data', 'mountPath': '/data', 'readOnly': True}],
        }],
        'volumes': [{'name': 'data', 'persistentVolumeClaim':
                     {'claimName': 'open-webui-data', 'readOnly': True}}],
    },
}
if 'securityContext' in pod_spec:
    helper['spec']['securityContext'] = pod_spec['securityContext']
if 'securityContext' in containers[0]:
    helper['spec']['containers'][0]['securityContext'] = containers[0]['securityContext']
(root / 'backup-pod.json').write_text(json.dumps(helper))
PY
OLD_IMAGE=$(cat "$BACKUP_DIR/old-image.txt")
kubectl -n "$NAMESPACE" get configmap open-webui-config -o yaml > "$BACKUP_DIR/configmap.yaml"
kubectl -n "$NAMESPACE" get secret open-webui-secrets -o yaml > "$BACKUP_DIR/app-secret.yaml"
kubectl -n "$NAMESPACE" get secret harbor-secret -o yaml > "$BACKUP_DIR/harbor-secret.yaml"
kubectl -n "$NAMESPACE" get pvc open-webui-data -o yaml > "$BACKUP_DIR/pvc.yaml"
python3 - "$BACKUP_DIR/backup-pod.json" "$HELPER" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data['metadata']['name'] = sys.argv[2]
p.write_text(json.dumps(data))
PY

RESTORE=true
kubectl -n "$NAMESPACE" scale deployment/open-webui --replicas=0
kubectl -n "$NAMESPACE" wait --for=delete pod \
    -l app.kubernetes.io/name=open-webui --timeout=300s
kubectl -n "$NAMESPACE" create -f "$BACKUP_DIR/backup-pod.json"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$HELPER" --timeout=600s
kubectl -n "$NAMESPACE" exec "$HELPER" -- python -c \
    'import sys,tarfile; t=tarfile.open(fileobj=sys.stdout.buffer,mode="w|gz"); t.add("/data",arcname="data"); t.close()' \
    > "$BACKUP_DIR/data.tar.gz.partial"
python3 - "$BACKUP_DIR/data.tar.gz.partial" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    found = False
    for member in archive:
        if member.isfile():
            found = True
            with archive.extractfile(member) as stream:
                while stream.read(1024 * 1024):
                    pass
    assert found, 'Data backup is empty.'
PY
mv "$BACKUP_DIR/data.tar.gz.partial" "$BACKUP_DIR/data.tar.gz"
sha256sum "$BACKUP_DIR/data.tar.gz" > "$BACKUP_DIR/data.tar.gz.sha256"
kubectl -n "$NAMESPACE" delete pod "$HELPER" --wait=true --timeout=300s

kubectl -n "$NAMESPACE" set image deployment/open-webui "open-webui=$DEWA_IMAGE"
kubectl -n "$NAMESPACE" scale deployment/open-webui --replicas=1
kubectl -n "$NAMESPACE" rollout status deployment/open-webui --timeout=1800s
SUCCESS=true
RESTORE=false
echo "DEWA rollout finished. Backup (contains credentials): $BACKUP_DIR"
echo 'Verify login, existing chats, Knowledge, streaming and RAG through the public hostname.'
