#!/usr/bin/env bash

# Copyright 2014, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author Kevin.Carter@Rackspace.com

# Variables:
#   PASSWD=Set the password, if not set it will be generated.
#   CONTAINER_USER=The name of the user that will be built within the container.
#   COOKBOOK_VERSION=Version number of the cookbooks being used for deployment.
#   PRIMARY_DEVICE=The device name for the primary network interface. 
#                  This is the network device that will the default gateway.
#   NEUTRON_DEVICE=The device name that neutron will be attached to.
#   VIRT_TYPE=The Virtualization type, if your System supports KVM 
#             you should set this to "kvm". Default, "qemu"
#   MAX_RETRIES=The Max number of times to retry an operation before quiting.
#               The default is set to 5.

set -e -u -x -v

WHOAMI=$(whoami)
PASSWD=${PASSWD:-"secrete"}
CONTAINER_USER=${CONTAINER_USER:-"openstack"}
COOKBOOK_VERSION=${COOKBOOK_VERSION:-"v4.2.2"}
CHEF_CLIENT_URL=${CHEF_URL:-"https://www.opscode.com/chef/install.sh"}
CHEF_CLIENT_VERSION=${CHEF_VERSION:-"11.10.4-1"}
PRIMARY_DEVICE=${PRIMARY_DEVICE:-"eth0"}
NEUTRON_DEVICE=${NEUTRON_DEVICE:-"eth1"}
VIRT_TYPE=${VIRT_TYPE:-"qemu"}


# Used to retry process that may fail due to random issues.
function retry_process() {
  set +e
  MAX_RETRIES=${MAX_RETRIES:-5}
  RETRY=0

  # Set the initial return value to failure
  false

  while [ $? -ne 0 -a ${RETRY} -lt ${MAX_RETRIES} ];do
    RETRY=$((${RETRY}+1))
    $@
  done

  if [ ${RETRY} -eq ${MAX_RETRIES} ];then
    error_exit "Hit maximum number of retries, giving up..."
  fi
  set -e
}


if [ "$WHOAMI" != "root" ];then
  echo "Please escalate to root."
  exit 1
fi

echo "Changing root password to \"secrete\""
echo -e "${PASSWD}\n${PASSWD}" | (passwd ${WHOAMI})

if [ ! -f "/root/.ssh/id_rsa" ];then
  echo "Generating SSH Keys"
  ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ''
fi


if [ ! -f "/etc/rc.local" ];then
    touch /etc/rc.local
    chmod +x /etc/rc.local
else
    chmod +x /etc/rc.local
fi

if [ "$(grep 'exit 0' /etc/rc.local)" ];then
    sed -i '/exit\ 0/ s/^/#\ /' /etc/rc.local
fi


# Add the LXC Stable back ports repo
apt-get -y install python-software-properties
add-apt-repository -y ppa:ubuntu-lxc/stable

# Update
apt-get update

# Install LXC
apt-get -y install lxc python3-lxc lxc-templates liblxc1 \
                   git lvm2 git python-dev haproxy cpu-checker

echo "Setting up HAProxy"
cp $(pwd)/haproxy.cfg /etc/haproxy/haproxy.cfg

echo "starting HAProxy"
sed -i '/test\ "\$ENABLED".*/ s/^/#\ /' /etc/init.d/haproxy
/etc/init.d/haproxy restart

if [ ! -d "/opt" ];then
  mkdir /opt
fi


echo "Enabling Swap"
if [ ! "$(swapon -s | grep -v Filename)" ];then
  cat > /opt/swap.sh <<EOF
#!/usr/bin/env bash
if [ ! "\$(swapon -s | grep -v Filename)" ];then
SWAPFILE="/tmp/SwapFile"
if [ -f "\${SWAPFILE}" ];then
  swapoff -a
  rm \${SWAPFILE}
