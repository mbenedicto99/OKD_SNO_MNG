#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OKD SNO em EC2 bare-metal (nested KVM/libvirt)
# RECOMENDAÇÕES (AWS):
# - Use instância bare-metal (p.ex. c7i.metal-24xl ou m7i.metal-24xl).
# - SG (Security Group): abrir 22/tcp (SSH), 6443/tcp (API K8s),
#   80/tcp e 443/tcp (Ingress). Restrinja origens (se possível, seu IP).
# - Crie um Elastic IP e associe à EC2.
# - DNS: aponte api.<cluster>.<dominio> e *.apps.<cluster>.<dominio>
#   para o IP público da EC2 (Route53). :contentReference[oaicite:1]{index=1}
# ============================================================

# -------- Versão/tag OKD (ajuste para o último "Accepted" 4.20) --------
OKD_VERSION="${OKD_VERSION:-4.20.0-okd-scos.ec.15}"

# -------- Identidade do cluster --------
CLUSTER_NAME="${CLUSTER_NAME:-lab}"
BASE_DOMAIN="${BASE_DOMAIN:-okd.aws.local}"      # use seu domínio (ideal: Route53)

# -------- Rede da VM libvirt (NAT padrão 192.168.122.0/24) --------
MACHINE_CIDR="${MACHINE_CIDR:-192.168.122.0/24}"

# -------- Recursos da VM OKD SNO --------
VM_NAME="${VM_NAME:-okd-sno-420}"
VM_VCPUS="${VM_VCPUS:-8}"
VM_RAM_MB="${VM_RAM_MB:-32768}"                  # 32 GB
VM_DISK_GB="${VM_DISK_GB:-160}"
VM_NET="${VM_NET:-default}"

# Disco destino dentro da VM (virtio = /dev/vda; NVMe seria /dev/nvme0n1)
INSTALL_DISK_PATH="${INSTALL_DISK_PATH:-/dev/vda}"

# -------- Caminhos de trabalho --------
WORKDIR="${WORKDIR:-$PWD/okd-sno}"
BIN_DIR="$WORKDIR/bin"
ASSETS_DIR="$WORKDIR/sno"
ISO_LIVE="$WORKDIR/fcos-live.iso"
ISO_CUSTOM="$WORKDIR/okd-sno-live.iso"

# -------- Chave SSH e pull secret --------
SSH_PUB_KEY_PATH="${SSH_PUB_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
PULL_SECRET="${PULL_SECRET:-{\"auths\":{\"fake\":{\"auth\":\"aWQ6cGFzcwo=\"}}}}"  # ok para lab rápido. :contentReference[oaicite:2]{index=2}

# -------- Portas a encaminhar da EC2 -> VM (API/Ingress) --------
FWD_PORTS="${FWD_PORTS:-6443,80,443}"

# ============================================================
# Pré-cheques EC2/AWS
# ============================================================
echo "[+] Verificando se a instância é bare-metal..."
INSTANCE_TYPE="$(curl -fsS http://169.254.169.254/latest/meta-data/instance-type || true)"
if [[ -z "${INSTANCE_TYPE}" ]]; then
  echo "ERRO: não consegui ler o instance-type do metadata EC2."; exit 1
fi
echo "    instance-type: ${INSTANCE_TYPE}"
if [[ "${INSTANCE_TYPE}" != *".metal"* && "${INSTANCE_TYPE}" != *"metal-"* ]]; then
  echo "ERRO: ${INSTANCE_TYPE} não é bare-metal. Nested KVM não é suportado oficialmente fora de instâncias metal. Abortando."; exit 1
fi
# Checa flags de virtualização no CPU
if ! egrep -q '(vmx|svm)' /proc/cpuinfo; then
  echo "ERRO: CPU sem VT-x/AMD-V exposto. Abortando."; exit 1
fi

# Interface de saída da EC2 (para DNAT)
EC2_IFACE="$(ip route get 1.1.1.1 | awk '{print $5; exit}')"
EC2_PUBIP="$(curl -fsS http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
EC2_PRIVIP="$(curl -fsS http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
echo "    iface externa: ${EC2_IFACE} | public-ip: ${EC2_PUBIP} | private-ip: ${EC2_PRIVIP}"

# ============================================================
# Dependências do host
# ============================================================
echo "[+] Instalando dependências..."
sudo apt-get update -y
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
                        curl tar jq unzip podman iptables-persistent

sudo systemctl enable --now libvirtd

mkdir -p "$BIN_DIR" "$ASSETS_DIR"
cd "$WORKDIR"

# ============================================================
# Baixa oc/kubectl + openshift-install (OKD 4.20)
# ============================================================
echo "[+] Baixando client tools (oc/kubectl) ${OKD_VERSION}..."
curl -L "https://github.com/okd-project/okd/releases/download/${OKD_VERSION}/openshift-client-linux-${OKD_VERSION}.tar.gz" -o oc.tgz
tar -C "$BIN_DIR" -zxf oc.tgz oc kubectl && chmod +x "$BIN_DIR/oc" "$BIN_DIR/kubectl"

echo "[+] Baixando openshift-install ${OKD_VERSION}..."
curl -L "https://github.com/okd-project/okd/releases/download/${OKD_VERSION}/openshift-install-linux-${OKD_VERSION}.tar.gz" -o installer.tgz
tar -C "$BIN_DIR" -zxf installer.tgz openshift-install && chmod +x "$BIN_DIR/openshift-install"
export PATH="$BIN_DIR:$PATH"

