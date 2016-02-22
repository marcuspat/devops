$pe_master_service = 'pe-puppetserver'
 service { "$pe_master_service":
  ensure => running,
}


file { '/etc/puppetlabs/puppet/autosign.conf':
  ensure  => file,
  content => "pe-internal-dashboard
pmaster2
*
",
  owner   => 'root',
  group   => 'pe-puppet',
  mode    => '0644',
  notify  => Service[$pe_master_service],
}
