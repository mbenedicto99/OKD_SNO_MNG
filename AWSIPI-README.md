# README-AWS.md — Instalação do OpenShift (OCP) na AWS via IPI (Ubuntu 24)

Este guia explica **passo a passo** como instalar o **Red Hat OpenShift (OCP)** na **AWS** usando o método **IPI (Installer-Provisioned Infrastructure)** a partir de uma máquina **Ubuntu 24.04**. O domínio usado no exemplo é **`canopusrobotics.com`** (pode ser adaptado para um subdomínio como `ocp.canopusrobotics.com`).

> **Para quem é:** você que é iniciante/leigo e quer um caminho **simples e direto**, mas com explicações suficientes para evitar armadilhas comuns.

---

## 📌 Escopo
- Plataforma: **AWS** (região-padrão dos exemplos: **sa-east-1 / São Paulo**)
- Método: **IPI** (o instalador cria toda a infraestrutura automaticamente: VPC, sub-redes, ELBs, IAM, Route 53, etc.)
- SO da máquina de trabalho: **Ubuntu 24.04 LTS**
- Domínio: **`canopusrobotics.com`** (ou um subdomínio delegado)
- Tamanho inicial do cluster (exemplo): **3 control-plane (m5.xlarge) + 3 workers (m5.large)**

> Se busca um ambiente bem econômico/temporário, ajuste tipos de instância e contagem de nós. Em produção, valide sizing, HA e SLAs.

---

## 🔎 IPI, UPI e ROSA (contexto rápido)
- **IPI (Installer-Provisioned Infrastructure)**: o **instalador do OpenShift** cria tudo na AWS. **Mais simples para começar**.
- **UPI (User-Provisioned Infrastructure)**: **você** cria e configura toda a infra; o instalador só faz o cluster. Flexível, porém **mais trabalhoso**.
- **ROSA (Red Hat OpenShift Service on AWS)**: serviço **gerenciado** por AWS/Red Hat. Provisiona clusters OpenShift como serviço (menos controle infra, mais conveniência).

---

## ✅ Pré-requisitos
1. **Conta AWS** com permissões para **EC2, VPC, ELB, IAM, Route 53, S3** e limites/quota suficientes (endereços IP, instâncias, etc.).
2. **Domínio público** gerenciado no **Route 53** (Hosted Zone) **ou** **subdomínio delegado** para a AWS.  
   - Ex.: usar `canopusrobotics.com` **ou** criar `ocp.canopusrobotics.com` como Hosted Zone separada e **delegar** via registro **NS** na zona-mãe.
3. **Pull Secret (JSON)** da Red Hat: obtenha em  
   **https://console.redhat.com/openshift/install/pull-secret**
4. Máquina **Ubuntu 24.04** com internet e privilégios sudo.
5. **Chave SSH** (ed25519) para acesso aos nós (opcional, mas recomendada).
6. **CLI AWS** configurada (`aws configure`) com **Access Key/Secret** de uma conta/usuário com permissões.
7. **Crie um usuário ocp/ocp** para instalação.
    
---

## 🧱 Arquitetura (O que o IPI cria na AWS)
- **VPC** dedicada com sub-redes públicas/privadas em múltiplas **AZs**.
- **Security Groups**, **IAM Roles/Policies** necessárias para os componentes.
- **ELBs** (para `api.<cluster>.<baseDomain>` e `*.apps.<cluster>.<baseDomain>`).
- **Registros DNS** na **Hosted Zone do Route 53**.
- **Instâncias EC2** para **3 control-plane** e **N workers** (por padrão 3).

> O IPI entrega um cluster altamente disponível (3 control-plane). Para laboratório, dá para reduzir custos com tipos menores (cuidado com performance).

---

## 💸 Nota sobre custos
- Os tipos **`m5.xlarge`** (masters) e **`m5.large`** (workers) são um **ponto de partida** confortável para labs.
- **Região `sa-east-1`** costuma ter preços mais altos que `us-east-1`. Ajuste a região se custo for prioridade.
- Use a **AWS Pricing Calculator** para uma estimativa segundo seu perfil (tipos, horas, storage, tráfego).

---

