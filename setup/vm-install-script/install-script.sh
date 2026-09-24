#!/bin/bash

echo ".........----------------#################._.-.-INSTALL-.-._.#################----------------........."
PS1='\[\e[01;36m\]\u\[\e[01;37m\]@\[\e[01;33m\]\H\[\e[01;37m\]:\[\e[01;32m\]\w\[\e[01;37m\]\$\[\033[0;37m\] '
echo "PS1='\[\e[01;36m\]\u\[\e[01;37m\]@\[\e[01;33m\]\H\[\e[01;37m\]:\[\e[01;32m\]\w\[\e[01;37m\]\$\[\033[0;37m\] '" >> ~/.bashrc
sed -i '1s/^/force_color_prompt=yes\n/' ~/.bashrc
source ~/.bashrc

# Don't ask to restart services after apt update, just do it.
[ -f /etc/needrestart/needrestart.conf ] && sed -i 's/#\$nrconf{restart} = \x27i\x27/$nrconf{restart} = \x27a\x27/' /etc/needrestart/needrestart.conf

apt-get autoremove -y  #removes the packages that are no longer needed
apt-get update
systemctl daemon-reload

KUBE_LATEST=$(curl -L -s https://dl.k8s.io/release/stable.txt | awk 'BEGIN { FS="." } { printf "%s.%s", $1, $2 }')
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBE_LATEST}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_LATEST}/deb/ /" >> /etc/apt/sources.list.d/kubernetes.list

apt-get update
KUBE_VERSION=$(apt-cache madison kubeadm | head -1 | awk '{print $3}')
apt-get install -y docker.io vim build-essential jq python3-pip kubelet kubectl kubernetes-cni kubeadm containerd
pip3 install jc

### UUID of VM
### comment below line if this Script is not executed on Cloud based VMs
jc dmidecode | jq .[1].values.uuid -r

systemctl enable kubelet

echo ".........----------------#################._.-.-KUBERNETES-.-._.#################----------------........."
rm -f /root/.kube/config
kubeadm reset -f

mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl restart containerd

# uncomment below line if your host doesnt have minimum requirement of 2 CPU
# kubeadm init --pod-network-cidr '10.244.0.0/16' --service-cidr '10.96.0.0/16' --ignore-preflight-errors=NumCPU --skip-token-print
kubeadm init --pod-network-cidr '10.244.0.0/16' --service-cidr '10.96.0.0/16'  --skip-token-print

mkdir -p ~/.kube
cp -i /etc/kubernetes/admin.conf ~/.kube/config

#CNI is Calico not weave-net as it's shutdown in 2024
#kubectl rollout status daemonset weave-net -n kube-system --timeout=90s
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl -n kube-system rollout status ds/kube-calico-ds --timeout=180s || { echo "CNI failed to come up"; exit 1; }

#Use Flannel for CNI if Calico doesn't workout
#kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
#kubectl -n kube-system rollout status ds/kube-flannel-ds --timeout=180s || { echo "CNI failed to come up"; exit 1; }
sleep 5

echo "untaint controlplane node"
node=$(kubectl get nodes -o=jsonpath='{.items[0].metadata.name}')
for taint in $(kubectl get node $node -o jsonpath='{range .spec.taints[*]}{.key}{":"}{.effect}{"-"}{end}')
do
    kubectl taint node $node $taint
done
kubectl get nodes -o wide
#------
#Quick sanity check on containerd config
#Before re-running, verify the sed actually took effect:
#bash
#grep SystemdCgroup /etc/containerd/config.toml
#You want to see SystemdCgroup = true. If it's not there or still false, fix it manually and restart containerd before doing kubeadm reset again.
#----

echo ".........----------------#################._.-.-Docker-.-._.#################----------------........."

cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "storage-driver": "overlay2"
}
EOF
mkdir -p /etc/systemd/system/docker.service.d

systemctl daemon-reload
systemctl restart docker
systemctl enable docker


echo ".........----------------#################._.-.-Java (automatic latest version installation) and MAVEN-.-._.#################----------------........."
#!/bin/bash
set -e

# Query Adoptium's API for the latest GA feature release
LATEST_MAJOR=$(curl -s https://api.adoptium.net/v3/info/available_releases | grep -oP '"most_recent_feature_release":\s*\K\d+')

echo "Latest available JDK major version: $LATEST_MAJOR"

# Download and install that version fresh each time
curl -L "https://api.adoptium.net/v3/binary/latest/${LATEST_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse" \
  -o /tmp/jdk-latest.tar.gz

mkdir -p /opt/java
tar -xzf /tmp/jdk-latest.tar.gz -C /opt/java --strip-components=1

update-alternatives --install /usr/bin/java java /opt/java/bin/java 100
update-alternatives --set java /opt/java/bin/java
java -version
mvn -v

echo ".........----------------#################._.-.-JENKINS-.-._.#################----------------........."
wget -q -O - https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | gpg --dearmor -o /usr/share/keyrings/jenkins.gpg
echo 'deb [signed-by=/usr/share/keyrings/jenkins.gpg] http://pkg.jenkins.io/debian-stable binary/' > /etc/apt/sources.list.d/jenkins.list
apt update
apt install -y jenkins
systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins
usermod -a -G docker jenkins
echo "jenkins ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

echo ".........----------------#################._.-.-COMPLETED-.-._.#################----------------........."
