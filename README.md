# OKD 4.20 (SCOS) — Instalação IPI na AWS (Guia para Leigos)

Este guia explica, em linguagem simples, como usar o script **`okd-aws-ipi.sh`** para criar um cluster **OKD 4.20 (SCOS)** diretamente na **AWS** via **IPI (Installer‑Provisioned Infrastructure)**. No final há um **diagrama Mermaid** da arquitetura padrão IPI na AWS.

---

## O que o script faz
- Baixa os binários do OKD (**oc** e **openshift-install**).
- Gera o arquivo `install-config.yaml` para **AWS (sa-east-1)**.
- Cria o cluster (VPC, sub-redes, balanceadores, instâncias EC2, DNS no Route53 etc.).
- Mostra **KUBECONFIG**, **senha do kubeadmin** e **links** (API e Console).

> Dois modos de criação:
> - **default**: 3 masters + 3 workers (padrão para testes completos).
> - **compact**: 3 masters e **0 workers** (custo menor); o script torna os masters agendáveis.

---

## Pré‑requisitos (uma vez)
- **Conta AWS** com permissão em: EC2, IAM, VPC, ELB/NLB, Route53, S3.
- **Hosted Zone** no **Route53** do seu domínio (ex.: `example.com`).
- **AWS CLI** configurado: `aws configure` (Access Key, Secret, region).
- Chave **SSH pública** em `~/.ssh/id_rsa.pub` (ou aponte outra pelo ambiente).

Instale utilitários no Ubuntu 24.x:
```bash
sudo apt-get update
sudo apt-get install -y jq yq curl tar unzip
aws sts get-caller-identity   # deve retornar info da sua conta
```

---

## Como usar o script (passo a passo)
1. **Crie** o arquivo `okd-aws-ipi.sh` com o conteúdo que você recebeu anteriormente.
2. **Permissão de execução**:
   ```bash
   chmod +x okd-aws-ipi.sh
   ```
3. **Defina variáveis mínimas** (ajuste nome e domínio):
   ```bash
   export CLUSTER_NAME=okd
   export BASE_DOMAIN=seu-dominio.com.br      # precisa existir no Route53
   export AWS_REGION=sa-east-1
   export MODE=default                         # ou compact (mais barato)
   # (opcional) export OKD_VERSION="4.20.0-okd-scos.ec.15"
   # (opcional) export CP_TYPE="m5.xlarge"; export WK_TYPE="m5.large"
   # (lab)      export PULL_SECRET='{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'
   ```
4. **Execute**:
   ```bash
   ./okd-aws-ipi.sh
   ```

> **Tempo**: a criação pode levar vários minutos (a AWS vai subir toda a infraestrutura).

---

## Saída esperada
- Pasta de trabalho: `okd-aws/<CLUSTER_NAME>` com artefatos.
- No final, o script imprime algo como:
  - `KUBECONFIG: okd-aws/okd/auth/kubeconfig`
  - `Senha kubeadmin: XXXXX-XXXXX-...`
  - `API: https://api.okd.seu-dominio.com.br:6443`
  - `Console: https://console-openshift-console.apps.okd.seu-dominio.com.br`

---

## Acessando o cluster pela CLI
```bash
export KUBECONFIG=$PWD/okd-aws/okd/auth/kubeconfig
oc whoami
oc get nodes
oc get co        # ClusterOperators — aguarde ficarem Available
```

## Acessando o Console Web
- Abra: `https://console-openshift-console.apps.<CLUSTER>.<DOMÍNIO>`
- Usuário: `kubeadmin`
- Senha: (a que o script mostrou no final)

---

## Escolha do modo
- **MODE=default** → 3 masters + 3 workers (mais “completo” para testes de Operators/rotas/upgrade).
- **MODE=compact** → 3 masters, **0 workers** (reduz custo). O script já aplica:
  ```bash
  oc patch schedulers.config.openshift.io cluster --type merge -p '{"spec":{"mastersSchedulable": true}}'
  ```

---

