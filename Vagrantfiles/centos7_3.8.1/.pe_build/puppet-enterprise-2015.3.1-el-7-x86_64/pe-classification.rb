#==========================================================
# Copyright @ 2014 Puppet Labs, LLC
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
# This ruby script uses the Node Classifier to classify
# Puppet Enterprise.
#==========================================================

#===[ Functions ]==========================================

require 'json'
require 'net/https'
require 'uri'

class HTTPException < RuntimeError
  attr_reader :response

  def initialize(verb, uri, body, response)
    error = "An error has occured while attempting #{verb} to #{uri}."
    if body
      error += "#{verb} request body was: #{body}"
    end
    error += "#{verb} response was: HTTP #{response.code}, #{response.body}"

    @verb = verb
    @uri = uri
    @body = body
    @response = response

    super(error)
  end
end

class PEClassifier

  DEFAULT_NC_GROUP = '00000000-0000-4000-8000-000000000000'

  def missing_required_env(env)
    required_env = [
      'q_puppetagent_server',
      'q_puppetdb_hostname',
      'q_puppetdb_port',
      'q_puppetagent_certname',
      't_console_hostname',
      'q_puppet_enterpriseconsole_httpd_port',
      'q_puppetdb_database_name',
      'q_puppetdb_database_user',
      'q_database_host',
      'q_database_port',
    ]

    required_env.select { |var| ! env.member?(var) || ! env[var] || env[var].strip == '' }
  end

  def initialize(env)
    missing_env = missing_required_env(env)
    unless missing_env.count == 0
      raise ArgumentError.new("Missing required environment variables #{missing_env.join(', ')}")
    end

    @master = env['q_puppetagent_server'] # master
    @puppetdb = env['q_puppetdb_hostname'] # puppetdb
    @puppetdb_port = env['q_puppetdb_port'] # puppetdb_port
    @puppetdb_database_name= env['q_puppetdb_database_name']
    @puppetdb_database_user= env['q_puppetdb_database_user']
    @console = env['t_console_hostname'] # console
    @console_port = env['q_puppet_enterpriseconsole_httpd_port'] # console_port
    @database_install = env['q_database_install'] == 'y'
    @database = env['q_database_host'] # database
    @database_port = env['q_database_port'] # database_port
    @r10k_remote = env['q_puppetmaster_r10k_remote'] # r10k remote
    @r10k_private_key = env['q_puppetmaster_r10k_private_key'] # r10k private key
    @file_sync_enabled = env['q_puppetmaster_file_sync_service_enabled'] == 'y'
    @code_manager_auto_configure = env['q_puppetmaster_code_manager_auto_configure'] == "y"
    @platform_puppet_class = env['t_platform_puppet_class']
    @is_upgrade = env['IS_UPGRADE'] == 'y'
    @tarball_server = env['q_tarball_server']
    @ca_cert_file = '/etc/puppetlabs/puppet/ssl/certs/ca.pem'
    @server_data_dir = '/opt/puppetlabs/server/data'
    @console_cert_dir = "#{@server_data_dir}/console-services/certs"
    @host_private_key_file = "#{@console_cert_dir}/#{env['q_puppetagent_certname']}.private_key.pem"
    @host_cert_file = "#{@console_cert_dir}/#{env['q_puppetagent_certname']}.cert.pem"
    @nc_api_url = "https://#{@console}:4433/classifier-api"
    @nc_groups_uri = URI.parse("#{@nc_api_url}/v1/groups")
    @use_application_services = env['q_use_application_services'] == 'y'
    @use_legacy_auth_conf = env['q_migrate_auth_conf_after_upgrade'] == 'n'
    @classification_attempts = env['q_classification_attempts'] ? Integer(env['q_classification_attempts']) : 150

    @CURRENT_PE_MAJOR = env['CURRENT_PE_MAJOR']
    @CURRENT_PE_MINOR = env['CURRENT_PE_MINOR']
    # Define the groups that PE uses to manage itself (order of array matters,
    # and is used later to determine deletion order)
    @pe_group_names = [
      'PE ActiveMQ Broker',
      'PE Certificate Authority',
      'PE Console',
      'PE Master',
      'PE Orchestrator',
      'PE MCollective',
      'PE PuppetDB',
      'PE Infrastructure',
      'PE Agent',
    ]
  end

  def pe_group_names
    @pe_group_names
  end

  def pe_group_cache
    @pe_group_cache ||= get_groups_by_names(@pe_group_names)
  end

  def build_auth(uri)
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    https.ca_file =  @ca_cert_file
    https.key = OpenSSL::PKey::RSA.new(File.read(@host_private_key_file))
    https.cert = OpenSSL::X509::Certificate.new(File.read(@host_cert_file))
    https.verify_mode = OpenSSL::SSL::VERIFY_PEER
    https
  end

  def http_request(verb, uri, body=nil)
    https = build_auth(uri)

    case verb
    when :PUT
      request = Net::HTTP::Put.new(uri.request_uri)
    when :POST
      request = Net::HTTP::Post.new(uri.request_uri)
    when :GET
      request = Net::HTTP::Get.new(uri.request_uri)
    when :DELETE
      request = Net::HTTP::Delete.new(uri.request_uri)
    else
      $stderr.puts caller
      $stderr.puts "Unknown HTTP verb: #{verb}."
    end

    if body
      request.body = body
    end

    # This is required to send data to NC
    request["Content-Type"] = "application/json"

    response = https.request(request)
    if response.code.to_i >= 400
      raise HTTPException.new(verb, uri, body, response)
    end

    response
  end

  def configure_pe_repo
    @master_group['classes'].merge!('pe_repo' => {})
    @master_group['classes'].merge!("pe_repo::platform::#{@platform_puppet_class}" => {})

    # If they've set a tarball server (via answer file if this is split
    # install), use it. Otherwise leave it unset to use the default.
    if @tarball_server
      @master_group['classes']['pe_repo'].merge!('base_path' => @tarball_server)
    end
  end

  def add_license
    @console_group['classes'].merge!('puppet_enterprise::license' => {})
  end

  def add_broker
    @brokers_group['classes'].merge!("puppet_enterprise::profile::amq::broker" => {})
  end

  # High level function classifies both the console and master with the appropriate mcollective profiles
  # so that they can be set up correctly.
  def add_mcollective
    @master_group['classes'].merge!("puppet_enterprise::profile::master::mcollective" => {})
    @master_group['classes'].merge!("puppet_enterprise::profile::mcollective::peadmin" => {})
  end

  def add_console_prune
    @console_group['classes'].merge!('pe_console_prune' => {'prune_upto' => '30'})
  end

  def add_ca
    @ca_group['classes'].merge!("puppet_enterprise::profile::certificate_authority" => {})
  end

  def add_master
    profile_master = {}
    profile_master.merge!("r10k_remote"      => @r10k_remote)      if @r10k_remote
    profile_master.merge!("r10k_private_key" => @r10k_private_key) if @r10k_private_key
    profile_master.merge!("file_sync_enabled" => @file_sync_enabled) if !@file_sync_enabled
    profile_master.merge!('code_manager_auto_configure' => @code_manager_auto_configure) if @code_manager_auto_configure
    @master_group['classes'].merge!("puppet_enterprise::profile::master" => profile_master)
  end

  def add_orchestrator
    @orchestrator_group['classes'].merge!("puppet_enterprise::profile::orchestrator" => {})
  end

  def add_puppetdb
    profile_puppetdb = {}
    profile_puppetdb['database_properties'] = '' if ! @database_install
    @puppetdb_group['classes'].merge!("puppet_enterprise::profile::puppetdb" => {})
  end

  def add_console
    @console_group['classes'].merge!("puppet_enterprise::profile::console" => {})
  end

  def post_group(group)
    response = http_request(:POST, @nc_groups_uri, group.to_json)
    # Return the uuid from redirect "/classifier-api/v1/groups/474a7cea-8b32-4990-b65b-1f841d030fcc"
    response['location'].split("/")[-1]
  end

  def update_group(group)
    response = http_request(:POST, URI.parse("#{@nc_api_url}/v1/groups/#{group['id']}"), group.to_json)
    response
  end

  def put_group(group)
    response = http_request(:PUT, URI.parse("#{@nc_api_url}/v1/groups/#{group['id']}"), group.to_json)
    response
  end

  def get_groups()
    response = http_request(:GET, @nc_groups_uri)

    JSON.parse(response.body) || []
  end

  def get_groups_by_names(group_names)
    get_groups.select { |group| group_names.include?(group['name']) }
  end

  def get_group_by_name(group_name)
    groups = get_groups_by_names([group_name])
    if groups.size > 1
      puts "WARNING: Multiple groups named #{group_name} found. The first match will be used."
    end

    groups.first
  end

  def group_exists?(group_name)
    @groups_cache.any? { |group| group['name'] == group_name }
  end

  def find_groups_with_classes(groups)
    groups.select { |group| group['classes'].keys.count > 0 }
  end

  def get_class(environment, class_name)
    class_uri = "#{@nc_api_url}/v1/environments/#{environment}/classes/#{class_name}"
    response = http_request(:GET, URI.parse(class_uri))

    response.body
  end

  def ensure_classes_synced
    pe_class = JSON.parse(get_class('production', 'puppet_enterprise'))
    attempts = 0

    until pe_class['parameters'].key?('pcp_broker_host') || attempts >= @classification_attempts do
      attempts += 1
      $stderr.puts "puppet_enterprise class does not include pcp_broker_host."
      $stderr.puts "Attempting to update classification (Attempt #{attempts} of #{@classification_attempts})."

      uri = "#{@nc_api_url}/v1/update-classes"
      begin
        response = http_request(:POST, URI.parse(uri))

        if response.code.to_i != 201
          raise HTTPException.new(:POST, uri, nil, response)
        end
      rescue HTTPException => e
        error_msg = JSON.parse(e.response.body)['msg']
        if e.response.is_a?(Net::HTTPInternalServerError) && error_msg =~ /could not obtain lock on relation/
          $stderr.puts "Assuming a class update is in progress. Another attempt will be made. Error from NC for debugging:"
          $stderr.puts e
        else
          raise e
        end
      # Workaround for PE-10214
      rescue Net::ReadTimeout => e
        $stderr.puts "Class update request timed out after 60 seconds. We're assuming there is a large amount of class data and will continue to retry..."
      ensure
        sleep 10
      end

      pe_class = JSON.parse(get_class('production', 'puppet_enterprise'))
    end
  end

  def delete_groups(group_ids)
    group_ids.each do |group_id|
      uri = URI.parse("#{@nc_api_url}/v1/groups/#{group_id}")
      response = http_request(:DELETE, uri)

      if response.code.to_i != 204
        raise HTTPException.new(:DELETE, uri, nil, response)
      end
    end
  end

  def merge_parent(group,uuid)
      group.merge!({'parent' => uuid })
  end

  def create_groups
    # make master group
    @master_group = {
      'name'    => "PE Master",
      'classes' => {},
    }

    # only pin node on install
    if ! @is_upgrade
      @master_group['rule'] = ["or", ["=", "name", @master]]
    end

    # make orchestrator group
    @orchestrator_group = {
      'name'    => "PE Orchestrator",
      'classes' => {},
    }

    # only pin node on install
    if ! @is_upgrade
      @orchestrator_group['rule'] = ["or", ["=", "name", @master]]
    end

    # make puppetdb group
    @puppetdb_group = {
      'name'    => "PE PuppetDB",
      'classes' => {},
    }

    # only pin node on install
    if ! @is_upgrade
      @puppetdb_group['rule'] = ["or", ["=", "name", @puppetdb]]
    end

    # make console group
    @console_group = {
      'name'    => "PE Console",
      'classes' => {},
    }

    # only pin node on install
    if ! @is_upgrade
      @console_group['rule'] = ["or", ["=", "name", @console]]
    end

    @brokers_group = {
      'name'    => "PE ActiveMQ Broker",
      'classes' => {},
    }

    # only pin node on install
    if ! @is_upgrade
      @brokers_group['rule'] = ["or", ["=", "name", @master]]
    end

    @ca_group = {
      'name'    => "PE Certificate Authority",
      'classes' => {},
    }

    # only pin node on install
    if ! @is_upgrade
      @ca_group['rule'] = ["or", ["=", "name", @master]]
    end
  end

  def create_environment_groups
    # make production environment group
    @production_environment_group = {
      'name'               => "Production environment",
      'parent'             => DEFAULT_NC_GROUP,
      'environment'        => 'production',
      'environment_trumps' => true,
      'classes'            => {},
      'rule'               => ["and", ["~", "name", '.*']],
    }
    @agentspecified_environment_group = {
      'name'               => "Agent-specified environment",
      'environment'        => 'agent-specified',
      'environment_trumps' => true,
      'classes'            => {},
    }
  end

  def create_infrastructure
    # make infrastructure group
    @infrastructure_group = {
      'name'    => "PE Infrastructure",
      'parent'  => DEFAULT_NC_GROUP,
      'classes' => {},
    }

    @infrastructure_group['classes'].merge!("puppet_enterprise" => {
    'certificate_authority_host'   => @master,
    'puppet_master_host'           => @master,
    'console_host'                 => @console,
    'console_port'                 => @console_port,
    'puppetdb_host'                => @puppetdb,
    'puppetdb_port'                => @puppetdb_port,
    'puppetdb_database_name'       => @puppetdb_database_name,
    'puppetdb_database_user'       => @puppetdb_database_user,
    'database_host'                => @database,
    'database_port'                => @database_port,
    'mcollective_middleware_hosts' => [@master],
    'pcp_broker_host'              => @master,
    'database_ssl'                 => @database_install || @puppetdb == @database,
    'use_application_services'     => @use_application_services,
    })
  end

  def create_mcollective
    # make mcollective group

    # This rule is specific because the is_pe fact is not correctly
    # being used by the classifier. This rule is basically the same
    # thing. If pe_version is empty, then it isn't PE.
    @mcollective_group = {
      'name'    => "PE MCollective",
      'classes' => {"puppet_enterprise::profile::mcollective::agent" => {}},
    }

    # always pin MCO
    @mcollective_group['rule'] = ["and",["~",["fact","aio_agent_version"],".+"]]
  end

  def create_agent
    @agent_group = {
      'name'    => "PE Agent",
      'rule'    => ["and",["~",["fact","aio_agent_version"],".+"]], # always pinning agents
      'classes' => {"puppet_enterprise::profile::agent" => {}},
    }
  end

  def save_groups
    # Create the PE Infrastructure group
    parent = post_group(@infrastructure_group)

    # Create the children of the PE Infrastructure group
    [
     @master_group,
     @orchestrator_group,
     @puppetdb_group,
     @console_group,
     @mcollective_group,
     @brokers_group,
     @ca_group,
    ].each do |child|
      group = merge_parent(child,parent)
      post_group group
    end

  end

  def save_agent_group
    # This is dependent on the infrastructure being already
    # written. This kind of hidden dependency makes me want
    # to rework this script to pass more of these data structures
    # around instead of using instance variables.
    parent = get_groups_by_names(['PE Infrastructure'])

    if parent.size == 1
      @agent_group['parent'] = parent[0]['id']

      post_group @agent_group
    else
      $stderr.puts caller
      $stderr.puts "ERROR: We could not classify the PE Agent group."
      exit 1
    end
  end

  def save_environment_groups
    # Create the production environment group
    parent = post_group(@production_environment_group)

    # Create the children of the production environment group
    [
      @agentspecified_environment_group,
    ].each do |child|
      group = merge_parent(child, parent)
      post_group group
    end
  end

  def matching_group_and_classes_in?(name, classes)
    pe_group_cache.one? do |group|
      group['name'] == name &&
      classes.all? { |c| group['classes'].include? c }
    end
  end

  def correct_pe_groups?
    groups_to_check = [
      matching_group_and_classes_in?('PE ActiveMQ Broker', ['puppet_enterprise::profile::amq::broker']),
      matching_group_and_classes_in?('PE Certificate Authority', ['puppet_enterprise::profile::certificate_authority']),
      matching_group_and_classes_in?('PE Console', ['puppet_enterprise::profile::console', 'puppet_enterprise::license']),
      matching_group_and_classes_in?('PE Master', ['puppet_enterprise::profile::master', 'puppet_enterprise::profile::master::mcollective', 'puppet_enterprise::profile::mcollective::peadmin']),
      matching_group_and_classes_in?('PE MCollective', ['puppet_enterprise::profile::mcollective::agent']),
      matching_group_and_classes_in?('PE PuppetDB', ['puppet_enterprise::profile::puppetdb']),
      matching_group_and_classes_in?('PE Infrastructure', ['puppet_enterprise']),
      matching_group_and_classes_in?('PE Agent', ['puppet_enterprise::profile::agent']),
    ]
    if ! @CURRENT_PE_MAJOR.nil? and ! @CURRENT_PE_MINOR.nil?
      if @CURRENT_PE_MAJOR.to_i >= 2015 and @CURRENT_PE_MINOR.to_i >= 3
        groups_to_check.push matching_group_and_classes_in?('PE Orchestrator', ['puppet_enterprise::profile::orchestrator'])
      end
    end
    groups_to_check.all?
  end

  def delete_empty_groups
    # If true, either we successfully deleted the empty groups, or there was
    # nothing to delete.
    # If false, we were unable to delete groups because they were not empty.
    successful = true

    if pe_group_cache.count > 0
      unsafe_groups = find_groups_with_classes(pe_group_cache)

      # The PE MCollective group is configured with a rule by default
      # So we'll remove it if we're confident it's the group we setup
      # during previous install.
      unsafe_groups = unsafe_groups.reject { |group|
        group['name'] == "PE MCollective" &&
        group['classes'].include?("puppet_enterprise::profile::mcollective::agent") &&
        group['rule'] = ["and",["~",["fact","pe_version"],".+"]]
      }

      if unsafe_groups.count == 0
        # Delete the Infrastructure last (it's at the end of the group names),
        # as it is the parent class and I think the NC will have a bad time if
        # you delete a parent w/o deleting the children.
        group_ids_to_delete = []

        @pe_group_names.each do |name|
          group = pe_group_cache.find { |g| g['name'] == name }
          if group
            group_ids_to_delete << group['id']
          end
        end

        # No groups have classes, we should be safe deleting them
        delete_groups(group_ids_to_delete)
      else
        # here be user-defined dragons
        successful = false
      end
    end

    successful
  end

  # Classify PE
  def classify
    create_groups
    create_infrastructure
    create_mcollective

    # Add classes to groups, and pin nodes if we are doing a fresh install.
    add_broker
    add_mcollective
    add_ca
    add_master
    add_orchestrator
    add_puppetdb
    add_console

    # Add the pe_console_prune class to the puppet_console group but only on new
    # installs as we don't want to surprise the user by pruning the DB without
    # notice within a day after an upgrade.
    if ! @is_upgrade
      add_console_prune
    end

    if ! @is_upgrade
      create_environment_groups
      save_environment_groups
    end

    # Classify the console with the puppet_enterprise::license class, to sync
    # the license file from the master. This is necessary for proper
    # behavior of the license app, so we do it unconditionally.
    add_license

    # Classify the master with the pe_repo classes, only if this is a fresh
    # install. We won't enforce it on future upgrades because users may choose
    # to unclassify the master with these classes and we want to respect that.
    if ! @is_upgrade
      # Setup the frictionless agent install repo on the master
      configure_pe_repo
    end

    save_groups
  end

  def classify_agent
    create_agent
    save_agent_group
  end

  # Change the node group rules for the PE Agent and PE MCollective class if
  # the rule has not been modified. This ends up being something we need to
  # patch since the pe_version fact will only exist on PE Infrastructure nodes.
  # Since it only exists on those few nodes you lose the ability to manage
  # mcollective on every other node. This also replaces pe_version with
  # aio_version instead of appending because after an upgrade if your nodes are
  # running old agents then they will get the new classification and break.
  def patch_pe_version_fact_rule
    patch_agent_groups = pe_group_cache.select { |item|
      (item['name'] == "PE Agent" ||
       item['name'] == "PE MCollective") &&
      item['rule'] == ["and", ["~", ["fact", "pe_version"], ".+"]]
    }

    patch_agent_groups.each {|group|
      group['rule'] = ["and", ["~", ["fact", "aio_agent_version"], ".+"]]
      put_group group
    }
  end

  def nil_key_if_present(hash, key)
    if hash.include? key
      hash[key] = nil
    end

    hash
  end

  def add_key_if_absent(hash, key, val)
    unless hash.include? key
      hash[key] = val
    end

    hash
  end

  def add_missing_parameter_values
    infra = get_group_by_name('PE Infrastructure')
    master = get_group_by_name('PE Master')

    add_key_if_absent infra['classes']['puppet_enterprise'], 'pcp_broker_host', @master

    if @use_application_services
      add_key_if_absent infra['classes']['puppet_enterprise'], 'use_application_services', true
    end

    if @use_legacy_auth_conf
      add_key_if_absent master['classes']['puppet_enterprise::profile::master'], 'use_legacy_auth_conf', @use_legacy_auth_conf
    end

    if !@file_sync_enabled
      add_key_if_absent master['classes']['puppet_enterprise::profile::master'], 'file_sync_enabled', @file_sync_enabled
    end

    update_group infra
    update_group master
  end

  # Apply delta changes for params
  def remove_deprecated_parameters_and_classes
    console = get_group_by_name('PE Console')
    # PE-9882 Cleanup depreated MCO console class
    nil_key_if_present console['classes'], 'puppet_enterprise::profile::mcollective::console'
    # PE-12187 Cleanup deprecated console params
    [ 'disable_live_management',
      'dashboard_ssl_listen_port',
      'dashboard_listen_port',
      'dashboard_database_user',
      'dashboard_database_password',
      'dashboard_database_name' ].each do |key|
      nil_key_if_present console['classes']['puppet_enterprise::profile::console'], key
    end
    update_group console

    master = get_group_by_name('PE Master')
    [ 'enable_future_parser', 'metrics_enabled' ].each do |key|
      nil_key_if_present master['classes']['puppet_enterprise::profile::master'], key
    end
    update_group master
  end

  def patch_orchestrator
    infra = get_group_by_name('PE Infrastructure')

    orchestrator_group = {
      'name'    => "PE Orchestrator",
      'rule'    => ["or", ["=", "name", @master]],
      'classes' => {"puppet_enterprise::profile::orchestrator" => {}},
      'parent'  => infra['id']
    }

    post_group orchestrator_group
  end

  def run
    # We must ensure the classes are synced so that the classification we are
    # attempting to apply will match what the NC is expecting.
    ensure_classes_synced

    # Only attempt classification if the correct groups are not already present.
    if ! correct_pe_groups?
      # Attempt clearing any empty groups, but if any are found to have classes,
      # this will return false.
      if ! delete_empty_groups
        $stderr.puts caller
        $stderr.puts "ERROR: We could not classify your PE Infrastructure because #{pe_group_names.join(', ')} contain(s) configuration that we do not want to overwrite. For details about what classes and nodes these groups should contain, please refer to http://docs.puppetlabs.com/pe/3.8/console_classes_groups_preconfigured_groups.html"
        # exit now, don't touch anything
        exit 1
      end

      # At this point, we either have a fresh install, or we've cleared out
      # unconfigured groups from a 3.7 install. Either way, we can now classify
      # PE with no worries about conflicts.
      classify
    end

    if @is_upgrade
      # On upgrade, we need to add additional parameters to some classes
      # This must be done before attempting any additional operations on the
      # PE infrastructure because the classifier will not allow any changes
      # to be submitted while the classification has a missing parameter in it.
      add_missing_parameter_values

      # Now that we know the expected PE groups are present, we can do cleanup
      # of deprecated parameters and classes
      remove_deprecated_parameters_and_classes

      patch_pe_version_fact_rule

      # If we're upgrading, the classify method above will not add PE Orchestrator
      # node group, so it must be added here. We should really be putting all of
      # these classifications together in some sort of idempotent way without having
      # the terrifying delete_empty_groups/classify dance above and duplicating
      # most of the classify logic here.
      if @use_application_services && ! get_group_by_name('PE Orchestrator')
        patch_orchestrator
      end
    end

    if ! get_group_by_name('PE Agent')
      classify_agent
    end
  end
end

if __FILE__ == $0
  PEClassifier.new(ENV).run

  exit 0
end