fi
dd if=/dev/zero of=\${SWAPFILE} bs=1M count=2048
mkswap \${SWAPFILE}
swapon \${SWAPFILE}
fi
EOF

  chmod +x /opt/swap.sh
  /opt/swap.sh
fi

sysctl vm.swappiness=60 | tee -a /etc/sysctl.conf

echo "Creating FAKE Cinder"
CINDER="/opt/cinder.img"
if [ ! "$(losetup -a | grep /opt/cinder.img)" ];then
  LOOP=$(losetup -f)
  dd if=/dev/zero of=${CINDER} bs=1 count=0 seek=1000G
  losetup ${LOOP} ${CINDER}
  pvcreate ${LOOP}
  vgcreate cinder-volumes ${LOOP}
  pvscan
fi
# Set Cinder Device as Persistent
cat > /opt/cinder.sh <<EOF
#!/usr/bin/env bash
CINDER="${CINDER}"
if [ ! "\$(losetup -a | grep \${CINDER})"  ];then
  LOOP=\$(losetup -f)
  CINDER="/opt/cinder.img"
  losetup \${LOOP} \${CINDER}
  pvscan
  # Restart Cinder once the volumes are online
  for srv in cinder-volume cinder-api cinder-scheduler;do
    service \${srv} restart
  done
fi
EOF

if [ -f "/opt/cinder.sh" ];then
    chmod +x /opt/cinder.sh
fi


# LXC Template
if [ -d "lxc_defiant" ];then
  rm -rf "lxc_defiant"
fi
git clone https://github.com/cloudnull/lxc_defiant lxc_defiant
cp lxc_defiant/lxc-defiant.py /usr/share/lxc/templates/lxc-defiant

cat > /usr/share/lxc/config/defiant.common.conf <<EOF
 Default pivot location
lxc.pivotdir = lxc_putold

# Default mount entries
lxc.mount.entry = proc proc proc nodev,noexec,nosuid 0 0
lxc.mount.entry = sysfs sys sysfs defaults 0 0
lxc.mount.entry = /sys/fs/fuse/connections sys/fs/fuse/connections none bind,optional 0 0
lxc.mount.entry = /sys/kernel/debug sys/kernel/debug none bind,optional 0 0
lxc.mount.entry = /sys/kernel/security sys/kernel/security none bind,optional 0 0
lxc.mount.entry = /sys/fs/pstore sys/fs/pstore none bind,optional 0 0

# Default console settings
lxc.devttydir = lxc
lxc.tty = 4
lxc.pts = 1024

# Default capabilities
lxc.cap.drop = mac_admin mac_override sys_time
lxc.cgroup.devices.allow = a *:* rwm

lxc.start.auto = 1
lxc.group = rpc_controllers
lxc.aa_profile = unconfined
EOF


# Update the lxc-defiant.conf file
cat > /etc/lxc/lxc-defiant.conf <<EOF
lxc.network.type=veth
lxc.network.name=eth0
lxc.network.link=lxcbr0
lxc.network.flags=up

lxc.network.type = veth
lxc.network.name = eth1
lxc.network.link = lxcbr0
lxc.network.flags = up
EOF

if [ ! "$(grep -w "${CONTAINER_USER}" /etc/passwd)" ];then
  useradd -m -s /bin/bash -c "Openstack User" ${CONTAINER_USER}
fi

if [ ! "$(grep -w "${CONTAINER_USER}" /etc/sudoers)" ];then
  echo "${CONTAINER_USER} ALL = NOPASSWD: ALL" | tee -a /etc/sudoers
fi

# Destroy the controller node if found
if [ "$(lxc-ls --fancy | grep controller1)" ];then
  lxc-destroy -n controller1 -f 
fi

lxc-create -n controller1 \
           -t defiant \
           -f /etc/lxc/lxc-defiant.conf \
           -- \
           -o curl,wget,iptables,python-dev,sshpass,git-core \
           -I eth0=10.0.3.100=255.255.255.0=10.0.3.1 \
           -I eth1=10.0.3.101=255.255.255.0 \
           -S /root/.ssh/id_rsa.pub \
           -P ${PASSWD} \
           -U ${CONTAINER_USER} \
           -M 4096 \
           --sudo-no-password \
           -L /var/log/controller1_logs=var/log

