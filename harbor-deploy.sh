#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HARBOR_URL=${HARBOR_URL:-registry.bercalab.my.id}
HARBOR_PROJECT=${HARBOR_PROJECT:-chatbot}
IMAGE_TAG=${IMAGE_TAG:-v0.13.3}
SOURCE_IMAGE=${SOURCE_IMAGE:-ghcr.io/open-webui/open-webui:v0.13.3}
STORAGE_CLASS_NAME=${STORAGE_CLASS_NAME:-}
NAMESPACE_MODE=${NAMESPACE_MODE:-kommander}
SECRET_ENV_FILE=${SECRET_ENV_FILE:-$SCRIPT_DIR/secret.env}
PROJECT_FILE=${PROJECT_FILE:-$SCRIPT_DIR/project.example.yaml}
NAMESPACE=open-webui
PUSH=false
DEPLOY=false
CREATE_SECRET=false
RENDER=false
WORK_DIR=''

usage() {
    cat <<'EOF'
Usage: bash harbor-deploy.sh --all|--push|--deploy|--create-secret|--render
  --push          Pull official Open WebUI image and mirror it to Harbor
  --deploy        Prepare namespace, validate storage, apply secrets/manifests, wait
  --all           Mirror image, then deploy (no application build required)
  --create-secret Prepare namespace and Harbor pull Secret only
  --render        Print app YAML locally; requires STORAGE_CLASS_NAME
  --help          Show this help

Environment:
  HARBOR_URL / HARBOR_PROJECT   registry.bercalab.my.id / chatbot
  IMAGE_TAG / SOURCE_IMAGE     v0.13.3 / ghcr.io/open-webui/open-webui:v0.13.3
  HARBOR_USER / HARBOR_PASSWORD Required for --push / --create-secret
  STORAGE_CLASS_NAME           Existing filesystem PVC class; default detected on deploy
  NAMESPACE_MODE               kommander (default), existing, or namespace
  PROJECT_FILE                 Edited Kommander Project manifest
  SECRET_ENV_FILE              Open WebUI credential env file (default ./secret.env)

Run against the same management/workload context as DEWA for kommander mode.
For separate management/workload clusters, create the Project there first and
deploy to its target workload cluster with NAMESPACE_MODE=existing.
No cleanup, DEWA mutation, Flux reconciliation, or tunnel mutation is performed.
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
cleanup() { if [[ -n "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi; }
trap cleanup EXIT

[[ $# -gt 0 ]] || { usage; exit 0; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) PUSH=true; DEPLOY=true ;;
        --push) PUSH=true ;;
        --deploy) DEPLOY=true ;;
        --create-secret) CREATE_SECRET=true ;;
        --render) RENDER=true ;;
        --help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done
if [[ "$RENDER" == true && ( "$PUSH" == true || "$DEPLOY" == true || "$CREATE_SECRET" == true ) ]]; then
    die '--render must be used alone.'
fi
[[ "$HARBOR_URL" =~ ^[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || die 'HARBOR_URL must be a registry host[:port], without scheme/path.'
[[ "$HARBOR_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die 'Invalid HARBOR_PROJECT.'
[[ "$IMAGE_TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die 'Invalid IMAGE_TAG.'
[[ "$NAMESPACE_MODE" =~ ^(kommander|existing|namespace)$ ]] || die 'Invalid NAMESPACE_MODE.'
TARGET_IMAGE="$HARBOR_URL/$HARBOR_PROJECT/open-webui:$IMAGE_TAG"
WORK_DIR=$(mktemp -d)

registry_config() {
    [[ -n "${HARBOR_USER:-}" && -n "${HARBOR_PASSWORD:-}" ]] || die 'Set HARBOR_USER and HARBOR_PASSWORD.'
    mkdir -p "$WORK_DIR/docker"
    printf '%s' "$HARBOR_PASSWORD" | docker --config "$WORK_DIR/docker" login "$HARBOR_URL" \
        --username "$HARBOR_USER" --password-stdin >&2
}

ensure_namespace() {
    log "kubectl context: $(kubectl config current-context)"
    kubectl cluster-info >/dev/null
    case "$NAMESPACE_MODE" in
        kommander)
            [[ -f "$PROJECT_FILE" ]] || die "Project file not found: $PROJECT_FILE"
            kubectl get crd projects.workspaces.kommander.mesosphere.io >/dev/null
            kubectl apply -f "$PROJECT_FILE"
            # Kommander creates the namespace asynchronously.
            for ((attempt=0; attempt<24; attempt++)); do
                if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then return; fi
                sleep 5
            done
            die 'Project namespace not found after 120s. Check workspace, placement and cluster context.'
            ;;
        existing) kubectl get namespace "$NAMESPACE" >/dev/null ;;
        namespace) kubectl apply -f "$SCRIPT_DIR/namespace.yaml" ;;
    esac
}

resolve_storage() {
    if [[ -z "$STORAGE_CLASS_NAME" ]]; then
        local defaults
        defaults=$(kubectl get storageclass -o 'jsonpath={range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}')
        local -a classes
        read -r -a classes <<< "$defaults"
        [[ ${#classes[@]} -eq 1 ]] || die 'Set STORAGE_CLASS_NAME explicitly; cluster has zero or multiple default classes.'
        STORAGE_CLASS_NAME=${classes[0]}
    fi
    local provisioner
    provisioner=$(kubectl get storageclass "$STORAGE_CLASS_NAME" -o jsonpath='{.provisioner}')
    [[ -n "$provisioner" && "${provisioner,,}" != *bucket* ]] || die 'A filesystem/block PVC class is required; object bucket classes cannot store SQLite/Chroma.'
    local existing_class
    existing_class=$(kubectl -n "$NAMESPACE" get pvc open-webui-data --ignore-not-found -o jsonpath='{.spec.storageClassName}')
    if [[ -n "$existing_class" && "$existing_class" != "$STORAGE_CLASS_NAME" ]]; then
        die "Existing PVC uses $existing_class; changing StorageClass requires a planned data migration."
    fi
    log "StorageClass: $STORAGE_CLASS_NAME ($provisioner)"
}

render() {
    [[ "$STORAGE_CLASS_NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die 'Set STORAGE_CLASS_NAME to a valid StorageClass name.'
    mkdir -p "$WORK_DIR/app"
    cp "$SCRIPT_DIR"/{namespace,configmap,pvc,deployment,service}.yaml "$WORK_DIR/app/"
    cat > "$WORK_DIR/app/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: open-webui
resources:
  - namespace.yaml
  - configmap.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
images:
  - name: ghcr.io/open-webui/open-webui
    newName: $HARBOR_URL/$HARBOR_PROJECT/open-webui
    newTag: "$IMAGE_TAG"
patches:
  - target:
      kind: PersistentVolumeClaim
      name: open-webui-data
    patch: |-
      - op: add
        path: /spec/storageClassName
        value: "$STORAGE_CLASS_NAME"
EOF
    kubectl kustomize "$WORK_DIR/app"
}

create_pull_secret() {
    kubectl -n "$NAMESPACE" create secret generic harbor-secret \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=".dockerconfigjson=$WORK_DIR/docker/config.json" \
        --dry-run=client -o yaml | kubectl apply -f -
}

if [[ "$RENDER" == true ]]; then render; exit 0; fi
if [[ "$DEPLOY" == true ]]; then
    [[ -f "$SECRET_ENV_FILE" ]] || die "Create and fill $SECRET_ENV_FILE from secret.env.example first."
    if grep -q 'REPLACE_WITH_' "$SECRET_ENV_FILE"; then die 'Replace every credential placeholder before deployment.'; fi
    for required in OPENAI_API_KEY WEBUI_SECRET_KEY WEBUI_ADMIN_EMAIL WEBUI_ADMIN_PASSWORD; do
        grep -q "^${required}=.\+" "$SECRET_ENV_FILE" || die "Missing or empty $required in credential env file."
    done
fi
if [[ "$PUSH" == true || "$CREATE_SECRET" == true || ( "$DEPLOY" == true && -n "${HARBOR_USER:-}" && -n "${HARBOR_PASSWORD:-}" ) ]]; then
    registry_config
fi
if [[ "$PUSH" == true ]]; then
    docker --config "$WORK_DIR/docker" pull "$SOURCE_IMAGE"
    docker --config "$WORK_DIR/docker" tag "$SOURCE_IMAGE" "$TARGET_IMAGE"
    docker --config "$WORK_DIR/docker" push "$TARGET_IMAGE"
fi
if [[ "$DEPLOY" == true || "$CREATE_SECRET" == true ]]; then
    ensure_namespace
    if [[ -f "$WORK_DIR/docker/config.json" ]]; then
        create_pull_secret
    else
        kubectl -n "$NAMESPACE" get secret harbor-secret >/dev/null || die 'Create harbor-secret using --create-secret and Harbor credentials.'
    fi
fi
if [[ "$DEPLOY" == true ]]; then
    resolve_storage
    render > "$WORK_DIR/rendered.yaml"
    kubectl apply --dry-run=server -f "$WORK_DIR/rendered.yaml" >/dev/null
    kubectl -n "$NAMESPACE" create secret generic open-webui-secrets \
        --from-env-file="$SECRET_ENV_FILE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "$WORK_DIR/rendered.yaml"
    kubectl -n "$NAMESPACE" rollout restart deployment/open-webui
    kubectl -n "$NAMESPACE" rollout status deployment/open-webui --timeout=1800s
    kubectl -n "$NAMESPACE" get pods,pvc,svc
    log 'Ready. Test using: kubectl -n open-webui port-forward service/open-webui 3001:80'
fi
