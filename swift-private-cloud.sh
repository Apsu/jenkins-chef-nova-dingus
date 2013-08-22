#!/usr/bin/env bash


START_TIME=$(date +%s)
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-grizzly}
CHEF_IMAGE=chef-template5

JOB_NAME="spc"
source $(dirname $0)/chef-jenkins.sh

print_banner "Initializing Job"
init

CHEF_ENV="swift-private-cloud"
print_banner "Build Parameters
~~~~~~~~~~~~~~~~
environment = ${CHEF_ENV}
INSTANCE_IMAGE=${INSTANCE_IMAGE}
AVAILABILITY_ZONE=${AZ}
TMPDIR = ${TMPDIR}
GIT_PATCH_URL = ${GIT_PATCH_URL}"

rm -rf logs
mkdir -p logs/run
exec 9>logs/run/out.log
BASH_XTRACEFD=9
set -x
GIT_REPO=${GIT_REPO:-swift-lite}
declare -a cluster
cluster=(admin1 proxy1 storage1 storage2 storage3) # order sensitive

start_timer
setup_quantum_network
stop_timer

start_timer
print_banner "creating chef server"
boot_and_wait chef-server
wait_for_ssh chef-server
stop_timer

start_timer
x_with_server "Fixing up the chef-server and booting the cluster" "chef-server" <<EOF
set_package_provider
update_package_provider
flush_iptables
run_twice install_package git-core
fixup_hosts_file_for_quantum
chef11_fixup
run_twice checkout_cookbooks
sudo apt-get install -y ruby1.9.3 libxml2-dev libxslt-dev build-essential libz-dev
git clone http://github.com/rcbops-cookbooks/swift-lite cookbooks/swift-lite
git clone http://github.com/rcbops-cookbooks/swift-private-cloud cookbooks/swift-private-cloud

pushd "cookbooks/${GIT_REPO}"
if [[ -n "${GIT_PATCH_URL}" ]] && ! ( curl -s ${GIT_PATCH_URL} | git apply ); then
    echo "Unable to merge proposed patch: ${GIT_PATCH_URL}"
    exit 1
fi
popd
EOF
background_task "fc_do"

boot_cluster ${cluster[@]}
stop_timer

start_timer
print_banner "Waiting for IP connectivity to the instances"
wait_for_cluster_ssh ${cluster[@]}
print_banner "Waiting for SSH to become available"
wait_for_cluster_ssh_key ${cluster[@]}
stop_timer

start_timer
x_with_server "uploading the cookbooks" "chef-server" <<EOF
#run_twice upload_cookbooks
#run_twice upload_roles
run_twice upload_roles /root/chef-cookbooks/cookbooks/swift-lite/contrib/roles
run_twice upload_roles /root/chef-cookbooks/cookbooks/swift-private-cloud/roles
cd /root/chef-cookbooks/cookbooks/swift-private-cloud
gem install berkshelf
berks install
berks upload
EOF
background_task "fc_do"

x_with_cluster "Cluster booted.  Setting up the package providers and vpn thingy..." ${cluster[@]} <<EOF
plumb_quantum_networks eth1
# set_quantum_network_link_up eth2
cleanup_metadata_routes eth0 eth1
fixup_hosts_file_for_quantum
wait_for_rhn
set_package_provider
update_package_provider
run_twice install_package bridge-utils
EOF
stop_timer

start_timer
print_banner "Setting up the chef environment"
# at this point, chef server is done, cluster is up.
# let's set up the environment.
create_chef_environment chef-server swift-private-cloud

# Set the package_component environment variable (not really needed in grizzly but no matter)
knife_set_package_component chef-server ${CHEF_ENV} ${PACKAGE_COMPONENT}
stop_timer

# add_chef_clients chef-server ${cluster[@]} # what does this do?

start_timer
x_with_cluster "Installing chef-client and running for the first time" proxy1 storage{1..3} admin1 <<EOF
flush_iptables
install_chef_client
chef11_fetch_validation_pem $(ip_for_host chef-server)
copy_file client-template.rb /etc/chef/client-template.rb
template_client $(ip_for_host chef-server)
chef-client
EOF
stop_timer

# not strictly necessary, as this is done on the client side
for host in ${cluster[@]}; do
    new_env="swift-private-cloud"
    set_node_attribute chef-server ${host} "chef_environment" "\"${new_env}\""
done

