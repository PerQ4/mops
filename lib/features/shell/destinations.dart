import 'package:flutter/material.dart';

/// Разделы верхнего уровня.
///
/// Вынесены в отдельный файл, чтобы и оболочка, и остров навигации
/// пользовались одним списком без циклических импортов.
enum ShellDestination {
  home('Главная', Icons.home_outlined, Icons.home),
  explore('Обзор', Icons.explore_outlined, Icons.explore),
  search('Поиск', Icons.search_outlined, Icons.search),
  library('Библиотека', Icons.library_music_outlined, Icons.library_music);

  const ShellDestination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
