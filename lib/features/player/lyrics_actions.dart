import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/format.dart';
import '../../data/local/app_settings.dart';
import '../../data/models/models.dart';
import '../../state/catalog_providers.dart';
import '../../state/lyrics_edits.dart';
import '../../state/providers.dart';

/// Кнопка меню текста песни — одно на все поверхности плеера.
class LyricsMenuButton extends ConsumerWidget {
  const LyricsMenuButton({
    super.key,
    required this.request,
    this.onToggleVisibility,
    this.lyricsVisible = true,
    this.iconSize = 20,
  });

  final LyricsRequest request;

  /// Показ/скрытие текста конкретной поверхностью. Если не задано, пункт
  /// в меню не показывается: у самой поверхности нет такого состояния.
  final VoidCallback? onToggleVisibility;
  final bool lyricsVisible;

  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Поиск текста',
      iconSize: iconSize,
      icon: const Icon(Icons.manage_search),
      onPressed: () => showLyricsMenu(
        context,
        request,
        onToggleVisibility: onToggleVisibility,
        lyricsVisible: lyricsVisible,
      ),
    );
  }
}

/// Открывает меню действий с текстом — как `LyricsMenu` в ArchiveTune:
/// сетка действий (изменить, обновить, поиск, сброс) и переключатель показа
/// текста в плеере. Список найденных вариантов живёт не здесь, а в отдельном
/// экране поиска ([showLyricsSearchDialog]) — так же, как в оригинале.
Future<void> showLyricsMenu(
  BuildContext context,
  LyricsRequest request, {
  VoidCallback? onToggleVisibility,
  bool lyricsVisible = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => _LyricsMenuSheet(
      request: request,
      onToggleVisibility: onToggleVisibility,
      lyricsVisible: lyricsVisible,
    ),
  );
}

/// Экран поиска текста.
///
/// Один диалог на два режима — форму ввода метаданных и список найденного:
/// вторая поверхность поверх первой делила бы высоту экрана пополам, а нужен
/// один экран. По умолчанию открывается форма (как `SearchLyricsInputDialog`
/// в ArchiveTune), после «Искать» та же поверхность показывает результаты.
Future<void> showLyricsSearchDialog(
  BuildContext context,
  LyricsRequest request, {
  bool startInInput = true,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext _) => _LyricsSearchDialog(
      request: request,
      startInInput: startInInput,
    ),
  );
}

class _LyricsMenuSheet extends ConsumerStatefulWidget {
  const _LyricsMenuSheet({
    required this.request,
    this.onToggleVisibility,
    this.lyricsVisible = true,
  });

  final LyricsRequest request;
  final VoidCallback? onToggleVisibility;
  final bool lyricsVisible;

  @override
  ConsumerState<_LyricsMenuSheet> createState() => _LyricsMenuSheetState();
}

