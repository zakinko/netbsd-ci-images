# In-guest install script for the EOL CentOS releases (8 and 8-stream).
#
# Their cloud images point /etc/yum.repos.d at mirrorlist.centos.org, which
# stopped answering when the releases went EOL -- dnf does not get a 404, it
# gets nothing, so the failure reads as a network problem rather than as
# "this release is retired".  The packages are all still on vault.centos.org.
#
# Rewrite the repo files, then install exactly as hooks/vm_installpkgs.sh does.
sed -i -e 's/^mirrorlist=/#mirrorlist=/' \
       -e 's|^#\s*baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|' \
       /etc/yum.repos.d/CentOS-*.repo
dnf clean all
dnf clean expire-cache
dnf install -y --setopt=install_weak_deps=False $ANYVM_PKGS