set_environment_attribute chef-server swift-private-cloud "override_attributes/swift-private-cloud/keystone/swift_admin_url" "\"http://$(ip_for_host proxy1):8080/v1/AUTH_%(tenant_id)s\""
set_environment_attribute chef-server swift-private-cloud "override_attributes/swift-private-cloud/keystone/swift_internal_url" "\"http://$(ip_for_host proxy1):8080/v1/AUTH_%(tenant_id)s\""
set_environment_attribute chef-server swift-private-cloud "override_attributes/swift-private-cloud/keystone/swift_public_url" "\"http://$(ip_for_host proxy1):8080/v1/AUTH_%(tenant_id)s\""

run_list_add chef-server admin1 "role[spc-starter-controller]"
x_with_cluster "installing admin node" admin1 <<EOF
chef-client
EOF

run_list_add chef-server proxy1 "role[spc-starter-proxy]"

for storage in storage{1..3}; do
        run_list_add chef-server ${storage} "role[spc-starter-storage]"
done

x_with_cluster "installing swifteses" proxy1 storage{1..3} <<EOF
chef-client
EOF

# TODO (wilk): test actual swift private cloud helpers and so on
# on the proxy, build up some rings.
x_with_server "three rings for the elven kings" proxy1 <<EOF
cd /etc/swift

swift-ring-builder object.builder create 8 3 0
swift-ring-builder container.builder create 8 3 0
swift-ring-builder account.builder create 8 3 0

swift-ring-builder object.builder add z1-$(ip_for_host storage1):6000/disk1 100
swift-ring-builder object.builder add z2-$(ip_for_host storage2):6000/disk1 100
swift-ring-builder object.builder add z3-$(ip_for_host storage3):6000/disk1 100

swift-ring-builder container.builder add z1-$(ip_for_host storage1):6001/disk1 100
swift-ring-builder container.builder add z2-$(ip_for_host storage2):6001/disk1 100
swift-ring-builder container.builder add z3-$(ip_for_host storage3):6001/disk1 100

swift-ring-builder account.builder add z1-$(ip_for_host storage1):6002/disk1 100
swift-ring-builder account.builder add z2-$(ip_for_host storage2):6002/disk1 100
swift-ring-builder account.builder add z3-$(ip_for_host storage3):6002/disk1 100

swift-ring-builder object.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder account.builder rebalance

chown -R swift: .
mkdir -p /tmp/rings
cp {account,object,container}.ring.gz /tmp/rings

chown -R ubuntu: /tmp/rings

exit 0
EOF

background_task "fc_do"

# ... and in parallel, format the drives and mount
x_with_cluster "Fixing up swift disks... under the sky" storage{1..3} <<EOF
install_package xfsprogs
umount /mnt || /bin/true
parted -s /dev/vdb mklabel msdos
parted -s /dev/vdb mkpart primary xfs 1M 100%
mkfs.xfs -f -i size=512 /dev/vdb1
mkdir -p /srv/node/disk1
mount /dev/vdb1 /srv/node/disk1 -o noatime,nodiratime,nobarrier,logbufs=8
chown -R swift: /srv/node/disk1
EOF

mkdir -p ${TMPDIR}/rings
fetch_file proxy1 "/tmp/rings/*.ring.gz" ${TMPDIR}/rings

x_with_cluster "copying ring data" storage{1..3} <<EOF
copy_file ${TMPDIR}/rings/account.ring.gz /etc/swift
copy_file ${TMPDIR}/rings/container.ring.gz /etc/swift
copy_file ${TMPDIR}/rings/object.ring.gz /etc/swift
chown -R swift: /etc/swift
EOF

# now start all the services
x_with_cluster "starting services" storage{1..3} proxy1 admin1 <<EOF
chef-client
EOF


cat > ${TMPDIR}/config.ini <<EOF2
[KongRequester]
auth_url = http://$(ip_for_host admin1):5000
user = admin
password = secrete
tenantname = admin
region = RegionOne
EOF2


# install kong and exerstack and do the thangs
x_with_server "Installing kong and exerstack" proxy1 <<EOF
cd /root
install_package git
git clone https://github.com/rcbops/kong /root/kong
git clone https://github.com/rcbops/exerstack /root/exerstack

cat > /root/exerstack/localrc <<EOF2
export SERVICE_HOST=$(ip_for_host admin1)
export NOVA_PROJECT_ID=admin
export OS_AUTH_URL=http://$(ip_for_host admin1):5000/v2.0
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=secrete
export OS_AUTH_STRATEGY=keystone
export OS_REGION_NAME=RegionOne
export OS_VERSION=2.0
EOF2

pushd /root/exerstack
./exercise.sh grizzly swift.sh
popd

copy_file ${TMPDIR}/config.ini /root/kong/etc

pushd /root/kong
ONESHOT=1 ./run_tests.sh -V --version grizzly --swift --keystone
popd

EOF

fc_do

echo "Done"