class _LyricsMenuSheetState extends ConsumerState<_LyricsMenuSheet> {
  @override
  Widget build(BuildContext context) {
    final LyricsRequest request = widget.request;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    // Действующий источник: ручной выбор для этого трека важнее настройки.
    final LyricsSource current =
        ref.watch(lyricsSourceOverrideProvider)[request.videoId] ??
            ref.watch(
              settingsControllerProvider.select(
                (AppSettings s) => s.lyricsSource,
              ),
            );

    // Ручной запрос для трека важнее данных из YouTube — по нему и ищем.
    final LyricsRequest? manual = ref.watch(
      manualLyricsRequestsProvider
          .select((Map<String, LyricsRequest> m) => m[request.videoId]),
    );

    // Выбранная вручную запись (ручной поиск). Пока она есть, показываем
    // именно её текст и отмечаем её в шапке.
    final LyricsTrackHit? selectedHit = ref.watch(
      manualLyricsSelectionProvider
          .select((Map<String, LyricsTrackHit> m) => m[request.videoId]),
    );

    // Подпись в шапке: выбранная запись важнее ручного запроса, а он — важнее
    // источника по умолчанию.
    final String subtitle = selectedHit != null
        ? 'Выбран трек: ${_hitTitle(selectedHit)} (${selectedHit.source.label})'
        : manual != null
            ? 'Ручной поиск: '
                '${<String>[manual.title ?? '', manual.artist ?? ''].where((String s) => s.trim().isNotEmpty).join(' ')}'
            : 'Источник: ${current.label}';

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Текст песни',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                _MenuAction(
                  icon: Icons.edit_outlined,
                  label: 'Изменить',
                  onTap: () => _editLyrics(context, ref),
                ),
                _MenuAction(
                  icon: Icons.refresh,
                  label: 'Обновить',
                  onTap: () => unawaited(_refresh(ref)),
                ),
                _MenuAction(
                  icon: Icons.search,
                  label: 'Поиск',
                  onTap: _openSearch,
                ),
                _MenuAction(
                  icon: Icons.restart_alt,
                  label: 'Сбросить',
                  onTap: () {
                    ref
                        .read(lyricsSourceOverrideProvider.notifier)
                        .setSource(request.videoId, LyricsSource.auto);
                    ref
                        .read(manualLyricsRequestsProvider.notifier)
                        .set(request.videoId, null);
                    // Снимаем и выбранную запись: иначе поиск остался бы
                    // привязан к ней и «Сбросить» был бы неполным.
                    ref
                        .read(manualLyricsSelectionProvider.notifier)
                        .set(request.videoId, null);
                    // И выбранный вариант текста — он тоже ручной выбор.
                    ref
                        .read(lyricsPickProvider.notifier)
                        .set(request.videoId, null);
                    ref.invalidate(lyricsProvider(request));
                    ref.invalidate(lyricsVariantsProvider(request));
                  },
                ),
              ],
            ),
          ),
          if (widget.onToggleVisibility != null)
            SwitchListTile(
              value: widget.lyricsVisible,
              onChanged: (bool _) => widget.onToggleVisibility!(),
              title: const Text('Показывать текст в плеере'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// «Обновить»: снимаем кэш трека и перезапрашиваем источники.
  ///
  /// Без снятия кэша обновление было бы фиктивным: поиск читает кэш до сетевых
  /// запросов и вернул бы те же записи, не сходив в сеть (в оригинале это
  /// `forceRefresh`).
  Future<void> _refresh(WidgetRef ref) async {
    final LyricsRequest request = widget.request;
    final LyricsRequest? manual =
        ref.read(manualLyricsRequestsProvider)[request.videoId];
    await ref.read(lyricsCacheProvider).remove(request.videoId);
    ref.invalidate(lyricsProvider(manual ?? request));
    ref.invalidate(lyricsVariantsProvider(manual ?? request));
  }

  /// «Поиск»: меню закрываем, экран поиска — отдельная поверхность.
  void _openSearch() {
    // Контекст навигатора берём до закрытия шторки: после `pop` контекст
    // шторки уже не годится для показа нового маршрута.
    final BuildContext navigatorContext = Navigator.of(context).context;
    Navigator.of(context).pop();
    unawaited(showLyricsSearchDialog(navigatorContext, widget.request));
  }

  /// Ручная правка текста: показываем найденный текст, даём поправить строки и
  /// кладём правку поверх — без перезапроса источников. Правка живёт по треку,
  /// поэтому её можно снять отдельной кнопкой.
  Future<void> _editLyrics(BuildContext context, WidgetRef ref) async {
    final LyricsRequest request = widget.request;
    // Берём ровно тот текст, что показан сейчас: тот же выбор источника, что
    // и в плеере, иначе пользователь правил бы не то, что видит.
    final AppSettings settings = ref.read(settingsControllerProvider);
    final LyricsSource current =
        ref.read(lyricsSourceOverrideProvider)[request.videoId] ??
            settings.lyricsSource;
    final LyricsRequest? manual =
        ref.read(manualLyricsRequestsProvider)[request.videoId];
    final LyricsRequest effective = manual ?? request;
    final LyricsSearchState search =
        ref.read(lyricsProvider(effective)).value ??
            const LyricsSearchState();
    final Lyrics? base = ref.read(lyricsPickProvider)[request.videoId]?.lyrics ??
        (current == LyricsSource.auto
            ? search.bestByOrder(settings.lyricsProviderOrder)?.lyrics
            : search.candidateFor(current)?.lyrics);

    final LyricsEdits edits = ref.read(lyricsEditsProvider.notifier);
    final String? existing = ref.read(lyricsEditsProvider)[request.videoId];
    final TextEditingController field = TextEditingController(
      text: existing ?? _lyricsText(base),
    );

    final int? action = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Изменить текст'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          // Поле многострочное и может не влезть в диалог — прокручиваем.
          child: SingleChildScrollView(
            child: TextField(
              controller: field,
              // Многострочное поле: по строке на строку — так времена
              // сохраняются по индексу строки, когда число строк совпало.
              maxLines: null,
              minLines: 10,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'По строке на строку',
              ),
            ),
          ),
        ),
        actions: <Widget>[
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 0),
              child: const Text('Сбросить правку'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 1),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    final String text = field.text;
    field.dispose();

    if (action == 0) {
      await edits.set(request.videoId, null);
    } else if (action == 1) {
      await edits.set(request.videoId, text);
    }
  }

  /// Текущий текст строками — то, что видит пользователь в плеере.
  static String _lyricsText(Lyrics? lyrics) {
    if (lyrics == null) return '';
    final List<TimedLyric>? timed = lyrics.timed;
    if (timed != null && timed.isNotEmpty) {
      return timed.map((TimedLyric l) => l.text).join('\n');
    }
    return lyrics.plain ?? '';
  }
}

