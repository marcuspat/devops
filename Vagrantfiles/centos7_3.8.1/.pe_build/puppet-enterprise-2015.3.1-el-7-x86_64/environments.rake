namespace :environments do
  task :check do
    check_and_upgrade(false)
  end
  task :upgrade do
    check_and_upgrade(true)
  end
end

def check_and_upgrade(do_upgrade=false)
  require 'puppet'

  ## Initialize puppet for reading environment settings from puppet.conf
  config = get_puppet_config()
  config[:main].merge!(config[:master] || {})
  if config[:main][:environmentpath]
    exit 0
  end
  if config[:main][:manifest] and config[:main][:manifestdir]
    puts "Upgrading to directory environments cannot continue; both $manifest and $manifestdir were discovered in puppet.conf. The upgrade can only proceed if one of them is present."
    raise Puppet::Error, "Upgrading to directory environments cannot continue; both $manifest and $manifestdir were discovered in puppet.conf. The upgrade can only proceed if one of them is present."
  end

  real_modulepath = get_real_modulepath(config)

  environment_defaults = get_smart_environment_defaults(real_modulepath,config[:main][:manifest],config[:main][:manifestdir])

  dynamic_prefixes = real_modulepath.collect do |path|
    m = path.match(%r{(^(?:(?!\$environment).)+)/\$environment/?})
    m[1] if m
  end.compact.uniq

  custom_environment_names = Array.new
  if ! environment_defaults
    if dynamic_prefixes.length == 1
      environment_defaults = {
        :environmentpath  => dynamic_prefixes.first,
        :basemodulepath   => Array("/opt/puppet/share/puppet/modules"),
        :default_manifest => nil, # to be explicitly set in environment.conf files
      }
      custom_environment_names = enumerate_dynamic_environments(real_modulepath)
    else
      environment_defaults = {
        :environmentpath  => "/etc/puppetlabs/puppet/environments",
        :basemodulepath   => Array("/opt/puppet/share/puppet/modules"),
        :default_manifest => nil, # to be explicitly set in environment.conf files
      }
      custom_environment_names = enumerate_dynamic_environments(real_modulepath)
    end
  end
  static_environment_names = config.keys.reject do |r|
    %w[main master agent user].include?(r.to_s)
  end
  custom_environment_names += static_environment_names
  custom_environment_names.uniq!
  custom_environment_settings = custom_environment_names.inject({}) do |memo,env|
    if defined? Puppet::Environments
      env = Puppet::Environments::Legacy.new.get(env)
    else
      env = Puppet::Node::Environment.new(env)
    end
    full_modulepath = env.respond_to?(:full_modulepath) ? env.full_modulepath : env[:modulepath].split(File::PATH_SEPARATOR)
    modulepath = full_modulepath.collect do |path|
      remove_environment_prefix(environment_defaults[:environmentpath],path,env.to_s)
    end
    env_manifest = env.respond_to?(:manifest) ? env.manifest : Puppet.settings.value(:manifest, env.to_s)
    manifest = remove_environment_prefix(environment_defaults[:environmentpath],env_manifest,env.to_s)
    memo[env.to_s] = {
      :modulepath     => modulepath,
      :manifest       => manifest,
    }
    env_config_version = env.respond_to?(:config_version) ? env.config_version : Puppet.settings.value(:config_version, env.to_s)
    if ! env_config_version.empty?
      if env_config_version.match(%r{^/})
        memo[env.to_s][:config_version] = env_config_version
      else
        puts "Upgrading to directory environments cannot continue; a config_version setting with a non-absolute path was detected for environment '#{env.to_s}'. The upgrade can only proceed if it is an absolute path."
        raise Puppet::Error, "Upgrading to directory environments cannot continue; a config_version setting with a non-absolute path was detected for environment '#{env.to_s}'. The upgrade can only proceed if it is an absolute path."
      end
    end
    memo
  end

  if do_upgrade
    FileUtils.mkdir_p(File.join(environment_defaults[:environmentpath],"production"))
    write_puppet_conf(environment_defaults[:default_manifest], environment_defaults[:basemodulepath], environment_defaults[:environmentpath])
    write_environment_confs(environment_defaults[:environmentpath], custom_environment_settings)
    delete_static_environments(static_environment_names)
  end
end

def read_config(file)
  if defined? Puppet::Filesystem
    Puppet::Filesystem.read(file)
  else
    File.read(file)
  end
end

def write_puppet_conf(default_manifest, basemodulepath, environmentpath)
  puts ""
  puts "# Adding to /etc/puppetlabs/puppet/puppet.conf"
  puts "environmentpath = #{environmentpath}"
  puts "basemodulepath = #{basemodulepath.join(':')}"
  puts "default_manifest = #{default_manifest}" if default_manifest
  puts ""

  require 'augeas'
  Augeas::open do |aug|
    conf = "/files/etc/puppetlabs/puppet/puppet.conf"
    aug.rm("#{conf}/main/manifest")
    aug.rm("#{conf}/master/manifest")
    aug.rm("#{conf}/main/manifestdir")
    aug.rm("#{conf}/master/manifestdir")
    aug.rm("#{conf}/main/modulepath")
    aug.rm("#{conf}/master/modulepath")
    aug.rm("#{conf}/master/basemodulepath")
    aug.set("#{conf}/main/basemodulepath", basemodulepath.join(":"))
    aug.set("#{conf}/main/environmentpath", environmentpath)
    aug.set("#{conf}/main/default_manifest", default_manifest) if default_manifest
    unless aug.save
      puts "Failed to upgrade settings /etc/puppetlabs/puppet/puppet.conf"
      raise IOError, "Failed to upgrade settings /etc/puppetlabs/puppet/puppet.conf"
    end
  end
