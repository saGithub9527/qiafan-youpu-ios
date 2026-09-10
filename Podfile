source 'https://cdn.cocoapods.org/'

platform :ios, '15.0'
project 'QiafanYoupu.xcodeproj'
install! 'cocoapods', :deterministic_uuids => true

target 'QiafanYoupu' do
  # Objective-C 布局；具体版本及传递依赖通过 Podfile.lock 固定。
  pod 'Masonry', '1.1.0'

  target 'QiafanYoupuTests' do
    inherit! :search_paths
  end
end

# 只提升依赖中低于本工程要求的 deployment target，不降低依赖自身的要求。
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
      if current.nil? || Gem::Version.new(current) < Gem::Version.new('15.0')
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      end
    end
  end
end
