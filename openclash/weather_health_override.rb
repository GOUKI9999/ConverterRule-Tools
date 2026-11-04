# Set the fields the INI converter cannot express. Called by OpenClash overwrite hook.
require 'yaml'

path = ARGV.fetch(0)
config = YAML.load_file(path)
group = Array(config['proxy-groups']).find { |item| item['type'] == 'fallback' && item['name'].end_with?('Fallback_Weather') }
if group
  group['url'] = 'https://clob.polymarket.com/?weather-health=1'
  group['expected-status'] = 200
  group['interval'] = 300
  group['timeout'] = 5000
  group['lazy'] = false
  temporary = path + '.weather-pending'
  File.write(temporary, config.to_yaml)
  File.chmod(File.stat(path).mode & 0777, temporary)
  File.rename(temporary, path)
  puts 'Weather API HEAD health configured: expected-status=200'
end
