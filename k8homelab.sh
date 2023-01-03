#!/bin/bash

########################################################
#                                                      #
# Automation of homelab K8S cluster installation       #
#                                                      #
########################################################

HOMELAB_SSHKEY=""
UBUNTU_IMAGE="22.04"
MASTER_NODE="k8master"
WORKER_NODE="k8worker"
USER_NAME="worker"
TIME_ZONE="Europe/Bratislava"
MULTIPASS_PASSPHR="foofraze"
HOSTS_FILE=""

COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_ORANGE='\033[0;33m'

#
# Installer methods
#
function is_running_as_root() {
        if [[ $(id -u) == 0 ]]; then
                echo -e "${COLOR_RED}This script needs to be ran with sudo,\n"
                echo -e "will now exit.${COLOR_RESET}"
                exit
        fi
}

function install_kvm() {
        echo -e "${COLOR_GREEN}- Installing KVM and dependencies...${COLOR_RESET}"
        sudo apt update
        sudo apt install -y qemu-kvm libvirt-daemon bridge-utils \
                virtinst libvirt-daemon-system virt-top libguestfs-tools \
                libosinfo-bin qemu-system jq
}

function install_vhost() {
        echo -e "${COLOR_GREEN}- Module vhost ...${COLOR_RESET}"
        sudo modprobe vhost_net
        sudo sed -i '/vhost_net/d' /etc/modules
        echo -e vhost_net | sudo tee -a /etc/modules
}

function install_multipass() {
        echo -e "${COLOR_GREEN}- Installing multipass...${COLOR_RESET}"
        sudo snap install multipass --edge
	wait_for_multipass
}

function wait_for_multipass() {
        while [ ! -S /var/snap/multipass/common/multipass_socket ];
        do
            echo -e "${COLOR_ORANGE}- Waiting for multipass to boot up ...${COLOR_RESET}"
            sleep 1
        done
}

function install_multipass_kvm_driver() {
        echo -e "${COLOR_GREEN}- KVM driver for multipass...${COLOR_RESET}"
        multipass stop --all
        sudo snap connect multipass:libvirt
        multipass set local.driver=libvirt
	sudo snap restart multipass.multipassd
	wait_for_multipass
	multipass start
}

function create_ssh_key() {
        echo -e "${COLOR_GREEN}- Generating ssh keys...${COLOR_RESET}"
	mkdir -p keys/
        rm -f keys/id_rsa*
        ssh-keygen -q -N "" -C "$(id -u -n)@$(hostname)" -f keys/id_rsa <<<$'\ny\n'
        HOMELAB_SSHKEY=$(cat keys/id_rsa.pub)
	chmod -R 700 keys/
}

function exec_on_node() {
        echo -e "${COLOR_GREEN}- Executing on $1: $2 ${COLOR_RESET}"
        multipass exec $1 -- sudo su - $USER_NAME -c "$2"
}

function create_node_master() {
        echo -e "${COLOR_GREEN}- Creating master node...${COLOR_RESET}"
        cat <<EOF > cloud-init-master.yaml
#cloud-config
hostname: $MASTER_NODE
timezone: $TIME_ZONE
users:
  - name: $USER_NAME
    ssh-authorized-keys:
      - $HOMELAB_SSHKEY
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: [sudo, netdev, libvirtd]
    shell: /bin/bash
    home: /home/$USER_NAME
    lock_passwd: true
    gecos: Ubuntu
package_update: true
package_upgrade: true
package_reboot_if_required: true
packages:
  - screen
  - socat
  - conntrack
  - ebtables
  - ipset
  - ipvsadm
  - apt-transport-https
  - ca-certificates
  - nfs-common
  - curl
  - software-properties-common
EOF

        echo -e "${COLOR_GREEN}- Launching $MASTER_NODE ...${COLOR_RESET}"
        multipass launch \
	 -n $MASTER_NODE \
	 -c 2 \
	 -m 4G \
	 -d 40G \
	 --cloud-init cloud-init-master.yaml \
	 $UBUNTU_IMAGE

	echo -e "${COLOR_GREEN}- Removing cloud-init temp file...${COLOR_RESET}"
	rm cloud-init-master.yaml
}

