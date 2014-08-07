#!/usr/bin/env bats
# vim: ft=sh:sw=2:et

set -o pipefail

load os_helper
load foreman_helper

setup() {
  URL_PREFIX=""
  FOREMAN_REPO=${FOREMAN_REPO:-nightly}
  tForemanSetupUrl
  tForemanSetLang
  FOREMAN_VERSION=$(tForemanVersion)
  tSetOSVersion

  if tIsFedora 19; then
    # missing service file in puppet
    tPackageExists "puppet" && \
      cp /usr/lib/systemd/system/puppetagent.service /etc/systemd/system/puppet.service

    # puppet selinux is a mess
    setenforce 0
  fi

  # disable firewall
  if tIsRedHatCompatible; then
    if tFileExists /usr/sbin/firewalld; then
      systemctl stop firewalld; systemctl disable firewalld
    elif tCommandExists systemctl; then
      systemctl stop iptables; systemctl disable iptables
    else
      service iptables stop; chkconfig iptables off
    fi
  fi

  tPackageExists curl || tPackageInstall curl
  if tIsRedHatCompatible; then
    tPackageExists yum-utils || tPackageInstall yum-utils
  fi
}

@test "stop puppet agent (if installed)" {
  tPackageExists "puppet" || skip "Puppet package not installed"
  if tIsRHEL 6; then
    service puppet stop; chkconfig puppet off
  elif tIsFedora; then
    service puppetagent stop; chkconfig puppetagent off
  elif tIsDebianCompatible; then
    service puppet stop
  fi
  true
}

@test "clean after puppet (if installed)" {
  [[ -d /var/lib/puppet/ssl ]] || skip "Puppet not installed, or SSL directory doesn't exist"
  rm -rf /var/lib/puppet/ssl
  [ -n "$FOREMAN_VERSION" -o x$FOREMAN_VERSION = "x1.5" -o x$FOREMAN_VERSION = "x1.4" ] && \
    service foreman-proxy status && service foreman-proxy stop || true
}

@test "make sure puppet not configured to other pm" {
  egrep -q "server\s*=" /etc/puppet/puppet.conf || skip "Puppet not installed, or 'server' not configured"
  sed -ir "s/^\s*server\s*=.*/server = $(hostname -f)/g" /etc/puppet/puppet.conf
}

@test "wait max 30 secs until network is up" {
  ping -c1 -w30 8.8.8.8
}

@test "subscribe and attach channels" {
  if tIsRHEL; then
    [[ -z "$RHSM_USER" || -z "$RHSM_PASS" || -z "$RHSM_POOL" ]] && skip "No subscription-manager credentials and pool id"
    tPackageExists subscription-manager || tPackageInstall subscription-manager
    echo $RHSM_USER $RHSM_PASS $RHSM_POOL
    subscription-manager register --username=$RHSM_USER --password=$RHSM_PASS
    subscription-manager attach --pool=$RHSM_POOL
    subscription-manager repos --enable rhel-server-rhscl-$OS_VERSION-rpms --enable rhel-$OS_VERSION-server-optional-rpms
  else
    skip "Not required"
  fi
}

@test "enable epel" {
  tIsRHEL || skip "Not required"
  if tIsRHEL 7; then
    EPEL_REL="7-0.2"
    tPackageExists epel-release-$EPEL_REL || \
      yum -y install http://dl.fedoraproject.org/pub/epel/beta/7/x86_64/epel-release-$EPEL_REL.noarch.rpm
  elif tIsRHEL 6; then
    EPEL_REL="6-8"
    tPackageExists epel-release-$EPEL_REL || \
      rpm -Uvh http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-$EPEL_REL.noarch.rpm
  else
    skip "Unknown RHEL version"
  fi
}

@test "configure repository" {
  if tIsRedHatCompatible; then
    rpm -q foreman-release || yum -y install $FOREMAN_URL

    if [ -n "$FOREMAN_CUSTOM_URL" ]; then
      cat > /etc/yum.repos.d/foreman-custom.repo <<EOF
[foreman-custom]
name=foreman-custom
enabled=1
gpgcheck=0
baseurl=${FOREMAN_CUSTOM_URL}
EOF
      yum-config-manager --disable foreman
    fi
  elif tIsDebianCompatible; then
    echo "deb http://deb.theforeman.org/ ${OS_RELEASE} ${FOREMAN_REPO}" > /etc/apt/sources.list.d/foreman.list
    echo "deb http://deb.theforeman.org/ plugins ${FOREMAN_REPO}" >> /etc/apt/sources.list.d/foreman.list
    wget -q http://deb.theforeman.org/foreman.asc -O- | apt-key add -
    apt-get update
  else
    skip "Unknown operating system"
  fi
}

