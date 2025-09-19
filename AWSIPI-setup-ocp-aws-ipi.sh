#!/usr/bin/env bash
# OpenShift IPI na AWS — Setup automatizado
# Autor: Marcos de Benedicto
# Data : 19/09/2025
# Executar:  bash AWSIPI-setup-ocp-aws-ipi.sh

set -euo pipefail

########################
# 0) Variáveis básicas #
########################
REGION="sa-east-1"                         # Região AWS (São Paulo)
BASE_DOMAIN="canopusrobotics.com"          # Seu domínio base
CLUSTER_NAME="ocp"                         # Nome do cluster (vira prefixo DNS)
MASTER_TYPE="m5.xlarge"                    # Instância dos control-planes
WORKER_TYPE="m5.large"                     # Instância dos workers
WORKERS=3                                  # Qtd de workers
MASTERS=3                                  # Qtd de control-planes (recomendado 3)
ROOT="${HOME}/ocp"                         # Pasta raiz
INSTALL_DIR="${ROOT}/install-aws"          # Pasta do artefato de instalação
BIN_DIR="${ROOT}/bin"                      # Onde ficarão os binários oc/openshift-install
SSH_KEY="${HOME}/.ssh/ocp-aws"             # Caminho base da SSH key

#################################
# 1) Dependências no Ubuntu 24  #
#################################
echo "[1/9] Instalando dependências..."
sudo apt update
sudo apt install -y unzip tar curl jq awscli

mkdir -p "${BIN_DIR}" "${INSTALL_DIR}"
cd "${ROOT}"

echo "[REQ01] Grave a chave e o secret AWS..."

###########################################################
# 2) Baixar 'openshift-install' e 'oc' (última estável)   #
###########################################################
echo "[2/9] Baixando clientes OpenShift..."
curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-install-linux.tar.gz" -o openshift-install-linux.tar.gz
curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" -o openshift-client-linux.tar.gz

tar -xzf openshift-install-linux.tar.gz -C "${BIN_DIR}" openshift-install
tar -xzf openshift-client-linux.tar.gz -C "${BIN_DIR}" oc kubectl || true
chmod +x "${BIN_DIR}/openshift-install" "${BIN_DIR}/oc" || true

# Coloca no PATH na sessão atual e sugere persistência no ~/.bashrc
export PATH="${BIN_DIR}:${PATH}"
if ! grep -q "${BIN_DIR}" "${HOME}/.bashrc"; then
  echo "export PATH=\"${BIN_DIR}:\$PATH\"" >> "${HOME}/.bashrc"
fi

#############################################
# 3) Credenciais AWS e região (aws configure)
#############################################
echo "[3/9] Verificando credenciais AWS..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo ">> Rode 'aws configure' e informe sua Access Key/Secret, região (${REGION}) e saída json."
  aws configure
fi
aws configure set region "${REGION}"

##########################################################
# 4) Pull Secret — abrir URL oficial e salvar o JSON     #
##########################################################
echo "[4/9] Pull Secret do OpenShift:"
echo ">> Abra a URL e copie seu Pull Secret (login Red Hat):"
echo "   https://console.redhat.com/openshift/install/pull-secret"
echo ">> Cole o conteúdo no arquivo: ${INSTALL_DIR}/pull-secret.json"
if [ ! -f "${INSTALL_DIR}/pull-secret.json" ]; then
  mkdir -p "${INSTALL_DIR}"
  ${EDITOR:-nano} "${INSTALL_DIR}/pull-secret.json" || true
fi
if [ ! -s "${INSTALL_DIR}/pull-secret.json" ]; then
  echo "ERRO: pull-secret.json está vazio. Edite e cole o JSON do Pull Secret."
  exit 1
fi

#############################################
# 5) SSH key para acessar os nós (se faltar)
#############################################
echo "[5/9] Gerando/verificando chave SSH..."
if [ ! -f "${SSH_KEY}" ]; then
  ssh-keygen -t ed25519 -C "ocp-aws" -f "${SSH_KEY}" -N ""
fi
SSH_PUB_KEY=$(cat "${SSH_KEY}.pub")

########################################
# 6) Gerar install-config.yaml completo
########################################
echo "[6/9] Gerando install-config.yaml..."
PULL_SECRET_MINIFIED=$(jq -c . < "${INSTALL_DIR}/pull-secret.json")

cat > "${INSTALL_DIR}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  aws:
    region: ${REGION}
compute:
- name: worker
  replicas: ${WORKERS}
  platform:
    aws:
      type: ${WORKER_TYPE}
controlPlane:
  name: master
  replicas: ${MASTERS}
  platform:
    aws:
      type: ${MASTER_TYPE}
pullSecret: '${PULL_SECRET_MINIFIED}'
sshKey: '${SSH_PUB_KEY}'
EOF

echo ">> install-config.yaml criado em: ${INSTALL_DIR}/install-config.yaml"
echo "----"
cat "${INSTALL_DIR}/install-config.yaml"
echo "----"

###############################################
# 7) (Opcional) Valida Hosted Zone no Route53 #
###############################################
echo "[7/9] Validando se a Hosted Zone existe no Route53 (apenas checagem)..."
HZ_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}" \
  | jq -r '.HostedZones[] | select(.Name=="'"${BASE_DOMAIN}"'.") | .Id' | sed 's|/hostedzone/||' || true)

if [ -z "${HZ_ID}" ]; then
  echo "ATENÇÃO: Não encontrei Hosted Zone pública para '${BASE_DOMAIN}' no Route 53."
  echo " - Se o domínio está em outro provedor, crie uma Hosted Zone pública no Route 53"
  echo "   e aponte os NS no seu registrador."
  echo " - Alternativamente, crie e delegue um subdomínio (ex.: ocp.${BASE_DOMAIN})."
  echo "Você pode continuar, mas a criação do cluster falhará sem DNS correto."
  read -p "Deseja continuar mesmo assim? (y/N) " cont || true
  [[ "${cont:-N}" =~ ^[Yy]$ ]] || exit 1
else
  echo "OK: Hosted Zone encontrada (${HZ_ID}) para ${BASE_DOMAIN}."
fi

########################################
# 8) Criar o cluster (pode demorar)
########################################
echo "[8/9] Criando cluster OpenShift IPI na AWS..."
( cd "${INSTALL_DIR}" && "${BIN_DIR}/openshift-install" create cluster --dir "${INSTALL_DIR}" --log-level=info )

########################################################
# 9) Acessar: export KUBECONFIG, testar e mostrar URLs #
########################################################
echo "[9/9] Validando acesso com 'oc'..."
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
"${BIN_DIR}/oc" whoami || true
"${BIN_DIR}/oc" get nodes -o wide || true

echo
echo "==================== SUCESSO ===================="
echo "Console Web e credenciais:"
echo " - kubeconfig: ${INSTALL_DIR}/auth/kubeconfig"
echo " - kubeadmin password: $(cat "${INSTALL_DIR}/auth/kubeadmin-password" 2>/dev/null || echo '(arquivo gerado após sucesso)')"
echo " - Console URL: será algo como https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "====================================================================="
echo
echo "Para destruir depois (cautela!):"
echo "  ${BIN_DIR}/openshift-install destroy cluster --dir ${INSTALL_DIR} --log-level=info"