# ============================================================
# Baixa live ISO correta via print-stream-json (SCOS/FCOS)
# ============================================================
echo "[+] Descobrindo URL da live ISO via 'openshift-install coreos print-stream-json'..."
ARCH="x86_64"
ISO_URL=$(openshift-install coreos print-stream-json | grep location | grep "${ARCH}" | grep iso | cut -d\" -f4)
echo "    ISO_URL=${ISO_URL}"
curl -L "${ISO_URL}" -o "${ISO_LIVE}"

# ============================================================
# Gera install-config.yaml (SNO + bootstrapInPlace)
# ============================================================
echo "[+] Gerando install-config.yaml para SNO (${CLUSTER_NAME}.${BASE_DOMAIN})..."
[[ -f "$SSH_PUB_KEY_PATH" ]] || { echo "ERRO: chave SSH pública não encontrada em $SSH_PUB_KEY_PATH"; exit 1; }

cat > "$WORKDIR/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 1
metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${MACHINE_CIDR}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
bootstrapInPlace:
  installationDisk: ${INSTALL_DISK_PATH}
pullSecret: '${PULL_SECRET}'
sshKey: |
  $(cat "$SSH_PUB_KEY_PATH")
EOF

# ============================================================
# Cria assets/ignition do SNO
# ============================================================
echo "[+] Criando assets SNO e Ignition (bootstrap-in-place)..."
mkdir -p "$ASSETS_DIR"
cp "$WORKDIR/install-config.yaml" "$ASSETS_DIR/"
openshift-install --dir="$ASSETS_DIR" create single-node-ignition-config

# ============================================================
# Embute a Ignition na ISO (coreos-installer em container)
# ============================================================
echo "[+] Embutindo Ignition na live ISO..."
alias coreos-installer='podman run --privileged --pull always --rm \
  -v /dev:/dev -v /run/udev:/run/udev -v "$WORKDIR":/data -w /data \
  quay.io/coreos/coreos-installer:release'

coreos-installer iso ignition embed \
  -fi "$ASSETS_DIR/bootstrap-in-place-for-live-iso.ign" \
  "$ISO_LIVE"

cp "$ISO_LIVE" "$ISO_CUSTOM"

# ============================================================
# Cria a VM KVM e inicia instalação
# ============================================================
echo "[+] Criando VM '${VM_NAME}'..."
if virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
  echo "    Removendo VM anterior..."
  virsh destroy "${VM_NAME}" || true
  virsh undefine "${VM_NAME}" --remove-all-storage || true
fi

virt-install \
  --name "${VM_NAME}" \
  --vcpus "${VM_VCPUS}" \
  --memory "${VM_RAM_MB}" \
  --disk size="${VM_DISK_GB}",bus=virtio \
  --cdrom "${ISO_CUSTOM}" \
  --network network="${VM_NET}",model=virtio \
  --os-variant generic \
  --graphics none \
  --noautoconsole

echo "[i] A VM vai instalar o OKD no disco ${INSTALL_DISK_PATH}."

# ============================================================
# Descobre IP da VM e cria DNAT (EC2 -> VM) p/ 6443,80,443
# ============================================================
echo "[+] Aguardando IP da VM no virbr0..."
VM_IP=""
for i in {1..60}; do
  VM_IP=$(virsh domifaddr "${VM_NAME}" | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true)
  [[ -n "$VM_IP" ]] && break || sleep 5
done
[[ -n "$VM_IP" ]] || { echo "ERRO: não consegui obter IP da VM."; exit 1; }
echo "    VM_IP: ${VM_IP}"

echo "[+] Habilitando IP forward e regras de NAT/forward..."
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-okd-sno.conf >/dev/null

# Garante MASQUERADE para rede libvirt (caso não exista)
if ! sudo iptables -t nat -C POSTROUTING -s 192.168.122.0/24 -j MASQUERADE 2>/dev/null; then
  sudo iptables -t nat -A POSTROUTING -s 192.168.122.0/24 -j MASQUERADE
fi

# Cria DNAT para cada porta desejada
IFS=',' read -ra PORTS <<< "$FWD_PORTS"
for P in "${PORTS[@]}"; do
  echo "    Encaminhando porta ${P} -> ${VM_IP}:${P}"
  sudo iptables -t nat -A PREROUTING -i "${EC2_IFACE}" -p tcp --dport "${P}" -j DNAT --to-destination "${VM_IP}:${P}"
  sudo iptables -A FORWARD -p tcp -d "${VM_IP}" --dport "${P}" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
done

# Persiste regras
sudo netfilter-persistent save || sudo sh -c 'iptables-save > /etc/iptables/rules.v4'

# ============================================================
# Acompanha instalação e imprime credenciais
# ============================================================
echo "[+] Aguardando 'install-complete' (leva tempo)..."
openshift-install --dir="$ASSETS_DIR" wait-for install-complete --log-level=info || true

echo
echo "================ RESULTADOS ================"
echo "KUBECONFIG: $ASSETS_DIR/auth/kubeconfig"
echo "Senha kubeadmin: $(cat "$ASSETS_DIR/auth/kubeadmin-password" 2>/dev/null || echo '<aguarde até concluir>')"
echo
echo "API   (via EC2 DNAT): https://${EC2_PUBIP:-<seu_IP>}:6443"
echo "Console Web         : https://${EC2_PUBIP:-<seu_IP>}"
echo "DNS recomendado     : api.${CLUSTER_NAME}.${BASE_DOMAIN}  -> ${EC2_PUBIP}"
echo "                      *.apps.${CLUSTER_NAME}.${BASE_DOMAIN} -> ${EC2_PUBIP}"
echo "==========================================="