@test "install installer" {
  tPackageExists foreman-installer || tPackageInstall foreman-installer || return $?
  FOREMAN_VERSION=$(tPackageVersion foreman-installer | cut -d. -f1-2)

  # Work around http://projects.theforeman.org/issues/3950
  if [ -n "$MODULE_PATH" ] ; then
    install_conf=/usr/share/foreman-installer/config/foreman-installer.yaml
    [ -e /etc/foreman/foreman-installer.yaml ] && install_conf=/etc/foreman/foreman-installer.yaml
    ruby -ryaml - $install_conf "$MODULE_PATH" <<EOF
data = YAML::load(File.open(ARGV[0]))
data[:module_dir] = ARGV[1]
data[:modules_dir] = ARGV[1]
File.open(ARGV[0], 'w') { |f| f.write(data.to_yaml) }
EOF
  fi
}

@test "run the installer" {
  if [ x$FOREMAN_VERSION = "x1.5" -o x$FOREMAN_VERSION = "x1.4" ]; then
    foreman-installer --no-colors -v
  else
    foreman-installer --no-colors -v --foreman-admin-password=admin
  fi
}

@test "check for no changes when running the installer" {
  [ x$FOREMAN_VERSION = "x1.5" -o x$FOREMAN_VERSION = "x1.4" ] && skip "Only supported on 1.6+"
  tIsDebianCompatible && [ x$OS_RELEASE = xsqueeze -o x$OS_RELEASE = xprecise ] && skip "Known bug #6520"
  foreman-installer --no-colors -v --detailed-exitcodes
  [ $? -eq 0 ]
}

@test "wait 10 seconds" {
  sleep 10
}

@test "check web app is up" {
  curl -sk "https://localhost$URL_PREFIX/users/login" | grep -q login-form
}

@test "wake up puppet agent" {
  puppet agent -t -v
}

@test "install all compute resources" {
  tPackageInstall foreman-console
  if [ x$FOREMAN_VERSION = "x1.4" ]; then
    tPackageInstall foreman-libvirt foreman-vmware foreman-ovirt foreman-gce
  else
    foreman-installer --no-colors -v \
      --enable-foreman-compute-ec2 \
      --enable-foreman-compute-gce \
      --enable-foreman-compute-libvirt \
      --enable-foreman-compute-openstack \
      --enable-foreman-compute-ovirt \
      --enable-foreman-compute-rackspace \
      --enable-foreman-compute-vmware
  fi
}

@test "check web app is still up" {
  curl -sk "https://localhost$URL_PREFIX/users/login" | grep -q login-form
}

@test "restart foreman" {
  touch ~foreman/tmp/restart.txt
}

@test "install CLI (hammer)" {
  if [ x$FOREMAN_VERSION = "x1.5" -o x$FOREMAN_VERSION = "x1.4" ]; then
    tPackageInstall foreman-cli
  else
    foreman-installer --no-colors -v \
      --enable-foreman-cli
  fi
}

@test "check smart proxy is registered" {
  count=$(hammer $(tHammerCredentials) --csv proxy list | wc -l)
  [ $count -gt 1 ]
}

@test "check host is registered" {
  hammer $(tHammerCredentials) host info --name $(hostname -f) | egrep "Last report.*$(date +%Y/%m/%d)"
}

# ENC / Puppet class apply tests
@test "install puppet module" {
  [ -d /etc/puppet/environments/production/modules/ntp ] || \
    puppet module install -i /etc/puppet/environments/production/modules -v 3.0.3 puppetlabs/ntp
  [ -e /etc/puppet/environments/production/modules/ntp/manifests/init.pp ]
}

@test "import ntp puppet class" {
  [ x$FOREMAN_VERSION = "x1.4" ] && skip "Only supported on 1.5+"
  id=$(hammer $(tHammerCredentials) --csv proxy list | tail -n1 | cut -d, -f1)
  hammer $(tHammerCredentials) proxy import-classes --id $id
  count=$(hammer $(tHammerCredentials) --csv puppet-class list --search 'name = ntp' | wc -l)
  [ $count -gt 1 ]
}

@test "assign puppet class to host" {
  [ x$FOREMAN_VERSION = "x1.4" ] && skip "Only supported on 1.5+"
  id=$(hammer $(tHammerCredentials) --csv puppet-class list --search 'name = ntp' | tail -n1 | cut -d, -f1)
  hammer $(tHammerCredentials) host update --puppetclass-ids $id --name $(hostname -f)
}

@test "apply class with puppet agent" {
  [ x$FOREMAN_VERSION = "x1.4" ] && skip "Only supported on 1.5+"
  puppet agent -v -o --no-daemonize
  grep -i puppet /etc/ntp.conf
}

# Cleanup
@test "collect important logs" {
  tail -n100 /var/log/{apache2,httpd}/*_log /var/log/foreman{-proxy,}/*log /var/log/messages > /root/last_logs || true
  foreman-debug -q -d /root/foreman-debug || true
  if tIsRedHatCompatible; then
    tPackageExists sos || tPackageInstall sos
    sosreport --batch --tmp-dir=/root || true
  fi
}