/// Действие в меню: иконка + подпись (как `NewAction` в ArchiveTune).
class _MenuAction extends StatelessWidget {
  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: <Widget>[
              Icon(icon, color: scheme.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Экран поиска текста: форма ввода и список найденного в одной поверхности.
class _LyricsSearchDialog extends ConsumerStatefulWidget {
  const _LyricsSearchDialog({
    required this.request,
    required this.startInInput,
  });

  final LyricsRequest request;
  final bool startInInput;

  @override
  ConsumerState<_LyricsSearchDialog> createState() =>
      _LyricsSearchDialogState();
}

class _LyricsSearchDialogState extends ConsumerState<_LyricsSearchDialog> {
  /// Показываем форму ввода метаданных, а не список найденного.
  late bool _inputMode = widget.startInInput;

  /// Какая карточка раскрыта (ключ — источник). Раскрывается одна за раз,
  /// как `expandedSearchResultId` в ArchiveTune.
  String? _expandedId;

  @override
  Widget build(BuildContext context) {
    final LyricsRequest request = widget.request;
    // Ручной запрос для трека важнее данных из YouTube — по нему и ищем.
    final LyricsRequest? manual = ref.watch(
      manualLyricsRequestsProvider
          .select((Map<String, LyricsRequest> m) => m[request.videoId]),
    );
    final LyricsRequest effective = manual ?? request;
    // Список вариантов — из «всех совпадений»: у одного источника их бывает
    // несколько, и выбирать нужно из них (как `getAllLyrics` в ArchiveTune).
    //
    // Спрашиваем только когда показываем список: пока открыта форма ввода,
    // поиск не запущен — иначе он шёл бы впустую, если пользователь передумал.
    final LyricsSearchState search = _inputMode
        ? const LyricsSearchState()
        : ref.watch(lyricsVariantsProvider(effective)).value ??
            const LyricsSearchState();

    // Выбранный вручную вариант: он авторитетен и для списка, и для плеера.
    final LyricsPick? pick = ref.watch(
      lyricsPickProvider
          .select((Map<String, LyricsPick> m) => m[request.videoId]),
    );

    // Какой вариант показывается в плеере сейчас: в «Авто» — лучший по
    // приоритету, иначе выбранный вручную.
    final LyricsSource current =
        ref.watch(lyricsSourceOverrideProvider)[request.videoId] ??
            ref.watch(
              settingsControllerProvider.select(
                (AppSettings s) => s.lyricsSource,
              ),
            );
    final List<LyricsSource> order = ref.watch(
      settingsControllerProvider.select(
        (AppSettings s) => s.lyricsProviderOrder,
      ),
    );
    // Какой вариант показывает плеер: выбранный вручную — по ключу, иначе
    // лучший («Авто») или первый из выбранного источника. Спрашиваем обычный
    // поиск: именно его результат идёт в плеер, а список здесь — из «всех
    // совпадений», и это разные состояния.
    final LyricsSearchState shownState =
        ref.watch(lyricsProvider(effective)).value ??
            const LyricsSearchState();
    final LyricsCandidate? shown = pick != null
        ? shownState.candidateById(pick.id) ?? search.candidateById(pick.id)
        : current == LyricsSource.auto
            ? shownState.bestByOrder(order)
            : shownState.candidateFor(current);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SearchHeader(
              subtitle: _inputMode
                  ? 'Ищем по названию и исполнителю — их можно поправить.'
                  : _statusText(search),
              searching: !_inputMode && search.loading,
              onBack: _inputMode ? null : () => setState(() => _inputMode = true),
              onRefetch: _inputMode || search.loading
                  ? null
                  : () => _refetch(effective),
              onClose: () => Navigator.pop(context),
            ),
            Flexible(
              child: _inputMode
                  ? _SearchInputPane(
                      base: manual ?? request,
                      videoId: request.videoId,
                      onSearch: () => setState(() => _inputMode = false),
                      onReset: () => setState(() => _inputMode = false),
                    )
                  : _resultsPane(search, shown, pick),
            ),
          ],
        ),
      ),
    );
  }

  /// Подпись под заголовком: счётчик найденного, ожидание или пустота.
  String _statusText(LyricsSearchState search) {
    if (search.candidates.isEmpty) {
      return search.loading
          ? 'Ищем текст во всех источниках…'
          : 'Текст не найден';
    }
    return 'Найдено: ${search.candidates.length} '
        '${_plural(search.candidates.length, 'вариант', 'варианта', 'вариантов')}';
  }

  /// Повторный поиск: кэш трека снимаем, иначе ответы придут с диска.
  Future<void> _refetch(LyricsRequest effective) async {
    setState(() => _expandedId = null);
    await ref.read(lyricsCacheProvider).remove(widget.request.videoId);
    ref.invalidate(lyricsVariantsProvider(effective));
    // Обычный поиск (для плеера) тоже переспрашиваем: иначе он остался бы
    // с прежним ответом, а список показывал бы новый.
    ref.invalidate(lyricsProvider(effective));
  }

  Widget _resultsPane(
    LyricsSearchState search,
    LyricsCandidate? shown,
    LyricsPick? pick,
  ) {
    if (search.candidates.isEmpty) {
      return search.loading
          ? const _SearchMessage(
              icon: Icons.manage_search,
              text: 'Ищем текст во всех источниках…',
              spinner: true,
            )
          : const _SearchMessage(
              icon: Icons.search_off,
              text: 'Текст не найден. Попробуйте ручной поиск.',
              error: true,
            );
    }

    final List<LyricsCandidate> candidates = search.candidates;
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      itemCount: candidates.length + (search.loading ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        // Пока хоть один источник молчит — внизу списка видно, что поиск идёт
        // (как `LyricsSearchFooterLoading` в ArchiveTune).
        if (index == candidates.length) return const _SearchFooterLoading();

        final LyricsCandidate candidate = candidates[index];
        final String id = candidate.id;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ResultCard(
            providerLabel: candidate.source.label,
            // Объём и превью уже посчитаны при сборке варианта — берём их,
            // а не считаем заново по тексту.
            info: _ResultInfo(
              syncLabel: _syncLabel(
                wordSynced: candidate.isWordSynced,
                lineSynced: candidate.isLineSynced,
              ),
              icon: _syncIcon(
                wordSynced: candidate.isWordSynced,
                lineSynced: candidate.isLineSynced,
              ),
              preview: candidate.preview,
              stats: _statsText(
                candidate.lineCount,
                candidate.characterCount,
              ),
            ),
            // Выбранный вариант отмечаем по ключу, а не по источнику: у одного
            // источника вариантов теперь несколько, и по источнику их не
            // различить.
            selected: candidate.id == shown?.id || candidate.id == pick?.id,
            expanded: _expandedId == id,
            onExpand: () => setState(
              () => _expandedId = _expandedId == id ? null : id,
            ),
            onTap: () => _select(candidate),
          ),
        );
      },
    );
  }

  /// Выбор варианта: запоминаем сам текст, а не только источник.
  ///
  /// Почему текст: у одного источника вариантов несколько, и «показать этот»
  /// нельзя выразить одним источником. Источник тоже фиксируем — по нему
  /// подписан плеер.
  void _select(LyricsCandidate candidate) {
    final String videoId = widget.request.videoId;
    ref.read(lyricsPickProvider.notifier).set(
          videoId,
          LyricsPick(
            id: candidate.id,
            source: candidate.source,
            lyrics: candidate.lyrics,
          ),
        );
    // Выбранный текст теперь и есть текст трека — отмечаем: значок «есть
    // текст» в списках должен говорить правду.
    ref.read(lyricsAvailabilityProvider.notifier).mark(videoId);
    // Источник запоминаем для этого трека: смена настройки затронула бы все
    // треки, а пользователь просил другой текст именно здесь.
    ref
        .read(lyricsSourceOverrideProvider.notifier)
        .setSource(videoId, candidate.source);
    // Перезапрашивать не нужно: все варианты уже получены параллельным
    // поиском и лежат в состоянии — переключение мгновенное.
    Navigator.pop(context);
  }
}

