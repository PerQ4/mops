import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Оформление экрана настроек — значения вынесены из исходников ArchiveTune,
/// ветка `main`, чтобы интерфейс совпадал с оригиналом до пикселя:
///
///  * `ui/screens/settings/SettingsDimensions.kt` — все размеры;
///  * `ui/screens/settings/SettingsComponents.kt` — `SettingsGroupCard`,
///    `SettingsRow`, `SettingsSectionLabel` (карточка-группа, строка, заголовок
///    раздела и разделитель между строками).
///
/// Почему отдельный файл: те же карточки и строки нужны и в подэкранах
/// настроек, поэтому держим их в одном месте, а не копируем разметку.
abstract final class SettingsDims {
  /// Радиус карточки-группы — `SettingsDimensions.GroupCardCornerRadius = 16.dp`.
  static const double groupCardCornerRadius = 16;

  /// Горизонтальный отступ карточки от края — `ScreenHorizontalPadding = 16.dp`.
  static const double screenHorizontalPadding = 16;

  /// Отступ между группами — `SectionSpacing = 14.dp`.
  static const double sectionSpacing = 14;

  /// Отступы строки — `RowVerticalPadding / RowHorizontalPadding = 14 / 16 dp`.
  static const double rowVerticalPadding = 14;
  static const double rowHorizontalPadding = 16;

  /// Кружок под иконку и размер иконки внутри него —
  /// `RowIconSize = 36.dp`, `RowIconInnerSize = 20.dp`.
  static const double rowIconSize = 36;
  static const double rowIconInnerSize = 20;

  /// Шеврон справа — `ChevronSize = 18.dp`.
  static const double chevronSize = 18;

  /// Разделитель строк — `DividerThickness = 0.5.dp`,
  /// `DividerStartIndent = 60.dp` (под текстом, а не под иконкой).
  static const double dividerThickness = 0.5;
  static const double dividerStartIndent = 60;

  /// Заголовок раздела — `SectionHeaderHorizontalPadding = 20.dp`,
  /// `SectionHeaderBottomPadding = 6.dp`.
  static const double sectionHeaderHorizontalPadding = 20;
  static const double sectionHeaderVerticalPadding = 6;

  /// Нижний отступ списка — `ScreenBottomPadding = 32.dp`.
  static const double screenBottomPadding = 32;
}

/// Заголовок раздела — `SettingsSectionLabel` в ArchiveTune:
/// маленький прописной (`labelSmall`, uppercase), полужирный, приглушённый,
/// с чуть расширенной разрядкой (letterSpacing × 1.2).
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? base = theme.textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SettingsDims.sectionHeaderHorizontalPadding,
        vertical: SettingsDims.sectionHeaderVerticalPadding,
      ),
      child: Text(
        title.toUpperCase(),
        style: base?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: (base.letterSpacing ?? 0.5) * 1.2,
        ),
      ),
    );
  }
}

/// Карточка-группа: заголовок раздела и строки в одной карточке —
/// `SettingsGroupCard`: скругление 16, цвет `surfaceContainerLow`, без тени.
///
/// Разделители рисуются между строками автоматически — ровно как
/// `showDivider = index < group.items.size - 1` в оригинале.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.title,
    required this.children,
    this.accent,
  });

  final String title;
  final List<Widget> children;

  /// Акцент группы (цвет иконок). По умолчанию — primary.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color effectiveAccent = accent ?? scheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsSectionHeader(title),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SettingsDims.screenHorizontalPadding,
          ),
          child: Material(
            // Цвет и форма — как у `SettingsGroupCard`.
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(SettingsDims.groupCardCornerRadius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < children.length; i++) ...<Widget>[
                  _AccentScope(accent: effectiveAccent, child: children[i]),
                  if (i < children.length - 1) const SettingsDivider(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Прокидывает акцент группы вниз, чтобы не дублировать его у каждой строки.
class _AccentScope extends InheritedWidget {
  const _AccentScope({required this.accent, required super.child});

  final Color accent;

  static Color? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_AccentScope>()
      ?.accent;

  @override
  bool updateShouldNotify(_AccentScope oldWidget) => accent != oldWidget.accent;
}

/// Разделитель между строками — из `SettingsRow`: толщина 0.5, отступ слева
/// 60 (начинается под текстом), цвет `outlineVariant` с прозрачностью 30 %.
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: SettingsDims.dividerThickness,
      thickness: SettingsDims.dividerThickness,
      indent: SettingsDims.dividerStartIndent,
      color: Theme.of(context)
          .colorScheme
          .outlineVariant
          .withValues(alpha: 0.3),
    );
  }
}

/// Строка настроек с переходом — `SettingsRow` из ArchiveTune.
///
/// Слева кружок 36 с иконкой 20, затем заголовок `bodyLarge` и подпись
/// `bodySmall`, справа шеврон. Нажатие подсвечивает фон акцентом (6 %) и
/// сжимает строку до 0.98 — как в оригинале (`animateFloatAsState`).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.accent,
    this.subtitleMaxLines = 1,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? accent;

  /// Сколько строк отводить подписи. В ArchiveTune — одна; для длинных
  /// пояснений можно снять ограничение, передав `null`.
  final int? subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return _SettingsRowBase(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: subtitleMaxLines,
      accent: accent,
      onTap: onTap,
      // Шеврон показываем только у нажимаемых строк: у информационных он
      // вводил бы в заблуждение.
      trailing: onTap == null
          ? null
          : Icon(
              Icons.chevron_right,
              size: SettingsDims.chevronSize,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
    );
  }
}

/// Строка-переключатель: та же геометрия, но справа `Switch`, а нажатие на
/// строку переключает значение — `SwitchPreference` в ArchiveTune.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.accent,
    this.subtitleMaxLines = 1,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? accent;
  final int? subtitleMaxLines;

  /// Можно ли переключать. `false` — настройка показана, но платформа её не
  /// выполняет: переключатель гаснет, а подпись объясняет причину. Так честнее,
  /// чем прятать пункт или делать вид, что он работает.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return _SettingsRowBase(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleMaxLines: subtitleMaxLines,
      accent: accent,
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
  }
}

/// Общая геометрия и «поведение при нажатии» для всех строк настроек.
class _SettingsRowBase extends StatefulWidget {
  const _SettingsRowBase({
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleMaxLines = 1,
    this.accent,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final int? subtitleMaxLines;
  final Color? accent;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  State<_SettingsRowBase> createState() => _SettingsRowBaseState();
}

class _SettingsRowBaseState extends State<_SettingsRowBase> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color accent =
        widget.accent ?? _AccentScope.maybeOf(context) ?? scheme.primary;
    // В ArchiveTune нажимаема только строка с действием; у информационной
    // подсветки нет.
    final bool interactive = widget.onTap != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: interactive ? (_) => _setPressed(true) : null,
      onTapUp: interactive ? (_) => _setPressed(false) : null,
      onTapCancel: interactive ? () => _setPressed(false) : null,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1,
        duration: AppMotion.fast,
        curve: AppMotion.springSnappy,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.snappy,
          color: _pressed
              ? scheme.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: SettingsDims.rowHorizontalPadding,
            vertical: SettingsDims.rowVerticalPadding,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: SettingsDims.rowIconSize,
                height: SettingsDims.rowIconSize,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.icon,
                  size: SettingsDims.rowIconInnerSize,
                  color: accent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.title,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    if (widget.subtitle != null) ...<Widget>[
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                        maxLines: widget.subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...<Widget>[
                const SizedBox(width: 4),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
