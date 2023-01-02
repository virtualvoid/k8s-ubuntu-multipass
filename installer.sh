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
                ;;
	--update-hosts)
		generate_hosts
		update_hosts_on_master
		update_hosts_on_worker 1
		update_hosts_on_worker 2
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
