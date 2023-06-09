#!/bin/bash

# VyOS Branch
# equuleus = v1.3.x (stable)
# sagitta  = v1.4.x (dev)
VYOS_BRANCH="${1:-equuleus}"

# Next Action
# boot = boot the ISO
# http = serve the ISO over HTTP and HTTPS
ACTION="${2:-boot}"

# Install some packages.
apt-get update
apt-get install -y apt-transport-https ca-certificates gnupg2 software-properties-common git

# Upgrade all packages.
apt-get upgrade -y

# Install and start Docker.
curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
apt-get update
apt-get install -y docker-ce
systemctl start docker

# Get v1.3.x (equuleus)
cd /root && git clone -b equuleus --single-branch https://github.com/vyos/vyos-build

# Build the vyos-build Docker image.
cd /root/vyos-build/docker && docker build -t vyos-builder .

# Trust the PowerDNS repo.  (Shouldn't need to do this...)
sed -ri 's;deb \[arch=amd64\] (http://repo\.powerdns\.com/debian .*);deb [arch=amd64 trusted=yes] \1;' /root/vyos-build/data/defaults.json

# Create the VyOS ISO.
cd /root/vyos-build && docker run -t -v "$(pwd)":/vyos -w /vyos --privileged --sysctl net.ipv6.conf.lo.disable_ipv6=0 vyos-builder bash -c './configure && make iso'

# Ensure the ISO was created.
test -f /root/vyos-build/build/live-image-amd64.hybrid.iso || echo -e "\n\nSomething went wrong... aborting.  Please check for errors above." && exit 1

if [ "x$ACTION" == "xboot" ] ; then

  echo '
    menuentry "live-amd64-vyos" {
      insmod ext2
      set isofile="/root/vyos-build/build/live-image-amd64.hybrid.iso"
      loopback loop (hd0,1)$isofile
      linux (loop)/live/vmlinuz boot=live fromiso=/dev/sda1$isofile toram components hostname=vyos username=live nopersistence noautologin nonetworking union=overlay console=ttyS0,115200 console=tty0 net.ifnames=0 biosdevname=0
      initrd (loop)/live/initrd.img
    }' >> /etc/grub.d/40_custom
  update-grub
  grub-reboot live-amd64-vyos
  reboot

elif [ "x$ACTION" == "xhttp" ] ; then

  systemctl stop docker
  apt-get install -y nginx
  ufw allow http
  ufw allow https
  CURDATE=$(date +'%Y-%m-%d')
  FINAL_FILENAME="vyos-1.3.x-amd64-${CURDATE}.iso"
  ADDRESSES=$(ip addr | grep -P 'inet (?!127)' | grep -v 'docker' | awk '{sub(/\/[0-9]+/, "", $2); print $2}')
  /bin/mkdir /var/www/html/vyos
  /bin/mv /root/vyos-build/build/live-image-amd64.hybrid.iso /var/www/html/vyos/${FINAL_FILENAME}
  cd /var/www/html/vyos
  sha256sum -b $FINAL_FILENAME >${FINAL_FILENAME}.sha256
  cd /root/vyos-build
  git log --since="6 months ago" >/var/www/html/vyos/VYOS-BUILD-COMMITS
  openssl req -nodes -newkey rsa:2048 -keyout /etc/ssl/private/vyos-build.iso.key -out /tmp/vyos-build.iso.csr -subj "/C=XX/ST=Unknown/L=Unknown/O=Unknown/OU=Unknown/CN=vyos-build.iso"
  openssl x509 -signkey /etc/ssl/private/vyos-build.iso.key -in /tmp/vyos-build.iso.csr -req -days 365 -out /etc/ssl/certs/vyos-build.iso.crt
  echo '
  server {
   	listen 80 default_server;
   	listen [::]:80 default_server;
   	listen 443 ssl default_server;
   	listen [::]:443 ssl default_server;
   	ssl_certificate /etc/ssl/certs/vyos-build.iso.crt;
   	ssl_certificate_key /etc/ssl/private/vyos-build.iso.key;
   	root /var/www/html;
   	default_type text/plain;
   	index index.html index.nginx-debian.html;
   	server_name _;
   	location / {
      autoindex on;
      try_files $uri $uri/ =404;
   	}
  }' > /etc/nginx/sites-enabled/default
  systemctl restart nginx
  echo
  echo "================================"
  echo "Get the VyOS ISO at:"
  for ADDRESS in $ADDRESSES; do
    echo "http://${ADDRESS}/vyos/${FINAL_FILENAME}"
    echo "https://${ADDRESS}/vyos/${FINAL_FILENAME}"
  done
  echo "================================"
  echo

fi
