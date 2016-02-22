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
# This ruby script updates the superuser password in RBAC
# to be what is set during the installer interview.
#==========================================================

#===[ Functions ]==========================================

require 'json'
require 'net/https'

RBAC_HOSTNAME = ENV['q_puppetagent_certname']
SERVER_DATA_DIR = '/opt/puppetlabs/server/data'
CONSOLE_CERT_DIR = "#{SERVER_DATA_DIR}/console-services/certs"

CONF = {
  'rbac_api_url' => "https://#{RBAC_HOSTNAME}:4433",
  'ca_cert_file' => '/etc/puppetlabs/puppet/ssl/certs/ca.pem',
  'host_private_key_file' => "#{CONSOLE_CERT_DIR}/#{RBAC_HOSTNAME}.private_key.pem",
  'host_cert_file' => "#{CONSOLE_CERT_DIR}/#{RBAC_HOSTNAME}.cert.pem",
  'rbac_url_prefix' => '/rbac-api/v1',
}

def build_auth(uri)
  https = Net::HTTP.new(uri.host, uri.port)
  https.use_ssl = true
  https.ca_file = CONF['ca_cert_file']
  https.key = OpenSSL::PKey::RSA.new(File.read(CONF['host_private_key_file']))
  https.cert = OpenSSL::X509::Certificate.new(File.read(CONF['host_cert_file']))
  https.verify_mode = OpenSSL::SSL::VERIFY_PEER
  https
end

def get_response(endpoint)
  uri = URI.parse("#{CONF['rbac_api_url']}#{CONF['rbac_url_prefix']}#{endpoint}")
  https = build_auth(uri)

  request = Net::HTTP::Get.new(uri.request_uri)
  request['Content-Type'] = "application/json"
  res = https.request(request)

  case res
  when Net::HTTPSuccess then
    res
  else
    puts "!!! WARNING: An error occured getting a response from RBAC: HTTP #{res.code}, #{res.to_hash.inspect}"
    exit 1
  end
end

def post_response(endpoint, request_body)
  uri = URI.parse("#{CONF['rbac_api_url']}#{CONF['rbac_url_prefix']}#{endpoint}")
  https = build_auth(uri)

  request = Net::HTTP::Post.new(uri.request_uri)
  request['Content-Type'] = "application/json"

  unless request_body.nil?
    request.body = request_body.to_json
  end

  res = https.request(request)
  case res
  when Net::HTTPSuccess then
    res
  else
    puts "!!! WARNING: An error occured posting a response from RBAC: HTTP #{res.code}, #{res.to_hash.inspect}"
    exit 1
  end
end

def reset_password(user, new_password)
  reset_token_res = post_response("/users/#{user['id']}/password/reset", nil)
  reset_token = reset_token_res.body

  reset_body = {
    'token' => reset_token,
    'password' => new_password,
  }

  reset_password_res = post_response('/auth/reset', reset_body)
end

def get_user(user_name)
  user_list_res = get_response('/users')
  user_list = JSON.parse(user_list_res.body)
  user = user_list.find { |user| user['login'] == user_name }
  user
end

def main
  admin_password = ENV['q_puppet_enterpriseconsole_auth_password']
  admin_user = get_user('admin')
  reset_password(admin_user, admin_password)
end

main
