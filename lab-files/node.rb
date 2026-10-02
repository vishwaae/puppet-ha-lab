#!/opt/puppetlabs/puppet/bin/ruby
# Puppet ENC: returns exactly what Foreman has for this host — the classes
# pinned on its hostgroup, its parameters, and its environment (dev/production).
# No class names live in this script. Scales to any number of nodes/classes.
require 'net/http'
require 'uri'
require 'json'
require 'yaml'

certname = ARGV[0]
foreman  = 'https://admin.puppetlab.com'
token    = File.read('/etc/puppetlabs/foreman_token').strip
ca_file  = '/etc/puppetlabs/puppet/ssl/certs/ca.pem'

enc = { 'classes' => {}, 'environment' => 'production' }
begin
  uri  = URI.parse("#{foreman}/api/hosts/#{certname}/enc")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.ca_file      = ca_file
  http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
  http.open_timeout = 5
  http.read_timeout = 10
  req = Net::HTTP::Get.new(uri.request_uri)
  req.basic_auth('admin', token)          # Foreman API = Basic auth, token as password
  res = http.request(req)
  if res.code.to_i == 200
    data = JSON.parse(res.body)
    data = data['data'] if data.is_a?(Hash) && data.key?('data')
    enc = data
  else
    STDERR.puts "node.rb: Foreman returned #{res.code} for #{certname}"
  end
rescue => e
  STDERR.puts "node.rb: Foreman lookup failed for #{certname}: #{e.class}: #{e.message}"
end

puts enc.to_yaml
exit 0