## 🧭 DNS (Route 53)
### Opção A — Domínio raiz no Route 53
Se `canopusrobotics.com` já é gerenciado no **Route 53** (Hosted Zone pública), o instalador adicionará os registros automaticamente.

### Opção B — Subdomínio delegado (recomendado para isolar)
1. Crie uma **Hosted Zone pública** para `ocp.canopusrobotics.com` no Route 53.
2. Copie os **NS** dessa Hosted Zone.
3. Na zona-mãe `canopusrobotics.com`, crie um **registro NS** apontando para os NS de `ocp.canopusrobotics.com`.
4. Use **`baseDomain: ocp.canopusrobotics.com`** no `install-config.yaml`.

> Delegar subdomínio evita misturar registros do cluster com o domínio raiz.

---

## 🛠️ Passo a Passo (Ubuntu 24)

### 1) Instale dependências e baixe os binários
```bash
sudo apt update && sudo apt install -y unzip tar curl jq awscli
mkdir -p ~/ocp/bin ~/ocp/install-aws && cd ~/ocp

# Baixar instalador e clientes (última estável)
curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-install-linux.tar.gz -o openshift-install-linux.tar.gz
curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz -o openshift-client-linux.tar.gz

tar -xzf openshift-install-linux.tar.gz -C ~/ocp/bin openshift-install
tar -xzf openshift-client-linux.tar.gz -C ~/ocp/bin oc kubectl || true
chmod +x ~/ocp/bin/openshift-install ~/ocp/bin/oc
export PATH=~/ocp/bin:$PATH
echo 'export PATH=~/ocp/bin:$PATH' >> ~/.bashrc
```

### 2) Configure a AWS CLI
```bash
aws configure   # informe Access Key, Secret, região (ex.: sa-east-1), saída json
aws sts get-caller-identity   # deve retornar conta/ARN
```

### 3) Obtenha o **Pull Secret**
- Acesse: **https://console.redhat.com/openshift/install/pull-secret**
- Copie o **JSON completo** e salve em: `~/ocp/install-aws/pull-secret.json`

```bash
mkdir -p ~/ocp/install-aws
nano ~/ocp/install-aws/pull-secret.json  # cole o conteúdo e salve
```

### 4) Crie (ou valide) sua **chave SSH**
```bash
ssh-keygen -t ed25519 -C "ocp-aws" -f ~/.ssh/ocp-aws -N ""
cat ~/.ssh/ocp-aws.pub   # copie a chave pública (usaremos no install-config)
```

### 5) Crie o `install-config.yaml`
Exemplo **usando `canopusrobotics.com`** e região **`sa-east-1`**:

```yaml
# ~/ocp/install-aws/install-config.yaml
apiVersion: v1
baseDomain: canopusrobotics.com
metadata:
  name: awsipi
platform:
  aws:
    region: sa-east-1
compute:
- name: worker
  replicas: 3
  platform:
    aws:
      type: m5.large
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.xlarge
pullSecret: '<COLE AQUI O CONTEÚDO JSON DO pull-secret.json>'
sshKey: 'ssh-ed25519 AAAA... (sua chave pública)'
```

> **Dicas:**  
> - Para isolar o DNS em subdomínio, mude `baseDomain` para `ocp.canopusrobotics.com`.  
> - Para reduzir custo, você **pode** trocar tipos de instância, mas valide recursos mínimos.  
> - Em produção, considere **STS/ccoctl** (papéis de curto prazo/least-privilege) e **cluster privado**.

### 6) Crie o cluster
```bash
cd ~/ocp/install-aws
~/ocp/bin/openshift-install create cluster --dir ~/ocp/install-aws --log-level=info
```

- O instalador criará toda a infraestrutura e, ao final, exibirá:
  - **URL da Console** (ex.: `https://console-openshift-console.apps.awsipi.canopusrobotics.com`)
  - **Usuário**: `kubeadmin`
  - **Senha**: `~/ocp/install-aws/auth/kubeadmin-password`

### 7) Valide o acesso com `oc`
```bash
export KUBECONFIG=~/ocp/install-aws/auth/kubeconfig
~/ocp/bin/oc whoami
~/ocp/bin/oc get nodes -o wide
```