end

def write_environment_confs(environmentpath, environment_settings)
  environment_settings.each do |name,settings|
    absolute_env_path = environmentpath.sub(/\$confdir/, Puppet[:confdir])
    puts "# #{absolute_env_path}/#{name}/environment.conf"
    puts "modulepath = #{settings[:modulepath].join(':')}" unless settings[:modulepath].empty?
    puts "manifest = #{settings[:manifest]}" if settings[:manifest]
    puts "config_version = #{settings[:config_version]}" if settings[:config_version]
    FileUtils.mkdir_p(File.join(absolute_env_path,name))
    File.open(File.join(absolute_env_path,name,"environment.conf"),"w") do |f|
      f.puts "modulepath = #{settings[:modulepath].join(':')}" unless settings[:modulepath].empty?
      f.puts "manifest = #{settings[:manifest]}" if settings[:manifest]
      f.puts "config_version = #{settings[:config_version]}" if settings[:config_version]
    end
  end
end

def delete_static_environments(environment_names)
  require 'augeas'
  Augeas::open do |aug|
    conf = "/files/etc/puppetlabs/puppet/puppet.conf"
    environment_names.each do |static_env_name|
      aug.rm("#{conf}/#{static_env_name}")
    end
    unless aug.save
      puts "Failed to remove static environments from /etc/puppetlabs/puppet/puppet.conf"
      raise IOError, "Failed to remove static environments from /etc/puppetlabs/puppet/puppet.conf"
    end
  end
end

def get_smart_environment_defaults(modulepath,manifest,manifestdir)
  if modulepath_match = modulepath.first.match(%r{(^(?:(?!\$environment).)+)/\$environment/modules/?$}) and ! modulepath[1..-1].find { |x| x.match(%r{\$environment}) }
    environmentpath = modulepath_match[1]
    basemodulepath = modulepath[1..-1]

    if manifest
      default_manifest = manifest
    elsif manifestdir
      default_manifest = File.join(manifestdir, "site.pp")
    else
      default_manifest = "/etc/puppetlabs/puppet/manifests/site.pp"
    end

    default_manifest = default_manifest.sub(%r{^#{Regexp.escape(File.join(environmentpath,"$environment"))}},".")
    if ! default_manifest.match(%r{\$environment})
      return {
        :environmentpath  => environmentpath,
        :basemodulepath   => Array(basemodulepath),
        :default_manifest => default_manifest,
      }
    end
  elsif modulepath == ["/etc/puppetlabs/puppet/modules","/opt/puppet/share/puppet/modules"]
    if ! manifest or manifest == "/etc/puppetlabs/puppet/manifests/site.pp"
      return {
        :environmentpath  => "/etc/puppetlabs/puppet/environments",
        :basemodulepath   => ["/etc/puppetlabs/puppet/modules","/opt/puppet/share/puppet/modules"],
        :default_manifest => "/etc/puppetlabs/puppet/manifests/site.pp",
      }
    end
  end
end

def enumerate_dynamic_environments(modulepath)
  env_paths = modulepath.collect do |x|
    m = x.match(%r{^((.*?)((?:\$environment)(.*$)))})
    m[2] if m
  end.compact
  env_paths.flat_map do |env_path|
    absolute_env_path = env_path.sub(/\$confdir/, Puppet[:confdir])
    Dir[File.join(absolute_env_path,'*/')].collect { |x| File.basename(x) }
  end.uniq
end

def get_puppet_config
  Puppet.initialize_settings_for_run_mode(:master)
  Puppet[:confdir] = "/etc/puppetlabs/puppet"
  config_structure = Puppet::Settings::ConfigFile.new(Puppet::Settings::ValueTranslator.new).parse_file(Puppet[:config], read_config(Puppet[:config]))
  if config_structure.is_a? Hash
    config_structure
  else
    config_structure.sections.keys.inject({}) do |memo,section|
      settings = config_structure.sections[section].settings.inject({}) do |m,x|
        m.merge!({ x.name => x.value })
      end
      memo.merge!({ section => settings })
    end
  end
end

def get_real_modulepath(config)
  preparse_modulepaths = Array.new
  preparse_basemodulepaths = Array.new
  preparse_modulepaths << config[:main][:modulepath].split(':') if config[:main][:modulepath]
  preparse_basemodulepaths << config[:main][:basemodulepath].split(':') if config[:main][:basemodulepath]
  if ! preparse_modulepaths.empty? and ! preparse_basemodulepaths.empty?
    puts "Upgrading to directory environments cannot continue; both $modulepath and $basemodulepath were discovered in puppet.conf. The upgrade can only proceed if one of them is present."
    raise Puppet::Error, "Upgrading to directory environments cannot continue; both $modulepath and $basemodulepath were discovered in puppet.conf. The upgrade can only proceed if one of them is present."
  end
  return (preparse_modulepaths + preparse_basemodulepaths).first
end

def remove_environment_prefix(environmentpath,path,environment_name=nil)
  if environment_name
    path.sub!(%r{^#{Regexp.escape(File.join(environmentpath,environment_name))}},".")
  end
  path.sub(%r{^#{Regexp.escape(File.join(environmentpath,"$environment"))}},".")
end
