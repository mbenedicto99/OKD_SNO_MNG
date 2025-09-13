#!/usr/bin/env bash
set -euo pipefail

# ======== PARAMS (edite/exporte antes de rodar) ========
OKD_VERSION="${OKD_VERSION:-4.20.0-okd-scos.ec.15}"  # tag "Accepted" do OKD 4.20
AWS_REGION="${AWS_REGION:-sa-east-1}"                # São Paulo
CLUSTER_NAME="${CLUSTER_NAME:-okd}"                  # nome do cluster
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"            # Hosted Zone pública no Route53
MODE="${default}"                              # default | compact
SSH_PUB_KEY_PATH="${SSH_PUB_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
PULL_SECRET="${PULL_SECRET:-{\"auths\":{\"fake\":{\"auth\":\"aWQ6cGFzcwo=\"}}}}"

# Tamanhos padrão (ajuste se quiser)
CP_TYPE="${CP_TYPE:-m5.xlarge}"   # control-plane
WK_TYPE="${WK_TYPE:-m5.large}"    # workers (ignorado no modo compact)

# ======== CHECAGENS RÁPIDAS ========
command -v aws >/dev/null || { echo "Instale/configure AWS CLI (aws configure)."; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "AWS credenciais inválidas."; exit 1; }
[[ -f "$SSH_PUB_KEY_PATH" ]] || { echo "Chave SSH pública não encontrada: $SSH_PUB_KEY_PATH"; exit 1; }

ZONE_CHECK="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_DOMAIN" --query 'HostedZones[0].Name' --output text || true)"
if [[ "$ZONE_CHECK" != "${BASE_DOMAIN}." ]]; then
  echo "ATENÇÃO: Hosted Zone '$BASE_DOMAIN' não encontrada no Route53. Crie antes de continuar."
  # Você pode continuar, mas o instalador pode falhar na etapa de DNS.
fi

# ======== PREP ========
WORKDIR="${WORKDIR:-$PWD/okd-aws}"
INSTALL_DIR="$WORKDIR/$CLUSTER_NAME"
BIN_DIR="$WORKDIR/bin"
mkdir -p "$BIN_DIR" "$INSTALL_DIR"
export PATH="$BIN_DIR:$PATH"

# ======== BAIXA oc / openshift-install (OKD) ========
if [[ ! -x "$BIN_DIR/oc" ]]; then
  curl -L "https://github.com/okd-project/okd/releases/download/${OKD_VERSION}/openshift-client-linux-${OKD_VERSION}.tar.gz" -o "$WORKDIR/oc.tgz"
  tar -C "$BIN_DIR" -zxf "$WORKDIR/oc.tgz" oc kubectl
  chmod +x "$BIN_DIR/oc" "$BIN_DIR/kubectl"
fi
if [[ ! -x "$BIN_DIR/openshift-install" ]]; then
  curl -L "https://github.com/okd-project/okd/releases/download/${OKD_VERSION}/openshift-install-linux-${OKD_VERSION}.tar.gz" -o "$WORKDIR/installer.tgz"
  tar -C "$BIN_DIR" -zxf "$WORKDIR/installer.tgz" openshift-install
  chmod +x "$BIN_DIR/openshift-install"
fi

# ======== GERA install-config.yaml conforme MODE ========
cat > "$INSTALL_DIR/install-config.yaml" <<YAML
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  aws:
    region: ${AWS_REGION}
pullSecret: '${PULL_SECRET}'
sshKey: |
  $(cat "$SSH_PUB_KEY_PATH")
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: ${CP_TYPE}
compute:
- name: worker
  replicas: 3
  platform:
    aws:
      type: ${WK_TYPE}
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 10.0.0.0/16
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
YAML

if [[ "$MODE" == "compact" ]]; then
  # 3 masters, 0 workers (reduz custo) – depois tornamos masters agendáveis
  yq -i '.compute[0].replicas = 0' "$INSTALL_DIR/install-config.yaml" || \
  sed -i 's/replicas: 3/replicas: 0/' "$INSTALL_DIR/install-config.yaml"
fi

echo "[i] install-config.yaml gerado em: $INSTALL_DIR/install-config.yaml"
echo "----"
cat "$INSTALL_DIR/install-config.yaml"
echo "----"

# ======== CRIA CLUSTER ========
"$BIN_DIR/openshift-install" create cluster --dir="$INSTALL_DIR" --log-level=info

echo
echo "================ RESULTADOS ================"
echo "KUBECONFIG: $INSTALL_DIR/auth/kubeconfig"
echo "Senha kubeadmin: $(cat "$INSTALL_DIR/auth/kubeadmin-password" 2>/dev/null || echo '<ver console>')"
API="$(yq '.clusters[0].cluster.server' "$INSTALL_DIR/auth/kubeconfig" 2>/dev/null || true)"
echo "API: ${API:-https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443}"
echo "Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "==========================================="

# ======== PÓS PASSO (compact) ========
if [[ "$MODE" == "compact" ]]; then
  export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
  echo "[i] Habilitando agendamento nos masters (compact)..."
  oc patch schedulers.config.openshift.io cluster --type merge -p '{"spec":{"mastersSchedulable": true}}' || true
  echo "[i] Aguarde uns minutos para o cluster estabilizar com cargas nos masters."
fi

echo "[i] Para destruir o cluster depois:  $BIN_DIR/openshift-install destroy cluster --dir=$INSTALL_DIR"
