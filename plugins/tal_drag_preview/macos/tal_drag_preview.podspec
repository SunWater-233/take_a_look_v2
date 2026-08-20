Pod::Spec.new do |s|
  s.name             = 'tal_drag_preview'
  s.version          = '0.1.0'
  s.summary          = 'Click-through support for Take A Look drag previews.'
  s.description      = 'A private Flutter desktop plugin.'
  s.homepage         = 'https://example.invalid'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Take A Look' => 'dev@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