function create_node_worker() {
        echo -e "${COLOR_GREEN}- Creating worker node ${1} ... ${COLOR_RESET}"
        cat <<EOF > cloud-init-worker$1.yaml
#cloud-config
hostname: $WORKER_NODE$1
timezone: $TIME_ZONE
users:
  - name: $USER_NAME
    ssh-authorized-keys:
      - $HOMELAB_SSHKEY
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: [sudo, netdev, libvirtd]
    shell: /bin/bash
    home: /home/$USER_NAME
    lock_passwd: true
    gecos: Ubuntu
package_update: true
package_upgrade: true
package_reboot_if_required: true
packages:
  - screen
  - socat
  - conntrack
  - ebtables
  - ipset
  - ipvsadm
  - apt-transport-https
  - ca-certificates
  - nfs-common
  - curl
  - software-properties-common
EOF

        echo -e "${COLOR_GREEN}- Launching $WORKER_NODE$1 ...${COLOR_RESET}"
        multipass launch \
         -n $WORKER_NODE$1 \
         -c 2 \
         -m 4G \
         -d 40G \
         --cloud-init cloud-init-worker$1.yaml \
         $UBUNTU_IMAGE

        echo -e "${COLOR_GREEN}- Removing cloud-init temp file...${COLOR_RESET}"
        rm cloud-init-worker$1.yaml
}

function generate_hosts() {
	echo -e "${COLOR_GREEN}- Generating hosts entries ...${COLOR_RESET}"
	HOSTS_FILE=$(multipass list --format=json | jq -r '.list[] | {"address": .ipv4[0], "name": .name} | join(" ")')
}

function update_hosts_on_node() {
         echo -e "${COLOR_GREEN}- Updating hosts on $1 ...${COLOR_RESET}"
         exec_on_node $1 "echo '${HOSTS_FILE}' | sudo tee -a /etc/hosts"
}

function update_hosts_on_master() {
	echo -e "${COLOR_GREEN}- Updating hosts on ${MASTER_NODE} ...${COLOR_RESET}"
	update_hosts_on_node $MASTER_NODE
}

function update_hosts_on_worker() {
	echo -e "${COLOR_GREEN}- Updating hosts on ${WORKER_NODE}${1} ...${COLOR_RESET}"
	update_hosts_on_node $WORKER_NODE$1
}

function install_dependencies_on_master() {
	install_dependencies_on_node $MASTER_NODE
}

function install_dependencies_on_worker() {
	install_dependencies_on_node $WORKER_NODE$1
}

function setup_master() {
	echo -e "${COLOR_GREEN}- Setting up the master ${MASTER_NODE} node...${COLOR_RESET}"
	exec_on_node $MASTER_NODE "sudo kubeadm init --control-plane-endpoint=${MASTER_NODE}"
	exec_on_node $MASTER_NODE "mkdir -p ~/.kube"
	exec_on_node $MASTER_NODE "sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config"
	exec_on_node $MASTER_NODE "sudo chown ${USER_NAME}:${USER_NAME} ~/.kube/config"
}

function copy_kubeconfig_from_master() {
	echo -e "${COLOR_GREEN}- Copy the .kube/config file...${COLOR_RESET}"
	exec_on_node $MASTER_NODE "cp ~/.kube/config /home/ubuntu/kubeconfig"
	mkdir -p ~/.kube
	multipass transfer $MASTER_NODE:/home/ubuntu/kubeconfig ~/.kube/config

	install_kubectl_locally
}

function install_kubectl_locally() {
	echo -e "${COLOR_GREEN}- Installing kubectl locally...${COLOR_RESET}"
	curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
	sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
}