## Dicas e pegadinhas
- **Hosted Zone**: o domínio `BASE_DOMAIN` precisa existir no Route53 antes de rodar.
- **Custos**: *default* cria ~6 VMs + balanceadores; *compact* cria ~3 VMs + balanceadores.
- **Permissões AWS**: se faltar permissão (IAM/ELB/Route53), a criação falha; ajuste e rode de novo com o mesmo `--dir`.
- **Pull secret**: para laboratório, pode usar o “fake”; para Operators da Red Hat, use um pull secret real.

---

## Como remover (evitar custos)
```bash
export INSTALL_DIR=$PWD/okd-aws/okd   # ajuste se mudou o nome
openshift-install destroy cluster --dir="$INSTALL_DIR"
```

---

## Arquitetura (Mermaid) — OKD IPI na AWS (padrão)

```mermaid
flowchart LR
  R53[Route53 Hosted Zone<br/>api / *.apps]:::dns

  subgraph AWS[VPC (10.0.0.0/16)]
    IGW[Internet Gateway]:::net
    NAT[NAT Gateway]:::net

    subgraph AZ1[AZ1]
      PUB1[Public Subnet]:::sub
      PRIV1[Private Subnet]:::sub
      M1[(Control Plane 1)]:::node
      W1[(Worker 1)]:::node
    end

    subgraph AZ2[AZ2]
      PUB2[Public Subnet]:::sub
      PRIV2[Private Subnet]:::sub
      M2[(Control Plane 2)]:::node
      W2[(Worker 2)]:::node
    end

    subgraph AZ3[AZ3]
      PUB3[Public Subnet]:::sub
      PRIV3[Private Subnet]:::sub
      M3[(Control Plane 3)]:::node
      W3[(Worker 3)]:::node
    end

    NLBAPI[NLB - api:6443]:::lb
    NLBAPPS[LB - *.apps:80/443]:::lb
    BOOT[(Bootstrap - temporário)]:::boot
  end

  %% DNS → LBs
  R53 --> NLBAPI
  R53 --> NLBAPPS

  %% LBs → nós
  NLBAPI --> M1
  NLBAPI --> M2
  NLBAPI --> M3

  NLBAPPS --> W1
  NLBAPPS --> W2
  NLBAPPS --> W3

  %% Bootstrap ajuda a formar o controle
  BOOT --> M1
  BOOT --> M2
  BOOT --> M3

  %% Rotas de internet
  PUB1 --> IGW
  PUB2 --> IGW
  PUB3 --> IGW

  PRIV1 --> NAT
  PRIV2 --> NAT
  PRIV3 --> NAT

  classDef dns fill:#eef,stroke:#88a,color:#000;
  classDef net fill:#efe,stroke:#6a6,color:#000;
  classDef sub fill:#f7f7f7,stroke:#bbb,color:#000;
  classDef node fill:#fff,stroke:#555,color:#000;
  classDef lb fill:#ffe,stroke:#aa6,color:#000;
  classDef boot fill:#fde,stroke:#d66,color:#000;
```

---

## Exemplos de `install-config.yaml` (opcional)

**Default (3 masters + 3 workers):**
```yaml
apiVersion: v1
baseDomain: exemplo.com
metadata:
  name: okd
platform:
  aws:
    region: sa-east-1
pullSecret: '<pull secret ou o fake de lab>'
sshKey: |
  <sua chave SSH pública>
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.xlarge
compute:
- name: worker
  replicas: 3
  platform:
    aws:
      type: m5.large
networking:
  networkType: OVNKubernetes
```

**Compact (3 masters, 0 workers):**
```yaml
compute:
- name: worker
  replicas: 0
```
Depois da instalação, permitir agendamento em masters:
```bash
oc patch schedulers.config.openshift.io cluster --type merge -p '{"spec":{"mastersSchedulable": true}}'
```

---

### Próximos passos (sugestões)
- Criar *projects* e *namespaces*, instalar Operators, criar *Routes* e *Deployments*.
- Configurar *User Workload Monitoring* e Storage para o Image Registry (PVC/NFS/ODF).
- Testar integrações (ex.: **Rundeck**) via API/CLI do cluster.

---

*Este documento é um guia prático para fins de laboratório/PoC.*
