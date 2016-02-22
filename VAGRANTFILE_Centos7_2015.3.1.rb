VAGRANTFILE_API_VERSION = "2"

Vagrant.configure('2') do |config|
  config.vm.box                      = 'puppetlabs/centos-7.0-64-nocm'
  config.pe_build.download_root      = 'https://s3.amazonaws.com/pe-builds/released/2015.3.1'
  config.pe_build.version            = '2015.3.1'
  config.pe_build.filename           = 'puppet-enterprise-2015.3.1-el-7-x86_64.tar.gz'

# config.vm.provision 'shell', inline: 'yum update -y'
  config.vm.provision 'shell', inline: 'systemctl disable firewalld'
  config.vm.provision 'shell', inline: 'systemctl stop firewalld'
  config.vm.provision :hosts

  # Puppet Master config
    config.vm.define 'pmaster2' do |master|
    master.vm.hostname = 'pmaster2.localnet'
    master.vm.network :private_network, ip: "192.168.111.55"
    master.vm.provider :virtualbox do |vbox|
      vbox.customize ["modifyvm", :id, "--memory", "2048"]
    end

    master.vm.provision :pe_bootstrap do |provisioner|
      provisioner.role = :master
      provisioner.master = "pmaster2.localnet"
    end
end

# Webserver node config
  config.vm.define 'webserver' do |webserver|
    webserver.vm.hostname = 'webserver100.localnet'
    webserver.vm.network :private_network, ip: "192.168.111.104"
    webserver.vm.provider :virtualbox do |vbox|
    end

    webserver.vm.provision :pe_bootstrap do |provisioner|
      provisioner.role = :agent
      provisioner.master = "pmaster2.localnet"
    end
end
end