echo "" | tee -a /var/lib/lxc/controller1/config
echo "" | tee -a /var/lib/lxc/controller1/config
echo "" | tee -a /var/lib/lxc/controller1/config
lxc-start -d -n controller1

echo "Resting after container construction."
sleep 5

USER_SSH="ssh -o StrictHostKeyChecking=no ${CONTAINER_USER}@10.0.3.100"

# Set hostnames
if [ ! "$(grep "10.0.3.100 controller1" /etc/hosts)" ];then
    echo "10.0.3.100 controller1" | tee -a /etc/hosts
fi
if [ ! "$(grep "10.0.3.101 controller1" /etc/hosts)" ];then
    echo "10.0.3.101 controller1" | tee -a /etc/hosts
fi

# Install chef-client
bash <(wget -O - ${CHEF_CLIENT_URL}) -v ${CHEF_CLIENT_VERSION}

# Get Hostname
HOSTNAME=$(hostname)

# Basic Setup
echo "Creating SSH Key"
${USER_SSH} <<EOL
ssh-keygen -t rsa -f /home/${CONTAINER_USER}/.ssh/id_rsa -N ''
EOL

# System Setup
echo "Allowing root to login via SSH"
${USER_SSH} <<EOL
sudo sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
EOL

echo "Restarting SSH"
${USER_SSH} <<EOL
sudo /etc/init.d/ssh restart
EOL

echo "Setup DNS resolver and Hostname"
${USER_SSH} <<EOL
echo "nameserver 10.0.3.1" | sudo tee /etc/resolvconf/resolv.conf.d/original
echo "search localdomain" | sudo tee -a /etc/resolvconf/resolv.conf.d/original
if [ ! "$(grep "10.0.3.1 ${HOSTNAME}" /etc/hosts)" ];then
    echo "10.0.3.1 ${HOSTNAME}" | sudo tee -a /etc/hosts
fi
EOL

# This next block is due to a logic bomb that is happening with the keystone log
# being created and ownership changing to the keystone user but the keystone user
# does not exist.
echo "Create the keystone user on controller1"
useradd -m -s /bin/false -d /var/lib/keystone keystone || true
${USER_SSH} <<EOL
sudo su -c "useradd -m -s /bin/false -d /var/lib/keystone keystone || true"
EOL

echo "Installing Everything Else"
${USER_SSH} <<EOL
export COOKBOOK_VERSION="${COOKBOOK_VERSION}"
cat > install_all.sh <<EOF
git clone https://github.com/rcbops/support-tools /opt/tools
wget https://bootstrap.pypa.io/get-pip.py -P /opt/tools
python /opt/tools/get-pip.py

bash /opt/tools/chef-install/install-chef-rabbit-cookbooks.sh
rabbitmq-plugins enable rabbitmq_shovel
rabbitmq-plugins enable rabbitmq_management
rabbitmq-plugins enable rabbitmq_shovel_management
EOF

sudo su -c "export COOKBOOK_VERSION=\"${COOKBOOK_VERSION}\"; \
            bash /home/${CONTAINER_USER}/install_all.sh"
EOL

echo "Patching Nova VNC"
${USER_SSH} <<EOL
COOKBOOKS="/opt/rpcs/chef-cookbooks/cookbooks"
NOVACP="\${COOKBOOKS}/nova/templates/default/partials"
VNCCP="\${NOVACP}/vncproxy-options.partial.erb"
sudo su -c "sed -i 's/xvpvncproxy_host=.*/xvpvncproxy_host=10.0.3.100/' \${VNCCP}"
sudo su -c "sed -i 's/novncproxy_host=.*/novncproxy_host=10.0.3.100/' \${VNCCP}"
EOL

