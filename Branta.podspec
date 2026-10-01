Pod::Spec.new do |s|
  s.name         = 'Branta'
  s.version      = '3.2.2'
  s.summary      = 'Swift SDK for the Branta V2 API'
  s.description  = 'Payment destination lookup and registration with zero-knowledge encryption. For native iOS and macOS apps.'
  s.homepage     = 'https://branta.pro'
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.author       = { 'Branta' => 'support@branta.pro' }
  s.source       = { :git => 'https://github.com/BrantaOps/branta-swift.git', :tag => "v#{s.version}" }
  s.source_files = 'Sources/Branta/**/*.swift'
  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.swift_version = '5.9'
end
