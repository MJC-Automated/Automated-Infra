#cloud-config
preserve_hostname: false
hostname: ${jsonencode(hostname)}
fqdn: ${jsonencode(hostname)}
prefer_fqdn_over_hostname: false
manage_etc_hosts: true
ssh_pwauth: false

users:
  - name: ${username}
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
%{ for key in ssh_public_keys ~}
      - ${jsonencode(key)}
%{ endfor ~}
