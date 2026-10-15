import 'dart:ui';

import 'models.dart';
import 'techs/android_tech.dart';
import 'techs/dotnet_tech.dart';
import 'techs/flutter_tech.dart';
import 'techs/framework_tech.dart';
import 'techs/gradle_tech.dart';
import 'techs/java_tech.dart';
import 'techs/node_tech.dart';
import 'techs/python_tech.dart';
import 'techs/tech.dart';
import 'techs/xcode_tech.dart';

/// Every tech Stackyard knows about, in sidebar order.
///
/// Order matters for detection: Flutter runs before Android so Android can
/// read each project's Flutter SDK defaults (compileSdk, NDK).
List<TechAdapter> buildRegistry() => [
  FlutterTech(),
  NodeTech(),
  AndroidTech(),
  XcodeTech(),
  GradleTech(),
  JavaTech(),
  PythonTech(),
  DotnetTech(),
  FrameworkTech(package: 'react', name: 'React', color: const Color(0xFF58C4DC), monogram: 'R', logo: 'assets/tech/react.svg'),
  FrameworkTech(package: 'react-native', name: 'React Native', color: const Color(0xFF58C4DC), monogram: 'RN', logo: 'assets/tech/react.svg'),
  FrameworkTech(package: 'expo', name: 'Expo', color: const Color(0xFF4630EB), monogram: 'Ex', logo: 'assets/tech/expo.svg', logoTint: LogoTint.foreground),
  FrameworkTech(package: 'next', name: 'Next.js', color: const Color(0xFF6E6E6E), monogram: 'Nx', logo: 'assets/tech/next.svg', logoTint: LogoTint.foreground),
  FrameworkTech(package: 'vue', name: 'Vue', color: const Color(0xFF42B883), monogram: 'V', logo: 'assets/tech/vue.svg'),
  FrameworkTech(package: 'nuxt', name: 'Nuxt', color: const Color(0xFF00DC82), monogram: 'Nu', logo: 'assets/tech/nuxt.svg', logoTint: LogoTint.brand),
  FrameworkTech(package: '@angular/core', name: 'Angular', color: const Color(0xFFDD0031), monogram: 'Ng', logo: 'assets/tech/angular.svg'),
  FrameworkTech(package: 'svelte', name: 'Svelte', color: const Color(0xFFFF3E00), monogram: 'S', logo: 'assets/tech/svelte.svg'),
  FrameworkTech(package: 'astro', name: 'Astro', color: const Color(0xFFBC52EE), monogram: 'As', logo: 'assets/tech/astro.svg', logoTint: LogoTint.foreground),
  FrameworkTech(package: 'electron', name: 'Electron', color: const Color(0xFF47848F), monogram: 'El', logo: 'assets/tech/electron.svg'),
  FrameworkTech(package: 'vite', name: 'Vite', color: const Color(0xFF646CFF), monogram: 'Vi', logo: 'assets/tech/vite.svg'),
  FrameworkTech(package: 'typescript', name: 'TypeScript', color: const Color(0xFF3178C6), monogram: 'TS', logo: 'assets/tech/typescript.svg'),
];
