# AWS CLI v2
curl -Ls https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install

# Ferramentas OpenShift
cd ~/Downloads
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-install-linux.tar.gz
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
tar -xzf openshift-install-linux.tar.gz
tar -xzf openshift-client-linux.tar.gz
sudo mv openshift-install oc kubectl /usr/local/bin/