# Because chef is stupid we need to make sysctl go away.
echo "Patching sysctl"
${USER_SSH} <<EOL
sudo su -c "sed -i '/template/,/end/g' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/recipes/default.rb"
sudo su -c "sed -i '/file\ get_path/,/end/d' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/recipes/default.rb"
sudo su -c "sed -i '/execute/,/^end/d' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/recipes/default.rb"

sudo su -c "sed -i '/template/,/end/g' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/providers/multi.rb"
sudo su -c "sed -i '/file\ get_path/,/end/d' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/providers/multi.rb"
sudo su -c "sed -i '/execute/,/end/d' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/providers/multi.rb"

sudo su -c "sed -i '/template/,/end/g' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/providers/default.rb"
sudo su -c "sed -i '/file\ get_path/,/end/d' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/providers/default.rb"
sudo su -c "sed -i '/execute/,/end/d' /opt/rpcs/chef-cookbooks/cookbooks/sysctl/providers/default.rb"
EOL

echo "Uploading cookbooks"
retry_process ${USER_SSH} <<EOL
COOKBOOKS="/opt/rpcs/chef-cookbooks/cookbooks"
sudo su -c "knife cookbook upload -a -o \${COOKBOOKS}"
EOL

echo "Creating rpcs environment ini"
${USER_SSH} <<EOL
# Drop the environment ini in place.
ERLANG_COOKIE=\$(sudo cat /var/lib/rabbitmq/.erlang.cookie)
cat > rpcs.json <<EOF
{
  "name": "rpcs",
  "description": "Environment for Rackspace Private Cloud (Havana)",
  "cookbook_versions": {},
  "json_class": "Chef::Environment",
  "chef_type": "environment",
  "default_attributes": {
  },
  "override_attributes": {
    "rabbitmq": {
      "cluster": true,
      "erlang_cookie": "\${ERLANG_COOKIE}",
      "open_file_limit": 4096,
      "use_distro_version": false
    },
    "enable_monit": true,
    "monitoring" : {
      "procmon_provider" : "monit"
    },
    "keystone": {
      "tenants": [
        "admin",
        "service"
      ],
      "users": {
        "admin": {
          "password": "${PASSWD}",
          "roles": {
            "admin": [
              "admin"
            ]
          }
        }
      },
      "admin_user": "admin",
      "pki": {
        "enabled": false
      }
    },
    "nova": {
      "libvirt": {
        "vncserver_listen": "0.0.0.0"
      },
      "config": {
        "ram_allocation_ratio": 1.0,
        "cpu_allocation_ratio": 2.0,
        "disk_allocation_ratio": 1.0,
        "resume_guests_state_on_host_boot": false,
        "use_single_default_gateway": false,
        "force_config_drive": true
      },
      "scheduler": {
        "default_filters": [
          "AvailabilityZoneFilter",
          "RetryFilter"
        ]
      },
      "network": {
        "provider": "neutron"
      }
    },
    "neutron": {
      "ovs": {
        "provider_networks": [
          {
            "label": "ph-${NEUTRON_DEVICE}",
            "bridge": "br-${NEUTRON_DEVICE}",
            "vlans": "1:1000"
          }
        ],
        "network_type": "gre"
      }
    },
    "mysql": {
      "mysql_network_acl": "0.0.0.0",
      "allow_remote_root": true,
      "tunable": {
        "log_queries_not_using_index": false
      }
    },
    "osops_networks": {
      "nova": "10.0.3.0/24",
      "public": "10.0.3.0/24",
      "management": "10.0.3.0/24"
    }
  }
}
EOF
EOL

echo "Creating rpcs environment"
# this script is a hack until the vnc proxy bits make it upstream
# ref: https://github.com/rcbops/chef-cookbooks/issues/927
scp env_patch.py ${CONTAINER_USER}@10.0.3.100:/home/${CONTAINER_USER}/env_patch.py
SYS_IP=$(ip a l ${PRIMARY_DEVICE} | grep -w inet | awk -F" " '{print $2}'| sed -e 's/\/.*$//')