Se retornar nós **Ready**, o cluster está operacional.

---

## 🧪 Testes rápidos (pós-instalação)
- Acesse a **Console Web** na URL informada no final do install.
- Faça login com **`kubeadmin`** e a senha em `auth/kubeadmin-password`.
- Implante um aplicativo de exemplo (ex.: `oc new-app --name hello --docker-image registry.access.redhat.com/ubi8/ubi` e exponha com `oc expose svc/hello`).

---

## 🧯 Troubleshooting (erros comuns)
- **Hosted Zone não encontrada / falha DNS**: confirme que a **Hosted Zone** do `baseDomain` existe no Route 53 **e** está delegada corretamente (se subdomínio).
- **Permissões IAM**: o usuário/role da AWS usado pelo instalador precisa criar **VPC, Subnets, ELBs, IAM Roles/Policies, Route 53, EC2** etc.
- **Quotas/limites**: verifique limites de instância por família/AZ, **EIP**, **NAT Gateway**, **NLB/ALB**, etc.
- **Falha no bootstrap**: verifique no S3/instância bootstrap e nos **logs do instalador** (`--log-level=debug`), segurança de rede (NACL/SG), e conectividade à **quay.io/registry** (o Pull Secret e saída para internet são essenciais).
- **Workers não entram**: confirme **Security Groups**, **sub-redes** e rotas; veja `oc get csr` (approve pendentes), e logs do **Machine Config Operator**.

---

## 🔥 Destruir o cluster (limpa a infra)
```bash
~/ocp/bin/openshift-install destroy cluster --dir ~/ocp/install-aws --log-level=info
```

> **Cuidado:** remove **toda** a infraestrutura da AWS criada pelo IPI.

---

## 🛡️ Boas práticas (após o lab inicial)
- Migrar para **STS com ccoctl** (credenciais de curto prazo/least-privilege).
- Considerar **cluster privado** (API/Ingress privados, acesso via bastion/VPN).
- **Backup/DR**: etcd backups, snapshots e planejamento de restauração.
- **Observabilidade**: instale/integre Prometheus/Grafana/Alertmanager, ou SaaS (Datadog/Dynatrace).
- **CICD/IaC**: versionar `install-config.yaml` (sem segredo!), usar Terraform para recursos satélites (VPC compartilhada, bastion, S3, etc.).
- **Segurança**: políticas OPA/Gatekeeper, Quotas/Limits, NetworkPolicies, TLS/Cert-Manager, escaneamento de imagens.

---

## ❓ FAQ
**Preciso mesmo de um domínio?**  
Sim. O OpenShift publica **API** e **apps** em **FQDNs** públicos/privados e valida certificados. O IPI cria os registros no **Route 53** do `baseDomain` informado.

**Posso usar um subdomínio?**  
Sim. Recomenda-se **delegar** `ocp.canopusrobotics.com` para isolar os registros do cluster.

**Dá para ser privado (sem endpoints públicos)?**  
Sim. Ajuste o `install-config.yaml`/parâmetros para cluster **privado**; acesso via bastion/VPN/NAT.

**Posso usar menos nós?**  
Para HA, **3 control-plane** é o padrão. Para laboratório extremo, existem opções como **SNO (Single Node OpenShift)**, mas é outro fluxo.

---

## 🧾 Anexo: Script “tudo em um” (opcional)
Você pode usar um script que automatiza todo o processo: dependências, download de binários, Pull Secret, SSH, `install-config.yaml` e criação do cluster.  
Arquivo sugerido: **`setup-ocp-aws-ipi.sh`** (consulte o conteúdo no seu histórico ou peça a versão atualizada).

---

## ✅ Checklist final
- [ ] Hosted Zone ativa no Route 53 para `canopusrobotics.com` **ou** subdomínio delegado.
- [ ] Pull Secret salvo em `~/ocp/install-aws/pull-secret.json`.
- [ ] `install-config.yaml` com `baseDomain`, `metadata.name`, `region`, `sshKey` e `pullSecret` corretos.
- [ ] `openshift-install create cluster` concluído sem erros.
- [ ] Console acessível e `oc get nodes` com **Ready**.

Boa instalação! 🚀
