#==========================================================
# Copyright @ 2015 Puppet Labs, LLC
# Redistribution prohibited.
# Address: 308 SW 2nd Ave., 5th Floor Portland, OR 97204
# Phone: (877) 575-9775
# Email: info@puppetlabs.com
#
# Please refer to the LICENSE.pdf file included
# with the Puppet Enterprise distribution
# for licensing information.
#==========================================================

#===[ Summary ]============================================
# This ruby script uses Puppet and Augeas to update
# Puppet Enterprise's puppet.conf configuration file
# for Puppet 4.  It also migrates
#
#  * environments (/etc/puppetlabs/puppet/environments)
#  * user base modules (/etc/puppetlabs/puppet/modules)
#  * hiera config (/etc/puppetlabs/puppet/hiera.yaml)
#  * hieradata (/etc/puppetlabs/puppet/hieradata)
#
# to the new Puppet $codedir: /etc/puppetlabs/code
#==========================================================

module CodeDirMigration
  def self.debug=(value)
    @debug = value
  end

  def self.debug
    @debug
  end

  def self.update_hiera_config=(value)
    @update_hiera_config = value
  end

  def self.update_hiera_config
    @update_hiera_config
  end

  # Modify puppet.conf to remove or update settings based on unified layout
  # (https://github.com/puppetlabs/puppet-specifications/blob/master/file_paths.md)
  #
  # A different auges_root can be specified to assist with testing.
  def self.upgrade_puppet_conf(augeas_root = '/')
    puppet_conf = PuppetConf.new(augeas_root)
    puppet_conf.remove_deleted_settings
    puppet_conf.remove_old_default_settings
    puppet_conf.update_settings
    puppet_conf.write_changes_to_puppet_conf
  end

  def self.migrate_code(hiera_path=nil)
    hiera_yaml = HieraYaml.new(hiera_path)
    @update_hiera_config = hiera_yaml.needs_to_be_updated?
    return unless @update_hiera_config
    hiera_yaml.update_settings
    hiera_yaml.write_to_hiera_yaml
  end

  class HieraYaml

    @@OLD_HIERA_DATADIR = '/var/lib/hiera'
    @@HIERA_YAML_UPDATE_PATH = '/etc/puppetlabs/code/hiera.yaml'
    @@OLD_HIERA_YAML_PATH = ENV['HIERA_YAML_BACKUP'] || '/etc/puppetlabs/puppet/hiera.yaml'
    @@SAFE_BACKENDS = ['yaml', 'json', 'puppet']

    attr_accessor :the_config
    attr_reader :original_config

    def initialize(hiera_yaml_path=nil)
      if hiera_yaml_path == nil
        hiera_yaml_path = @@OLD_HIERA_YAML_PATH
      end
      @original_config = _load_hiera_yaml_as_hash(hiera_yaml_path)
      self.the_config = _load_hiera_yaml_as_hash(hiera_yaml_path)
    end

    def _load_hiera_yaml_as_hash(path)
      YAML.load_file(path)
    end

    def config
      self.the_config
    end

    def update_settings
      return unless needs_to_be_updated?

      self.the_config[:backends].each { |backend|
        if (!self.the_config.include?(backend.to_sym) ||
            (self.the_config[backend.to_sym].include?(:datadir) &&
             self.the_config[backend.to_sym][:datadir] == nil)) &&
          @@SAFE_BACKENDS.include?(backend)
          self.the_config[backend.to_sym] = {
            :datadir => @@OLD_HIERA_DATADIR
          }
        end
      }
    end

    def write_to_hiera_yaml
      return unless needs_to_be_updated?

      STDOUT.puts("## Writing hiera.yaml to #{@@HIERA_YAML_UPDATE_PATH}")
      File.open(@@HIERA_YAML_UPDATE_PATH, 'w') { |f| f.write(self.the_config.to_yaml()) }
    end

    def needs_to_be_updated?
      any_datadir_set = @original_config[:backends].any? do |bend|
        backend = bend.to_sym
        @original_config.has_key?(backend) && @original_config[backend].has_key?(:datadir) && ! @original_config[backend][:datadir].nil?
      end

      any_datadir_set || default_datadir_non_empty?
    end

    def default_datadir_non_empty?
      Dir.exist?(@@OLD_HIERA_DATADIR) && !(Dir.glob("#{@@OLD_HIERA_DATADIR}/*") ).empty?
    end
  end

  class PuppetConf
    require 'puppet'

    # These are parameters in the default PE 3.8 puppet.conf which can
    # be deleted if they still have these default values
    DEFAULT_38_VALUES = {
      :main => {
        :vardir          => "/var/opt/lib/pe-puppet",
        :logdir          => "/var/log/pe-puppet",
        :rundir          => "/var/run/pe-puppet",
      },
      :agent => {
        :report      => true,
        :pluginsync  => true,
      },
    }.freeze

    # These settings are no longer present in Puppet 4
    # This list was taken from
    # https://github.com/puppetlabs/puppetlabs-puppet_agent/blob/6cc5cabd0f357525f8d46e25e4a2f1f2d2a12695/manifests/prepare.pp#L35-L42
    DELETED_SETTINGS = [
      :allow_variables_with_dashes,
      :async_storeconfigs,
      :binder,
      :catalog_format,
      :certdnsnames,
      :certificate_expire_warning,
      :couchdb_url,
      :dbadapter,
      :dbconnections,
      :dblocation,
      :dbmigrate,
      :dbname,
      :dbpassword,
      :dbport,
      :dbserver,
      :dbsocket,
      :dbuser,
      :dynamicfacts,
      :http_compression,
      :httplog,
      :ignoreimport,
      :immutable_node_data,
      :inventory_port,
      :inventory_server,
      :inventory_terminus,
      :legacy_query_parameter_serialization,
      :listen,
      :localconfig,
      :manifestdir,
      :masterlog ,
      :parser,
      :preview_outputdir,
      :puppetport,
      :queue_source,
      :queue_type,
      :rails_loglevel,
      :railslog,
      :report_serialization_format,
      :reportfrom,
      :rrddir,
      :rrdinterval,
      :sendmail,
      :smtphelo,
      :smtpport,
      :smtpserver,
      :stringify_facts,
      :tagmap,
      :templatedir,
      :thin_storeconfigs,
      :trusted_node_data,
      :zlib,
    ].freeze

    PUPPET_CONF_PATH = '/etc/puppetlabs/puppet/puppet.conf'

    attr_accessor :puppet_conf_path, :augeas_root, :the_config

    def initialize(augeas_root = '/')
      self.augeas_root = augeas_root
      self.puppet_conf_path = augeas_root == '/' ?
        PUPPET_CONF_PATH :
        "#{augeas_root}#{PUPPET_CONF_PATH}"
      @original_config = _get_puppet_conf_as_hash(puppet_conf_path)
      self.the_config = _get_puppet_conf_as_hash(puppet_conf_path)
    end

    # Remove any setting the matches an entry in DELETED_SETTINGS (settings
    # which have been dropped in Puppet 4).
    def remove_deleted_settings
      the_config.values.each do |parameters|
        parameters.reject! { |key,value| DELETED_SETTINGS.include?(key) }
      end
      the_config
    end

    # Remove any setting if it matches one of the DEFAULT_38_VALUES parameter
    # keys, and its value is still the default value from the PE 3.8
    # puppet.conf
    def remove_old_default_settings
      the_config.values.each do |parameters|
        parameters.reject! do |key,value|
          _default_38_parameters.keys.include?(key) &&
            _default_38_parameters[key] == value
        end
      end
      the_config
    end

    # Update basemodulepath and reports parameters.
    #
    # NOTE: should be run /after/ remove_old_default_settings to avoid updating
    # a default basemodulepath pointlessly
    def update_settings
      if has_key?(:main, :basemodulepath)
        the_config[:main][:basemodulepath] = _transform_basemodulepath(the_config[:main][:basemodulepath])
      end

      if has_key?(:master, :basemodulepath)
        the_config[:master][:basemodulepath] = _transform_basemodulepath(the_config[:master][:basemodulepath])
      end

      if has_key?(:main, :reports)
        the_config[:main][:reports] = _transform_reports(the_config[:main][:reports])
      end

      if has_key?(:master, :reports)
        the_config[:master][:reports] = _transform_reports(the_config[:master][:reports])
      end

      the_config
    end

    def has_key?(section, parameter)
      the_config.keys.include?(section) && the_config[section].keys.include?(parameter)
    end

    def write_changes_to_puppet_conf(root = self.augeas_root)
      require 'augeas'
      Augeas.open(root) do |aug|
        conf = "/files/etc/puppetlabs/puppet/puppet.conf"
        @original_config.each do |section,parameters|
          parameters.each do |param,original_value|
            current_value = the_config[section][param]
            case
            when current_value.nil?
              if CodeDirMigration.debug
                STDOUT.puts("## Removing [#{section}] #{param}")
              end
              aug.rm("#{conf}/#{section}/#{param}")
            when original_value != current_value
              if CodeDirMigration.debug
                STDOUT.puts("## Setting [#{section}] #{param} to '#{current_value}'")
              end
              aug.set("#{conf}/#{section}/#{param}", current_value)
            end
          end
        end
        unless aug.save
          message = "Failed to upgrade puppet.conf settings at /etc/puppetlabs/puppet/puppet.conf"
          STDERR.puts "!! #{message}"
          exit 1
        end
      end
    end

    private

    def _transform_basemodulepath(basemodulepath)
      basemodulepath = basemodulepath.split(':')
      basemodulepath.map! do |dir|
        case dir.strip
        when '/opt/puppet/share/puppet/modules' then '/opt/puppetlabs/puppet/modules'
        else dir
        end
      end
      basemodulepath.join(':')
    end

    def _transform_reports(reports)
      reports = reports.split(',')
      reports.reject! { |r| r.strip == 'console' }
      reports.join(',')
    end

    def _default_38_parameters
      DEFAULT_38_VALUES.values.inject({}) { |hash,h| hash.merge(h) }
    end

    def _get_puppet_conf_as_hash(path)
      config_structure = Puppet.settings.parse_file(path)
      config_structure.sections.keys.inject({}) do |memo,section|
        settings = config_structure.sections[section].settings.inject({}) do |m,x|
          m.merge!({ x.name => x.value })
        end
        memo.merge!({ section => settings })
      end
    end
  end

end

# The script may be called with a single arguement for debug output.
# If `ruby pe-code-migration.rb -D` is called, then debug output will
# be submitted on STDOUT.
if __FILE__ == $0
  CodeDirMigration.debug = true if ARGV[0] == '-D'
  CodeDirMigration.upgrade_puppet_conf
  CodeDirMigration.migrate_code
  exit 0
end
