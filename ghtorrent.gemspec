Gem::Specification.new do |s|
  s.name          = 'ghtorrent'
  s.version       = '0.12.1'
  s.date          = Time.now.strftime('%Y-%m-%d')
  s.summary       = 'Mirror and process Github data'
  s.description   = 'A library and a collection of associated programs to mirror and process Github data'
  s.authors       = ['Georgios Gousios', 'Diomidis Spinellis']
  s.email         = 'gousiosg@gmail.com'
  s.homepage      = 'https://github.com/gousiosg/github-mirror'
  s.licenses      = ['BSD-2-Clause']
  s.require_paths = ['lib']
  s.rdoc_options  = ['--charset=UTF-8']
  s.executables   = ['ght-retrieve-repo']
  s.files         = Dir.glob(['lib/**/*.rb', 'bin/*', '[A-Z]*', 'lib/ghtorrent/country_codes.txt'])
  s.required_ruby_version = '>= 2.5'

  s.add_runtime_dependency 'mongo', '~> 2.21.0'
  s.add_runtime_dependency 'sequel', '~> 5.76.0'
  s.add_runtime_dependency 'optimist', '~> 3.1.0'
  s.add_runtime_dependency 'bunny', '~> 2.22.0'

  s.add_development_dependency 'sqlite3', '~> 1.7.3'
  s.add_development_dependency 'influxdb', '~> 0.8.1'
end