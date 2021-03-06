#!/usr/bin/env bash
#
# Ansible test script.
#
# Usage: [OPTIONS] scripts/test_in_docker.sh
#   - cleanup: whether to remove the Docker container after tests (default = true)
#   - container_id: the --name to set for the container (default = timestamp)
#   - test_idempotence: whether to test playbook's idempotence (default = true)
#
# License: MIT
#
# This script was derived from Jeff Geerling's Ansible Role Test Shim Script
# See https://gist.github.com/geerlingguy/73ef1e5ee45d8694570f334be385e181/

# Exit immediately if any command exits with a non-zero status.
set -e

# Pretty colors.
purple='\033[0;35m'
red='\033[0;31m'
green='\033[0;32m'
neutral='\033[0m'

# See http://docs.ansible.com/ansible/intro_configuration.html#force-color
color_opts='env ANSIBLE_FORCE_COLOR=1'

# Default container name. Only chars in [a-zA-Z0-9_.-] are allowed.
timestamp="$(date +%Y-%m-%dT%H.%M.%S_%Z)"

# Allow environment variables to override defaults.
cleanup=${cleanup:-"true"}
container_id=${container_id:-$timestamp}
test_idempotence=${test_idempotence:-"true"}

# See https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
parent_dir_of_this_script="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
host_project_dir="$(dirname $parent_dir_of_this_script)"

container_project_dir="/usr/local/nexus-IaC"
container_ansible_dir="$container_project_dir/ansible"

ansible_opts=(--inventory-file=$container_ansible_dir/inventories/test/hosts)
ansible_opts+=(--verbose)

# From Ansible for DevOps, version 2017-06-02, page 349:
#   Why use an init system in Docker? With Docker, it’s preferable to either
#   run apps directly (as ‘PID 1’) inside the container, or use a tool like Yelp’s
#   dumb-init161 as a wrapper for your app. For our purposes, we’re testing an
#   Ansible role or playbook that could be run inside a container, but is also
#   likely used on full VMs or bare-metal servers, where there will be a real
#   init system controlling multiple internal processes. We want to emulate
#   the real servers as closely as possible, therefore we set up a full init system
#   (systemd or sysv) according to the OS.
init_opts='--privileged --volume=/sys/fs/cgroup:/sys/fs/cgroup:ro'
init_exe='/lib/systemd/systemd'

# Run the container using the supplied OS.
printf ${purple}"Starting Docker container: cwardgar/docker-ubuntu1604-systemd.\n\n"${neutral}
docker pull cwardgar/docker-ubuntu1604-systemd:latest

# Below is a trick for documenting a long argument list. See https://unix.stackexchange.com/a/152554.
# It turns out that embedding the comments within the list (along with continuation operators) doesn't work:
# https://stackoverflow.com/questions/1455988/commenting-in-bash-script#comment18282079_1456059

# Run container in background.
docker_run_params=(--detach)
# The name of the container. By default, it is a timestamp of when this script was run.
docker_run_params+=(--name $container_id)
# Mount the host's nexus-IaC project directory to the container, with read-only privileges.
docker_run_params+=(--volume=$host_project_dir:$container_project_dir:ro)
# Some black magic to make systemD init work in the container.
docker_run_params+=($init_opts)
# Set an environment variable to allow ansible-playbook to find the Ansible configuration file.
# See http://docs.ansible.com/ansible/intro_configuration.html#configuration-file
docker_run_params+=(--env ANSIBLE_CONFIG=$container_ansible_dir/ansible.cfg)
# Set an environment variable to allow ansible-playbook to find the Vault password file.
# See http://docs.ansible.com/ansible/latest/playbooks_vault.html#running-a-playbook-with-vault
docker_run_params+=(--env ANSIBLE_VAULT_PASSWORD_FILE=$container_ansible_dir/files/vault-password)
# Propagates the 'VAULT_PASSWORD' variable I've set in my local environment to the container.
docker_run_params+=(--env VAULT_PASSWORD)
# /etc/hosts is read-only inside the container, so we must add our host mappings here.
docker_run_params+=(--add-host='artifacts.unidata.ucar.edu:127.0.0.1')
# Set a consistent hostname. Otherwise, it'll be the container ID, which is different every time.
# Duplicity gets mad if you try to make an incremental backup and you have a different hostname than before.
docker_run_params+=(--hostname='nexus-test')
# The image to run.
docker_run_params+=(cwardgar/docker-ubuntu1604-systemd:latest)
# The name of the system initialization program that will run first in the container.
docker_run_params+=($init_exe)

docker run "${docker_run_params[@]}"

printf ${purple}"\nInstalling Ansible.\n\n"${neutral}
docker exec $container_id $color_opts \
        $container_project_dir/scripts/install_ansible.sh

printf ${purple}"\nProvisioning the provisioner.\n\n"${neutral}
docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/prepare_ansible.yml

printf ${purple}"\nChecking Ansible playbook syntax.\n\n"${neutral}
docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/site.yml --syntax-check

printf ${purple}"\nRunning playbook: ensure configuration succeeds.\n\n"${neutral}
docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/site.yml

if [ "$test_idempotence" = true ]; then
  printf ${purple}"\nRunning playbook again: idempotence test.\n\n"${neutral}
  idempotence=$(mktemp)
  docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/site.yml | tee -a $idempotence
  tail $idempotence \
    | grep -q "changed=0.*failed=0" \
    && (printf ${green}"\nIdempotence test: pass\n"${neutral}) \
    || (printf ${red}"\nIdempotence test: fail\n"${neutral} && exit 1)
fi

printf ${purple}"\nRunning integration and functional tests against live instance.\n\n"${neutral}
docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/test.yml

printf ${purple}"\nBacking up application data to S3.\n\n"${neutral}
docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/backup.yml

printf ${purple}"\nRestoring application data from S3.\n\n"${neutral}
docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/restore.yml

printf ${purple}"\nRe-running tests that pull artifacts against the restored Nexus server.\n\n"${neutral}
docker exec $container_id $color_opts \
        ansible-playbook "${ansible_opts[@]}" $container_ansible_dir/test.yml --tags "test-pull"

if [ "$cleanup" = true ]; then
  printf ${purple}"\nRemoving Docker container...\n\n"${neutral}
  docker rm -f $container_id
fi
