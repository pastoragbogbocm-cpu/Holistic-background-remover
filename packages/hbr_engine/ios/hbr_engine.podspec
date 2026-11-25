Pod::Spec.new do |s|
  s.name             = 'hbr_engine'
  s.version          = '0.1.0'
  s.summary          = 'On-device video background removal engine.'
  s.description      = 'Person segmentation (Vision), full-resolution matte refinement and source-quality export, fully offline.'
  s.homepage         = 'https://example.com/holistic-background-remover'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Holistic' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'hbr_engine/Sources/hbr_engine/**/*.swift',
                       'hbr_engine/Sources/HbrCore/**/*.{h,cpp}'
  s.public_header_files = 'hbr_engine/Sources/HbrCore/include/hbr/*.h'
  s.header_mappings_dir = 'hbr_engine/Sources/HbrCore/include'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.frameworks = 'AVFoundation', 'Vision', 'CoreImage', 'CoreVideo', 'CoreMedia', 'Accelerate'
  s.library = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_OPTIMIZATION_LEVEL' => '3',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/hbr_engine/Sources/HbrCore/include"'
  }
  s.swift_version = '5.9'
  s.resource_bundles = {'hbr_engine_privacy' => ['hbr_engine/Sources/hbr_engine/PrivacyInfo.xcprivacy']}
end
