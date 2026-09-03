# DevOps Automation Collection

Collection of DevOps automation scripts, Vagrant configurations, and Ansible playbooks for development environment setup and infrastructure management.

## 🎯 Overview

This repository contains practical DevOps automation tools used for:
- **Development environment provisioning** with Vagrant
- **Infrastructure automation** with Ansible playbooks
- **Server configuration** management
- **Cloud deployment** automation
- **Testing infrastructure** setup

## 📁 Contents

### Vagrantfiles
Virtual machine configurations for various operating systems:
- **CentOS 7** (multiple versions: 2015.3.1, 3.8.1)
- **Ubuntu** configurations
- **OpenStack** with Chef integration
- **Development environments** for testing

### Ansible Playbooks
Infrastructure automation playbooks:
- **ec2-server.yml** - AWS EC2 server provisioning
- **ec2.py** - EC2 dynamic inventory script
- **nginx.conf** - Nginx server configuration
- **index.html.j2** - Web server template

### Scripts
Automation utilities:
- **playbooktemplate.sh** - Ansible playbook template generator

## 🚀 Usage

### Vagrant Development Environments

**CentOS Development Environment:**
```bash
cd Vagrantfiles/centos7_3.8.1
vagrant up
vagrant ssh
```

**Ubuntu Development Environment:**
```bash
cd Vagrantfiles/Ubuntu
vagrant up
vagrant ssh
```

### Ansible Automation

**EC2 Server Provisioning:**
```bash
cd playbooks
ansible-playbook -i ec2.py ec2-server.yml
```

## 🔧 Requirements

### For Vagrant:
- **VirtualBox** or **VMware Workstation**
- **Vagrant** 2.0+
- **Minimum 8GB RAM** for VM operations
- **20GB disk space** per VM

### For Ansible:
- **Ansible** 2.9+
- **Python** 2.7+ or 3.5+
- **SSH access** to target systems
- **Sudo privileges** on target systems

## 🛠️ Tech Stack

- **Virtualization**: Vagrant, VirtualBox, VMware
- **Automation**: Ansible
- **Cloud**: AWS EC2
- **Web Servers**: Nginx
- **Operating Systems**: CentOS, Ubuntu

## 📋 Use Cases

**Development Environments:**
- Local testing environments
- Multi-OS compatibility testing
- Development sandbox creation
- Quick environment replication

**Infrastructure Automation:**
- Server provisioning
- Configuration management
- Deployment automation
- Cloud resource management

## 🎓 Learning Resources

This repository demonstrates:
- **Vagrant** for development environment management
- **Ansible** for configuration automation
- **AWS EC2** integration
- **Infrastructure as code** practices
- **Multi-environment** setup

## 🔧 Configuration

**Vagrant Configuration:**
```ruby
# Example Vagrantfile configuration
Vagrant.configure("2") do |config|
  config.vm.box = "centos/7"
  config.vm.network "private_network", type: "dhcp"
  config.vm.provider "virtualbox" do |vb|
    vb.memory = "2048"
    vb.cpus = 2
  end
end
```

**Ansible Configuration:**
```yaml
# Example playbook structure
---
- hosts: webservers
  become: yes
  tasks:
    - name: Install nginx
      yum:
        name: nginx
        state: present
```

## 🤝 Contributing

Contributions welcome! This collection of DevOps tools is designed to be practical and reusable across different projects.

## 📚 Related Repositories

- **Misc_Ansible_Playbooks**: General Ansible automation
- **terraform_ansible_jenkins_deployment**: Jenkins CI/CD setup

## 📝 License

MIT — see [LICENSE](LICENSE).

---

**DevOps Automation Collection** - Streamlining development and operations with practical automation tools and configurations.