function get_worker_join_command() {
	echo -e "${COLOR_GREEN}- Trying to obtain kube join command...${COLOR_RESET}"

#sha ca hash
#openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
#    | openssl rsa -pubin -outform der 2>/dev/null \
#    | openssl dgst -sha256 -hex \
#    | sed 's/^.* //'
}

function setup_worker() {
	echo -e "${COLOR_GREEN}- Setting up the worker ${WORKER_NODE}${1} node...${COLOR_RESET}"
}

function install_dependencies_on_node() {
	# Preliminary settings
	echo -e "${COLOR_GREEN}- Working on some settings...${COLOR_RESET}"
	exec_on_node $1 "sudo swapoff -a"
	exec_on_node $1 "sudo sed -e '/swap.img/ s/^/#/' /etc/fstab"

	exec_on_node $1 "echo -e \"overlay\nbr_netfilter\n\" | sudo tee /etc/modules-load.d/containerd.conf"
	exec_on_node $1 "sudo modprobe overlay"
	exec_on_node $1 "sudo modprobe br_netfilter"
	LN1="net.bridge.bridge-nf-call-ip6tables = 1"
	LN2="net.bridge.bridge-nf-call-iptables = 1"
	LN3="net.ipv4.ip_forward = 1"
	exec_on_node $1 "echo -e \"${LN1}\n${LN2}\n${LN3}\" | sudo tee /etc/sysctl.d/kubernetes.conf"
	exec_on_node $1 "sudo sysctl --system"

	# Dependencies itself
	echo -e "${COLOR_GREEN}- Installing dependencies on ${1}...${COLOR_RESET}"

	# Basic software
	exec_on_node $1 "sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates"

	# containerd
	exec_on_node $1 "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --no-tty --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg"
	exec_on_node $1 "sudo add-apt-repository --yes \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\""
	exec_on_node $1 "sudo apt update && sudo apt install -y containerd.io"

	exec_on_node $1 "containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1"
	exec_on_node $1 "sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml"
	exec_on_node $1 "sudo systemctl restart containerd"
	exec_on_node $1 "sudo systemctl enable containerd"

	# Kubernetes
	exec_on_node $1 "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -"
	exec_on_node $1 "sudo apt-add-repository --yes \"deb http://apt.kubernetes.io/ kubernetes-xenial main\""
	exec_on_node $1 "sudo apt update && sudo apt install -y kubelet kubeadm kubectl"
}

function cleanup_all() {
	echo -e "${COLOR_ORANGE}- Cleanup, this might take a while...${COLOR_RESET}"
	multipass stop --all
	multipass delete --all
	rm -rf keys/
	sudo snap remove multipass --purge
	sudo apt autoremove -y
}

#
# Main
#
function splash() {
        sudo snap install figlet
	clear
        figlet "HomeLab K8"
}

splash

case $1 in
        --install)
                is_running_as_root
		install_kvm
		install_vhost
		install_multipass
		install_multipass_kvm_driver
                create_ssh_key
                create_node_master
                create_node_worker 1
                create_node_worker 2
		generate_hosts
		update_hosts_on_master
		update_hosts_on_worker 1
		update_hosts_on_worker 2
		install_dependencies_on_master
		install_dependencies_on_worker 1
		install_dependencies_on_worker 2
		setup_master
		copy_kubeconfig_from_master
		get_worker_join_command
		setup_worker 1
		setup_worker 2
                ;;
	--update-hosts)
		generate_hosts
		update_hosts_on_master
		update_hosts_on_worker 1
		update_hosts_on_worker 2
		;;
	--node-dependencies)
		install_dependencies_on_master
		install_dependencies_on_worker 1
		install_dependencies_on_worker 2
		;;
	--node-setup)
		setup_master
		copy_kubeconfig_from_master
		get_worker_join_command
		setup_worker 1
		setup_worker 2
		;;
        --cleanup)
                is_running_as_root
                cleanup_all
                ;;
        *)
		echo ""
                echo "Use either --install or --cleanup"
		echo ""
                ;;
esac

echo -e "${COLOR_ORANGE}Done...${COLOR_RESET}\n\n"


