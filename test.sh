#!/bin/bash

# Copyright 2017 The Kubernetes Authors.
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

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Install glide, golint, cfssl
curl https://glide.sh/get | sh
go get -u github.com/golang/lint/golint
export PATH=$PATH:$GOPATH/bin
go get -u github.com/alecthomas/gometalinter
gometalinter --install
make verify

if [ "$TEST_SUITE" = "nfs" ]; then
	# Install nfs, cfssl
	sudo apt-get -qq update
	sudo apt-get install -y nfs-common
	go get -u github.com/cloudflare/cfssl/cmd/...

	# Install etcd
	pushd $HOME
	DOWNLOAD_URL=https://github.com/coreos/etcd/releases/download
	curl -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
	mkdir -p /tmp/test-etcd && tar xzvf /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C /tmp/test-etcd --strip-components=1
	export PATH=${PATH}:/tmp/test-etcd

	# Install kubernetes
	curl -L https://dl.k8s.io/v${KUBE_VERSION}/kubernetes-server-linux-amd64.tar.gz | tar xz
	curl -L https://github.com/kubernetes/kubernetes/archive/v${KUBE_VERSION}.tar.gz | tar xz
	popd

	# Start kubernetes
	mkdir -p $HOME/.kube
	sudo chmod -R 777 $HOME/.kube
	sudo "PATH=$PATH" KUBECTL=$HOME/kubernetes/server/bin/kubectl ALLOW_SECURITY_CONTEXT=true API_HOST_IP=0.0.0.0 $HOME/kubernetes-${KUBE_VERSION}/hack/local-up-cluster.sh -o $HOME/kubernetes/server/bin >/tmp/local-up-cluster.log 2>&1 &
	touch /tmp/local-up-cluster.log
	timeout 30 grep -q "Local Kubernetes cluster is running." <(tail -f /tmp/local-up-cluster.log)
	if [ $? == 124 ]; then
		cat /tmp/local-up-cluster.log
		exit 1
	fi
	KUBECTL=$HOME/kubernetes/server/bin/kubectl
	if [ "$KUBE_VERSION" = "1.5.4" ]; then
		$KUBECTL config set-cluster local --server=https://localhost:6443 --certificate-authority=/var/run/kubernetes/apiserver.crt;
		$KUBECTL config set-credentials myself --username=admin --password=admin;
	else
		$KUBECTL config set-cluster local --server=https://localhost:6443 --certificate-authority=/var/run/kubernetes/server-ca.crt;
		$KUBECTL config set-credentials myself --client-key=/var/run/kubernetes/client-admin.key --client-certificate=/var/run/kubernetes/client-admin.crt;
	fi
	$KUBECTL config set-context local --cluster=local --user=myself
	$KUBECTL config use-context local
	if [ "$KUBE_VERSION" != "1.5.4" ]; then
		sudo chown -R $(logname) /var/run/kubernetes;
	fi

	# Build nfs-provisioner and run tests
	make nfs
	make test-nfs
elif [ "$TEST_SUITE" = "everything-else" ]; then
	pushd ./lib
	go test ./controller
	go test ./allocator
	popd
	# Test building hostpath-provisioner demo
	pushd ./docs/demo/hostpath-provisioner
	make image
	make clean
	popd
	make aws/efs
	make test-aws/efs
	make ceph/cephfs
	make ceph/rbd
	make flex
	make gluster/block
	make gluster/glusterfs
	make iscsi/targetd
	make test-iscsi/targetd
	make nfs-client
	make snapshot
	make test-snapshot
	make test-openstack/standalone-cinder
elif [ "$TEST_SUITE" = "local-volume" ]; then
	make local-volume/provisioner
	make test-local-volume/provisioner
fi