# When the perviously patch is taken care of remove the `env_patch.py` script.
retry_process ${USER_SSH} <<EOL
python env_patch.py ${CONTAINER_USER} ${SYS_IP}
sudo su -c "knife environment from file /home/${CONTAINER_USER}/rpcs.json"
EOL

echo "Registering the host key"
${USER_SSH} <<EOL
sudo su -c "sshpass -p ${PASSWD} ssh -o StrictHostKeyChecking=no root@10.0.3.1 'touch .controller1'"
EOL

echo "Copying The SSH key from the container to the host"
${USER_SSH} <<EOL
sudo su -c "sshpass -p ${PASSWD} ssh-copy-id root@10.0.3.1"
EOL

# This next block is due to a change in chef which relates to an 
# OpenSSL security issue
# http://www.getchef.com/blog/2014/04/08/openssl-heartbleed-security-update/
# Create the path to the trusted certs dir for chef and send over the chef cert
mkdir -p /etc/chef/trusted_certs/
echo "Get the chef-server host cert"
${USER_SSH} <<EOL
sudo su -c "scp /var/opt/chef-server/nginx/ca/controller1.crt root@10.0.3.1:/etc/chef/trusted_certs/"
EOL

echo "Bootstrapping the controller node"
retry_process ${USER_SSH} <<EOL
sudo su -c "knife bootstrap -E rpcs -r role[ha-controller1],role[heat-all] controller1"
EOL

# Remove the chef dir if found
if [ -d "/etc/chef" ];then
  rm -rf /etc/chef
fi

echo "Bootstrapping the compute, cinder, neutron node"
retry_process ${USER_SSH} <<EOL
sudo su -c "knife bootstrap 10.0.3.1 \
                            -E rpcs \
                            -r role[single-network-node],role[single-compute],role[cinder-volume] \
                            --server-url https://10.0.3.100:4000"
EOL

echo "finallizing the chef run"
retry_process ${USER_SSH} <<EOL
sudo su -c "chef-client"
EOL

source $HOME/openrc

# Make our networks
neutron net-create --provider:physical_network=ph-${NEUTRON_DEVICE} \
                   --provider:network_type=flat \
                   --shared raxova

# Make our subnets
SUBNET_ID=$(neutron subnet-create raxova \
                                  172.16.24.0/24 \
                                  --name raxova_subnet \
                                  --gateway 172.16.24.1 \
                                  --allocation-pool start=172.16.24.100,end=172.16.24.200 \
                                  --dns-nameservers list=true 8.8.4.4 8.8.8.8 \
                                  | grep -w id | awk '{print $4}')

# Router Create
ROUTER_ID=$(neutron router-create internalRouter | grep -w id | awk '{print $4}')

# Add the neutron router interface 
neutron router-interface-add ${ROUTER_ID} ${SUBNET_ID}

# Add Default Ping Security Group
neutron security-group-rule-create --protocol icmp \
                                   --direction ingress \
                                   default

# Add Default SSH Security Group
neutron security-group-rule-create --protocol tcp \
                                   --port-range-min 22 \
                                   --port-range-max 22 \
                                   --direction ingress \
                                   default

# Delete all of the m1 flavors
for FLAVOR in $(nova flavor-list | awk '/m1/ {print $2}');do
    nova flavor-delete ${FLAVOR}
done

# Create a new Standard Flavor
nova flavor-create "512MB Standard Instance" 1 512 5 1 --ephemeral 0 \
                                                       --swap 512 \
                                                       --rxtx-factor 1 \
                                                       --is-public True

# Get the image
wget http://download.cirros-cloud.net/0.3.1/cirros-0.3.1-x86_64-disk.img

# Upload the image
glance image-create --name cirros-image \
                    --disk-format=qcow2 \
                    --container-format=bare \
                    --is-public=True \
                    --file=./cirros-0.3.1-x86_64-disk.img

