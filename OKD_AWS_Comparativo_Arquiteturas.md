# Comparativo de Arquiteturas na AWS
**ROSA vs IPI vs UPI Manual (3 CP + 3 W)**  
> Objetivo: visualizar qual é o **ambiente menos complexo** para testes e integrações.

- **Menos complexo → Mais complexo:** **ROSA** (gerenciado) → **IPI** (automático) → **UPI Manual** (você provisiona tudo).
- **Observação importante:** **SNO** significa *Single Node OpenShift* (1 nó). O pedido “SNO instalado manualmente com 3 workers e 3 control-planes” **não é SNO**. Abaixo, apresentamos a arquitetura **UPI Manual (3 control planes + 3 workers)**, que corresponde ao cenário desejado (instalação manual com 3+3).

---

## 1) AWS ROSA (Red Hat OpenShift Service on AWS) — Gerenciado
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
      W1[(Worker Pool)]:::node
    end

    subgraph AZ2[AZ2]
      PUB2[Public Subnet]:::sub
      PRIV2[Private Subnet]:::sub
      M2[(Control Plane 2)]:::node
      W2[(Worker Pool)]:::node
    end

    subgraph AZ3[AZ3]
      PUB3[Public Subnet]:::sub
      PRIV3[Private Subnet]:::sub
      M3[(Control Plane 3)]:::node
      W3[(Worker Pool)]:::node
    end

    NLBAPI[NLB - API (6443)]:::lb
    ALBAPPS[ALB - *.apps (80/443)]:::lb
  end

  RH[Red Hat SRE<br/>(Gestão & Patching)]:::mgmt

  %% DNS → LBs
  R53 --> NLBAPI
  R53 --> ALBAPPS

  %% LBs → CP/Workers
  NLBAPI --> M1
  NLBAPI --> M2
  NLBAPI --> M3

  ALBAPPS --> W1
  ALBAPPS --> W2
  ALBAPPS --> W3

  %% Internet paths
  PUB1 --> IGW
  PUB2 --> IGW
  PUB3 --> IGW
  PRIV1 --> NAT
  PRIV2 --> NAT
  PRIV3 --> NAT

  %% Gestão (SRE) sobre o Control Plane
  RH -. observabilidade/patching .-> M1
  RH -. .-> M2
  RH -. .-> M3

  classDef dns fill:#eef,stroke:#88a,color:#000;
  classDef net fill:#efe,stroke:#6a6,color:#000;
  classDef sub fill:#f7f7f7,stroke:#bbb,color:#000;
  classDef node fill:#fff,stroke:#555,color:#000;
  classDef lb fill:#ffe,stroke:#aa6,color:#000;
  classDef mgmt fill:#e8f4ff,stroke:#69c,color:#000;
```

**Características resumidas**
- **Control plane**: gerenciado pela Red Hat (menos esforço operacional).
- **Infra AWS**: criada/operada em sua conta, mas com automações e SRE da Red Hat.
- **Complexidade**: **baixa** para o usuário (poucos passos, SLAs/patching gerenciados).

---

## 2) AWS IPI (Installer‑Provisioned Infrastructure) — Automático (OKD/OpenShift)
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

    BOOT[(Bootstrap<br/>(temporário))]:::boot
    NLBAPI[NLB - API (6443)]:::lb
    ALBAPPS[ALB/NLB - *.apps (80/443)]:::lb
  end

  %% DNS → LBs
  R53 --> NLBAPI
  R53 --> ALBAPPS

  %% LBs → nós
  NLBAPI --> M1
  NLBAPI --> M2
  NLBAPI --> M3

  ALBAPPS --> W1
  ALBAPPS --> W2
  ALBAPPS --> W3

  %% Bootstrap ajuda a formar o CP
  BOOT --> M1
  BOOT --> M2
  BOOT --> M3

  %% Internet paths
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

**Características resumidas**
- **Control plane**: você opera (patch/upgrade com `openshift-install`/`oc`).  
- **Infra AWS**: criada automaticamente pelo instalador (VPC, sub-redes, LB, IAM, DNS, EC2 etc.).  
- **Complexidade**: **média** (menos esforço que UPI, mais que ROSA).

---

## 3) UPI Manual (Instalação Manual — 3 Control Planes + 3 Workers)
```mermaid
flowchart LR
  YOU[Você/DevOps<br/>Terraform/CloudFormation]:::mgmt
  R53[Route53 Hosted Zone]:::dns

  subgraph AWS[VPC (10.0.0.0/16) — Você provisiona tudo]
    IGW[Internet Gateway]:::net
    NAT[NAT Gateway]:::net
    SG[Security Groups / IAM]:::svc
    S3[(S3 - Assets/Ignition)]:::svc

    subgraph AZ1[AZ1]
      PUB1[Public Subnet]:::sub
      PRIV1[Private Subnet]:::sub
      M1[(Control Plane 1)]:::node
      W1[(Worker 1)]:::node
      B1[(Bootstrap (temp))]:::boot
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

    NLBAPI[NLB - API (6443)]:::lb
    ALBAPPS[ALB/NLB - *.apps (80/443)]:::lb
  end

  %% Provisionamento manual
  YOU --> SG
  YOU --> NLBAPI
  YOU --> ALBAPPS
  YOU --> S3
  YOU --> R53

  %% DNS → LBs
  R53 --> NLBAPI
  R53 --> ALBAPPS

  %% LBs → nós
  NLBAPI --> M1
  NLBAPI --> M2
  NLBAPI --> M3

  ALBAPPS --> W1
  ALBAPPS --> W2
  ALBAPPS --> W3

  %% Bootstrap/ignitions
  S3 -. Ignition/manifests .-> B1
  B1 --> M1
  B1 --> M2
  B1 --> M3

  %% Internet paths
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
  classDef mgmt fill:#e8f4ff,stroke:#69c,color:#000;
  classDef svc fill:#eefcff,stroke:#69c,color:#000;
```

**Características resumidas**
- **Control plane**: você opera tudo (instalação, patches/upgrade, ciclo de vida).  
- **Infra AWS**: **100% provisionada por você** (VPC, sub-redes, roteamento, LB, IAM, DNS, EC2, S3, SGs…).  
- **Complexidade**: **alta** (maior controle e esforço).

---

## Comparativo rápido (complexidade e responsabilidade)

- **ROSA (gerenciado)**  
  - **Complexidade**: **Baixa**  
  - **Quem cuida do control plane**: Red Hat SRE  
  - **Infra**: criada no seu AWS, com automação/gestão da Red Hat  
  - **Quando usar**: menor time-to-value, SLO/SLA gerenciados, suporte oficial

- **IPI (automático)**  
  - **Complexidade**: **Média**  
  - **Quem cuida do control plane**: Você (com ferramentas do instalador)  
  - **Infra**: criada automaticamente pelo instalador  
  - **Quando usar**: PoC/padrão rápido, ainda com bastante controle

- **UPI Manual (3 CP + 3 W)**  
  - **Complexidade**: **Alta**  
  - **Quem cuida do control plane**: Você (total)  
  - **Infra**: você define e mantém tudo (IaC recomendado)  
  - **Quando usar**: ambientes restritos, VPC existente, requisitos especiais
