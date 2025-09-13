## Notas de arquitetura (AWS — instância, rede e segurança)

# Tipo de instância (host EC2)

Use bare-metal para KVM/nested: p.ex. c7i.metal-24xl (compute otimizado) ou m7i.metal-24xl (general purpose). São os tamanhos bare-metal da 7ª geração (Intel) e suportam VT-x/AMD-V, pré-requisito para KVM dentro da EC2.

Por que “metal”? Nested virtualization não é suportada oficialmente em instâncias não-metal. 

Tamanho da VM SNO (dentro da EC2): 8 vCPU, 16–32 GB RAM, ≥120 GB disco costuma ser suficiente para testes. A instalação SNO oficial (bootstrap-in-place) é a base deste script. 

# Rede

O libvirt cria virbr0 (NAT 192.168.122.0/24). O script faz DNAT de 6443/80/443 da EC2 para o IP da VM (via iptables). Exemplos semelhantes de forward para KVM NAT são consolidados em referências clássicas.

Ingress no SNO usa estratégia que toma 80/443 no host do nó (HostNetwork). Encaminhar 80/443 da EC2 para a VM garante acesso ao Router/Console. 
Documentação Red Hat

DNS (Route53): crie A para api.${CLUSTER}.${DOM} e wildcard *.apps.${CLUSTER}.${DOM} apontando para o Elastic IP da EC2; são os requisitos UPI obrigatórios.

# Segurança (SG/NACL)

Inbound no Security Group:

22/tcp (SSH host EC2),

6443/tcp (API Kubernetes),

80/tcp e 443/tcp (Ingress/console).

Restringir origem por IP (evite 0.0.0.0/0 em produção).

Outbound: 0.0.0.0/0 tcp/udp padrão (para pulls de imagens, updates etc.).

Na EC2 (Ubuntu), o script ativa net.ipv4.ip_forward e cria DNAT + FORWARD para as portas; isso é prática comum em KVM/libvirt com NAT. 