# Delete the image file
rm cirros-0.3.1-x86_64-disk.img

# Add a default Key
nova keypair-add adminKey --pub-key $HOME/.ssh/id_rsa.pub

# Add a Volume Type
nova volume-type-create RaxVolType

# Plugin the OVS interface
ovs-vsctl add-port br-${NEUTRON_DEVICE} ${NEUTRON_DEVICE}

# remove the files
if [ -f "/usr/lib/libvirt/connection-driver/libvirt_driver_xen.so" ];then
  rm /usr/lib/libvirt/connection-driver/libvirt_driver_xen.so
fi
if [ -f "/usr/lib/libvirt/connection-driver/libvirt_driver_libxl.so" ];then
  rm /usr/lib/libvirt/connection-driver/libvirt_driver_libxl.so
fi

# restart compute services
/etc/init.d/libvirt-bin restart
/etc/init.d/nova-compute restart

if [ -f "/lib/plymouth/themes/ubuntu-text/ubuntu-text.plymouth" ];then
    cat > /lib/plymouth/themes/ubuntu-text/ubuntu-text.plymouth <<EOF
[Plymouth Theme]
Name=Ubuntu Text
Description=Text mode theme based on ubuntu-logo theme
ModuleName=ubuntu-text

[ubuntu-text]
title=Rackspace Private Cloud, [ESC] for progress
black=0x000000
white=0xffffff
brown=0xff4012
blue=0x988592
EOF

    update-initramfs -u
fi

if [ -f "/etc/default/grub" ];then
    cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Rackspace Private Cloud"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_RECORDFAIL_TIMEOUT=1
EOF

    update-grub
fi

echo 'blacklist i2c_piix4' | tee -a /etc/modprobe.d/blacklist.conf
update-initramfs -u -k all

# Remove MOTD files
if [ -f "/etc/motd" ];then
  rm /etc/motd
fi

if [ -f "/var/run/motd" ];then
  rm /var/run/motd
fi

# Remove PAM motd modules from config
if [ -f "/etc/pam.d/login" ];then
  sed -i '/pam_motd.so/ s/^/#\ /' /etc/pam.d/login
fi

if [ -f "/etc/pam.d/sshd" ];then
  sed -i '/pam_motd.so/ s/^/#\ /' /etc/pam.d/sshd
fi

cat > /opt/motd.sh <<EOF
#!/usr/bin/env bash

SYS_IP=\$(ip a l ${PRIMARY_DEVICE} | grep -w inet | awk -F" " '{print \$2}'| sed -e 's/\/.*$//')
cat >/etc/motd <<EOH

This is an Openstack Deployment based on the Rackspace Private Cloud Software
# ===========================================================================
    Controller1 SSH command        : ssh -p 2222 openstack@\${SYS_IP}
    Your OpenStack Password is     : secrete
    Admin SSH key has been set as  : adminKey
    Openstack Cred File is located : /root/openrc
    Horizon URL is                 : https://\${SYS_IP}:443
    Horizon User Name              : admin
    Horizon Password               : secrete
    Chef User Name is              : admin
    Chef Server Password is        : secrete
    Sandbox User Name              : root
    Sandbox Password               : secrete
# ===========================================================================

Remember! That this system is using Neutron. To gain access to an instance
via the command line you MUST execute commands within in the namespace.
Example, "ip netns exec NAME_SPACE_ID bash".

This will give you shell access to the specific namespace routing table
Execute "ip netns" for a full list of all network namespsaces on this Server.

EOH

EOF

if [ -f "/opt/motd.sh" ];then
    chmod +x /opt/motd.sh
    /opt/motd.sh
    ln -f -s /etc/motd /etc/issue
fi

# Place the rax build init script
cp $(pwd)/rax-rebuild /etc/init.d/rax-rebuild 
chmod +x /etc/init.d/rax-rebuild
update-rc.d rax-rebuild defaults