/// Шапка экрана поиска — как `LyricsSearchResultHeader` в ArchiveTune:
/// плитка с иконкой, заголовок, состояние поиска и кнопки.
class _SearchHeader extends StatelessWidget {
  const _SearchHeader({
    required this.subtitle,
    required this.searching,
    required this.onBack,
    required this.onRefetch,
    required this.onClose,
  });

  final String subtitle;
  final bool searching;
  final VoidCallback? onBack;
  final VoidCallback? onRefetch;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;

    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 10, 18),
        child: Row(
          children: <Widget>[
            if (onBack != null)
              IconButton(
                tooltip: 'Назад',
                iconSize: 20,
                icon: const Icon(Icons.arrow_back),
                color: scheme.onPrimaryContainer,
                onPressed: onBack,
              ),
            Material(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(28),
              child: SizedBox(
                width: 56,
                height: 56,
                child: Icon(
                  Icons.manage_search,
                  size: 30,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Поиск текста',
                    style: text.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: text.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (searching)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            if (onRefetch != null)
              IconButton(
                tooltip: 'Искать заново',
                iconSize: 22,
                icon: const Icon(Icons.refresh),
                color: scheme.onPrimaryContainer,
                onPressed: onRefetch,
              ),
            IconButton(
              tooltip: 'Закрыть',
              iconSize: 22,
              icon: const Icon(Icons.close),
              color: scheme.onPrimaryContainer,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// Ожидание внизу списка, пока отвечают не все источники.
class _SearchFooterLoading extends StatelessWidget {
  const _SearchFooterLoading();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Всё ещё ищем…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

/// Сообщение вместо списка: пусто или ошибка (как `LyricsSearchMessageContent`).
class _SearchMessage extends StatelessWidget {
  const _SearchMessage({
    required this.icon,
    required this.text,
    this.spinner = false,
    this.error = false,
  });

  final IconData icon;
  final String text;
  final bool spinner;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Material(
            color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(28),
            child: SizedBox(
              width: 56,
              height: 56,
              child: spinner
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : Icon(
                      icon,
                      size: 28,
                      color: error
                          ? scheme.onErrorContainer
                          : scheme.onSurfaceVariant,
                    ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

/// Что показывать в карточке: тип синхронизации, объём и превью.
///
/// Одно представление и для найденных текстов, и для найденных записей —
/// карточка результата в ArchiveTune одна на оба случая.
@immutable
class _ResultInfo {
  const _ResultInfo({
    required this.syncLabel,
    required this.icon,
    required this.preview,
    required this.stats,
  });

  factory _ResultInfo.fromLyrics(Lyrics lyrics) {
    final List<TimedLyric> timed = lyrics.timed ?? const <TimedLyric>[];
    final bool wordSynced = timed.any((TimedLyric l) => l.hasWords);
    final bool lineSynced = timed.isNotEmpty && !wordSynced;
    final List<String> lines = timed.isNotEmpty
        ? timed.map((TimedLyric l) => l.text).toList()
        : (lyrics.plain ?? '').split('\n');
    final List<String> nonEmpty =
        lines.where((String l) => l.trim().isNotEmpty).toList();
    return _ResultInfo(
      syncLabel: _syncLabel(wordSynced: wordSynced, lineSynced: lineSynced),
      icon: _syncIcon(wordSynced: wordSynced, lineSynced: lineSynced),
      preview: nonEmpty.take(8).join('\n'),
      stats: _statsText(
        nonEmpty.length,
        lyrics.plain?.length ??
            lines.fold<int>(0, (int sum, String l) => sum + l.length),
      ),
    );
  }

  final String syncLabel;
  final IconData icon;
  final String preview;
  final String stats;
}

/// Карточка найденного варианта — как `LyricsSearchResultItem` в ArchiveTune:
/// плитка типа синхронизации, источник, раскрытие превью и две пилюли с
/// подробностями. Тап по карточке — выбрать этот вариант.
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.providerLabel,
    required this.info,
    required this.selected,
    required this.expanded,
    required this.onExpand,
    required this.onTap,
  });

  final String providerLabel;

  /// `null` — текст ещё грузится: показываем заглушки вместо строк.
  final _ResultInfo? info;

  final bool selected;
  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final _ResultInfo? info = this.info;

    // Раскрытая карточка перекрашивается — как в оригинале: её видно издалека.
    final Color container =
        expanded ? scheme.secondaryContainer : scheme.surfaceContainerHighest;
    final Color content =
        expanded ? scheme.onSecondaryContainer : scheme.onSurface;
    final Color outline = expanded ? scheme.primary : scheme.outlineVariant;

    return Material(
      color: container,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  _TypeTile(icon: info?.icon, expanded: expanded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                providerLabel,
                                style: text.labelLarge?.copyWith(
                                  color: content,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (selected) ...<Widget>[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.check_circle,
                                size: 16,
                                color: expanded
                                    ? scheme.onSecondaryContainer
                                    : scheme.primary,
                              ),
                            ],
                          ],
                        ),
                        Text(
                          info?.syncLabel ?? 'Проверяем текст…',
                          style: text.titleMedium?.copyWith(color: content),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: expanded ? 'Свернуть' : 'Подробнее',
                    iconSize: 24,
                    color: content,
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    onPressed: onExpand,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (info == null)
                const _PreviewPlaceholder()
              else
                AnimatedSize(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: Text(
                    info.preview,
                    maxLines: expanded ? 8 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(color: content),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _MetadataPill(
                      icon: Icons.info_outline,
                      text: info?.syncLabel ?? '—',
                      expanded: expanded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetadataPill(
                      icon: Icons.text_fields,
                      text: info?.stats ?? '—',
                      expanded: expanded,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Плитка типа синхронизации в карточке (`LyricsSearchTypeIcon`).
class _TypeTile extends StatelessWidget {
  const _TypeTile({required this.icon, required this.expanded});

  final IconData? icon;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: expanded ? scheme.primary : scheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        width: 48,
        height: 48,
        child: icon == null
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                icon,
                size: 24,
                color: expanded
                    ? scheme.onPrimary
                    : scheme.onTertiaryContainer,
              ),
      ),
    );
  }
}

/// Пилюля с подробностью (`LyricsSearchMetadataPill`).
class _MetadataPill extends StatelessWidget {
  const _MetadataPill({
    required this.icon,
    required this.text,
    required this.expanded,
  });

  final IconData icon;
  final String text;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color content =
        expanded ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return Material(
      color: expanded
          ? scheme.surface.withValues(alpha: 0.52)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 16, color: content),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: content,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Форма ручного поиска: метаданные и кнопки, как `SearchLyricsInputDialog`.
///
/// Живёт внутри того же экрана, что и список: после «Искать» показывается
/// список, а не вторая поверхность поверх первой.
class _SearchInputPane extends ConsumerStatefulWidget {
  const _SearchInputPane({
    required this.base,
    required this.videoId,
    required this.onSearch,
    required this.onReset,
  });

  final LyricsRequest base;
  final String videoId;

  /// Переход к списку найденного после «Искать».
  final VoidCallback onSearch;

  /// Переход к списку после сброса.
  final VoidCallback onReset;

  @override
  ConsumerState<_SearchInputPane> createState() => _SearchInputPaneState();
}

class _SearchInputPaneState extends ConsumerState<_SearchInputPane> {
  late final TextEditingController _title;
  late final TextEditingController _artist;

  @override
  void initState() {
    super.initState();
    final LyricsRequest base = widget.base;
    _title = TextEditingController(text: base.title ?? '');
    _artist = TextEditingController(text: base.artist ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  /// Запрос собираем из двух полей, а альбом и длительность берём из трека —
  /// как `SearchLyricsInputDialog` в ArchiveTune: править их незачем, а нужны
  /// они источникам для отсева чужих записей.
  LyricsRequest _buildRequest() {
    final String t = _title.text.trim();
    final String a = _artist.text.trim();
    return LyricsRequest(
      videoId: widget.videoId,
      title: t.isEmpty ? null : t,
      artist: a.isEmpty ? null : a,
      album: widget.base.album,
      duration: widget.base.duration,
    );
  }

  /// «Искать»: запоминаем ручной запрос и показываем список найденного.
  void _search() {
    // Ручной запрос запоминаем: по этим метаданным идёт и обычный параллельный
    // поиск, и поиск записей для выбора.
    ref.read(manualLyricsRequestsProvider.notifier).set(
          widget.videoId,
          _buildRequest(),
        );
    widget.onSearch();
  }

  /// «Искать в интернете»: открываем браузер с запросом по тем же словам.
  Future<void> _searchOnline() async {
    final String query = <String>[
      _artist.text.trim(),
      _title.text.trim(),
      'lyrics',
    ].where((String s) => s.isNotEmpty).join(' ');
    final Uri uri = Uri.parse(
      'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// «Сбросить»: снимаем и ручной запрос, и выбранную запись.
  void _reset() {
    ref
        .read(manualLyricsSelectionProvider.notifier)
        .set(widget.videoId, null);
    ref.read(manualLyricsRequestsProvider.notifier).set(widget.videoId, null);
    ref
        .read(lyricsSourceOverrideProvider.notifier)
        .setSource(widget.videoId, LyricsSource.auto);
    widget.onReset();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final LyricsTrackHit? selected = ref.watch(
      manualLyricsSelectionProvider
          .select((Map<String, LyricsTrackHit> m) => m[widget.videoId]),
    );
    // Список записей показываем только после поиска: до него это была бы
    // пустая форма без ответа.
    final LyricsRequest? query = ref.watch(
      manualLyricsRequestsProvider
          .select((Map<String, LyricsRequest> m) => m[widget.videoId]),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _title,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Название',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.music_note),
            ),
          ),
          const SizedBox(height: 16),
          // Альбом и длительность не правим — они из трека. Так же, как в
          // `SearchLyricsInputDialog`: полей два, а остальное берётся из
          // метаданных.
          TextField(
            controller: _artist,
            textInputAction: TextInputAction.search,
            onSubmitted: (String _) => _search(),
            decoration: const InputDecoration(
              labelText: 'Исполнитель',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () => unawaited(_searchOnline()),
                icon: const Icon(Icons.language),
                label: const Text('Искать в интернете'),
              ),
              FilledButton.icon(
                onPressed: _search,
                icon: const Icon(Icons.search),
                label: const Text('Искать'),
              ),
            ],
          ),
          if (query != null) ...<Widget>[
            const SizedBox(height: 24),
            Text('Найденные записи', style: text.titleSmall),
            const SizedBox(height: 2),
            Text(
              'YouLy+ и BetterLyrics ищут только по метаданным — их записей '
              'здесь нет.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            _HitResults(
              request: query,
              selected: selected,
              onSelect: _selectHit,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              TextButton(onPressed: _reset, child: const Text('Сбросить')),
            ],
          ),
        ],
      ),
    );
  }

  /// Тап по записи: применяем её для этого трека и закрываем экран поиска.
  void _selectHit(LyricsTrackHit hit) {
    ref
        .read(manualLyricsSelectionProvider.notifier)
        .set(widget.videoId, hit);
    // Источник тоже фиксируем, иначе плеер не знал бы, какой вариант показать.
    ref
        .read(lyricsSourceOverrideProvider.notifier)
        .setSource(widget.videoId, hit.source);
    // Выбранный из списка вариант снимаем: он относится к прежнему поиску и
    // перебил бы только что выбранную запись.
    ref.read(lyricsPickProvider.notifier).set(widget.videoId, null);
    Navigator.pop(context);
  }
}

/// Список найденных записей под формой ручного поиска.
class _HitResults extends ConsumerWidget {
  const _HitResults({
    required this.request,
    required this.selected,
    required this.onSelect,
  });

  final LyricsRequest request;
  final LyricsTrackHit? selected;
  final ValueChanged<LyricsTrackHit> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<LyricsTrackHit>> hits =
        ref.watch(manualLyricsHitsProvider(request));

    return hits.when(
      loading: () => const _SearchFooterLoading(),
      error: (Object error, StackTrace stack) => const Padding(
        padding: EdgeInsets.all(20),
        child: Text('Не удалось выполнить поиск. Попробуйте ещё раз.'),
      ),
      data: (List<LyricsTrackHit> list) {
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Text('Ничего не нашлось. Проверьте название и исполнителя.'),
          );
        }
        // Высоту ограничиваем, чтобы форма не разрасталась: список
        // прокручивается внутри своей рамки.
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: list.length,
            itemBuilder: (BuildContext context, int index) {
              final LyricsTrackHit hit = list[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _HitCard(
                  hit: hit,
                  selected: selected == hit,
                  onTap: () => onSelect(hit),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Карточка найденной записи: та же карточка результата, но текст подгружается
/// лениво — запрос уходит только за видимыми строками списка.
class _HitCard extends ConsumerStatefulWidget {
  const _HitCard({
    required this.hit,
    required this.selected,
    required this.onTap,
  });

  final LyricsTrackHit hit;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<_HitCard> createState() => _HitCardState();
}

class _HitCardState extends ConsumerState<_HitCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final LyricsTrackHit hit = widget.hit;
    final AsyncValue<Lyrics> preview = ref.watch(lyricsHitPreviewProvider(hit));
    final Lyrics? lyrics = preview.value;
    final _ResultInfo? info =
        (lyrics == null || lyrics.isEmpty) ? null : _ResultInfo.fromLyrics(lyrics);

    // Название записи — как в списке: «Название — Исполнитель».
    final String meta = <String>[
      if ((hit.artist ?? '').trim().isNotEmpty) hit.artist!.trim(),
      if ((hit.album ?? '').trim().isNotEmpty) hit.album!.trim(),
      if (hit.duration != null && hit.duration! > Duration.zero)
        formatDuration(hit.duration),
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _ResultCard(
          providerLabel: hit.source.label,
          info: info,
          selected: widget.selected,
          expanded: _expanded,
          onExpand: () => setState(() => _expanded = !_expanded),
          onTap: widget.onTap,
        ),
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 6),
            child: Text(
              _hitTitle(hit),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// Заглушка превью: серые полоски на время загрузки текста.
class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder();

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context)
        .colorScheme
        .onSurfaceVariant
        .withValues(alpha: 0.25);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _bar(color, 0.75),
        const SizedBox(height: 6),
        _bar(color, 0.45),
      ],
    );
  }

  Widget _bar(Color color, double factor) => FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: factor,
        child: Container(
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      );
}

/// «Название — Исполнитель» для подписи найденной записи.
String _hitTitle(LyricsTrackHit hit) {
  final List<String> parts = <String>[
    if ((hit.title ?? '').trim().isNotEmpty) hit.title!.trim(),
    if ((hit.artist ?? '').trim().isNotEmpty) hit.artist!.trim(),
  ];
  return parts.isEmpty ? 'без названия' : parts.join(' — ');
}

String _syncLabel({required bool wordSynced, required bool lineSynced}) =>
    wordSynced
        ? 'Пословная синхронизация'
        : lineSynced
            ? 'Построчная синхронизация'
            : 'Без синхронизации';

IconData _syncIcon({required bool wordSynced, required bool lineSynced}) =>
    wordSynced
        ? Icons.graphic_eq
        : lineSynced
            ? Icons.sync
            : Icons.format_align_left;

/// «37 строк · 1587 символов» — как `lyrics_search_result_stats`.
String _statsText(int lines, int characters) =>
    '$lines ${_plural(lines, 'строка', 'строки', 'строк')} · '
    '$characters ${_plural(characters, 'символ', 'символа', 'символов')}';

/// Русское склонение: 1 строка, 2 строки, 5 строк.
String _plural(int count, String one, String few, String many) {
  final int mod100 = count % 100;
  if (mod100 >= 11 && mod100 <= 14) return many;
  switch (count % 10) {
    case 1:
      return one;
    case 2:
    case 3:
    case 4:
      return few;
    default:
      return many;
  }
}
