#! /bin/bash

# Disable host fingerprint checking
echo "    StrictHostKeyChecking no" >> /etc/ssh/ssh_config

# Download static private key
curl http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-key-to-use -H 'Metadata-Flavor: Google' -o /root/.ssh/id_rsa
sudo chmod 600 /root/.ssh/id_rsa
