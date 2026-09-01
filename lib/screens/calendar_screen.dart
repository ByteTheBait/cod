import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import '../models/calendar_model.dart';
import '../models/message.dart';
import '../state/providers.dart';
import '../widgets/ai_input_field.dart';
import '../widgets/provider_badge.dart';
import '../widgets/linkified_text.dart';

class CalendarScreen extends ConsumerWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cal = ref.watch(calendarProvider);
    final config = ref.watch(configProvider);
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ProviderBadge(
              providerId: config.activeProviderId,
              modelId: config.active.selectedModel,
            ),
          ),
          if (cal.connected)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Refresh',
              onPressed: () => ref.read(calendarProvider.notifier).loadEvents(),
            ),
        ],
      ),
      body: cal.connected ? _CalendarBody() : _SetupView(),
    );
  }
}

// ── Setup ─────────────────────────────────────────────────────────────────────

class _SetupView extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_month_outlined,
                size: 48, color: cs.primary.withOpacity(0.5)),
            const SizedBox(height: 16),
            Text('Calendar not connected',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Connect your Google account in Settings → Gmail. '
              'Calendar uses the same sign-in — no separate login needed.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: cs.onSurface.withOpacity(0.55)),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                // Navigate to Settings tab (index 5)
                // Use a messenger approach — pop all and switch tab
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Go to Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Main body (3-panel layout) ────────────────────────────────────────────────

class _CalendarBody extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        // Left: suggestions
        const SizedBox(width: 200, child: _SuggestionsPanel()),
        VerticalDivider(
            width: 1,
            color: Theme.of(context).colorScheme.surfaceContainerHigh),
        // Center + chat
        const Expanded(child: _CenterArea()),
      ],
    );
  }
}

// ── Suggestions panel (left) ──────────────────────────────────────────────────

class _SuggestionsPanel extends ConsumerWidget {
  const _SuggestionsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cal = ref.watch(calendarProvider);
    final cs = Theme.of(context).colorScheme;

    return Container(
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
            child: Row(
              children: [
                Text('Suggestions',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface.withOpacity(0.55),
                      letterSpacing: 0.8,
                    )),
                const Spacer(),
                if (cal.loadingSuggestions)
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: cs.primary))
                else
                  Tooltip(
                    message: 'Refresh suggestions',
                    child: InkWell(
                      onTap: () => ref
                          .read(calendarProvider.notifier)
                          .refreshSuggestions(),
                      child: Icon(Icons.auto_awesome_outlined,
                          size: 15, color: cs.primary.withOpacity(0.7)),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // List
          Expanded(
            child: cal.suggestions.isEmpty
                ? _EmptySuggestions(loading: cal.loadingSuggestions)
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: cal.suggestions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) =>
                        _SuggestionCard(suggestion: cal.suggestions[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptySuggestions extends StatelessWidget {
  final bool loading;
  const _EmptySuggestions({required this.loading});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          loading
              ? 'Analysing emails…'
              : 'Tap ✨ to generate suggestions from your emails + calendar',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.35)),
        ),
      ),
    );
  }
}

class _SuggestionCard extends ConsumerWidget {
  final CalendarSuggestion suggestion;
  const _SuggestionCard({required this.suggestion});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;

    final (icon, color) = switch (suggestion.action) {
      SuggestionAction.addEvent => (Icons.event_available_outlined, cs.primary),
      SuggestionAction.reply => (Icons.reply_outlined, Colors.amber.shade600),
      SuggestionAction.info => (Icons.info_outline, cs.onSurface.withOpacity(0.4)),
    };

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.surfaceContainerHigh),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  suggestion.title,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface.withOpacity(0.9)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            suggestion.detail,
            style: TextStyle(
                fontSize: 11, color: cs.onSurface.withOpacity(0.55)),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (suggestion.action == SuggestionAction.addEvent &&
              suggestion.event != null) ...[
            const SizedBox(height: 6),
            TextButton(
              onPressed: () async {
                await ref
                    .read(calendarProvider.notifier)
                    .addEvent(suggestion.event!);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Event added')));
                }
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 28),
                foregroundColor: cs.primary,
              ),
              child: const Text('Add to calendar', style: TextStyle(fontSize: 11)),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Center area: calendar + chat ──────────────────────────────────────────────

class _CenterArea extends ConsumerStatefulWidget {
  const _CenterArea();

  @override
  ConsumerState<_CenterArea> createState() => _CenterAreaState();
}

class _CenterAreaState extends ConsumerState<_CenterArea> {
  bool _chatOpen = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Calendar fills the area
        const _CalendarView(),
        // Chat window anchored to bottom-right
        AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          bottom: 16,
          right: 16,
          child: _chatOpen
              ? _ChatPanel(onClose: () => setState(() => _chatOpen = false))
              : _ChatFab(onOpen: () => setState(() => _chatOpen = true)),
        ),
      ],
    );
  }
}

// ── Calendar view ─────────────────────────────────────────────────────────────

class _CalendarView extends ConsumerWidget {
  const _CalendarView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cal = ref.watch(calendarProvider);
    final cs = Theme.of(context).colorScheme;

    final dayEvents = cal.eventsForDay(cal.selectedDay);

    return Column(
      children: [
        // Table calendar
        TableCalendar<CalendarEvent>(
          firstDay: DateTime.utc(2020, 1, 1),
          lastDay: DateTime.utc(2030, 12, 31),
          focusedDay: cal.focusedDay,
          selectedDayPredicate: (d) => isSameDay(d, cal.selectedDay),
          eventLoader: (day) => cal.eventsForDay(day),
          onDaySelected: (selected, focused) =>
              ref.read(calendarProvider.notifier).setDay(focused, selected),
          onPageChanged: (focused) => ref
              .read(calendarProvider.notifier)
              .setDay(focused, cal.selectedDay),
          calendarFormat: CalendarFormat.month,
          availableCalendarFormats: const {CalendarFormat.month: 'Month'},
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: TextStyle(
                color: cs.onSurface, fontSize: 15, fontWeight: FontWeight.w600),
            leftChevronIcon:
                Icon(Icons.chevron_left, color: cs.onSurface.withOpacity(0.6)),
            rightChevronIcon:
                Icon(Icons.chevron_right, color: cs.onSurface.withOpacity(0.6)),
            decoration: BoxDecoration(color: cs.surfaceContainerLow),
          ),
          daysOfWeekStyle: DaysOfWeekStyle(
            weekdayStyle: TextStyle(
                color: cs.onSurface.withOpacity(0.5), fontSize: 12),
            weekendStyle: TextStyle(
                color: cs.onSurface.withOpacity(0.35), fontSize: 12),
          ),
          calendarStyle: CalendarStyle(
            outsideDaysVisible: false,
            defaultTextStyle: TextStyle(color: cs.onSurface, fontSize: 13),
            weekendTextStyle:
                TextStyle(color: cs.onSurface.withOpacity(0.6), fontSize: 13),
            todayDecoration: BoxDecoration(
                color: cs.primary.withOpacity(0.25),
                shape: BoxShape.circle),
            todayTextStyle:
                TextStyle(color: cs.primary, fontWeight: FontWeight.w700),
            selectedDecoration:
                BoxDecoration(color: cs.primary, shape: BoxShape.circle),
            selectedTextStyle: TextStyle(
                color: cs.onPrimary, fontWeight: FontWeight.w700),
            markerDecoration:
                BoxDecoration(color: cs.primary, shape: BoxShape.circle),
            markersMaxCount: 3,
            markerSize: 5,
            tableBorder: TableBorder(
              horizontalInside: BorderSide(
                  color: cs.surfaceContainerHigh, width: 0.5),
            ),
            tablePadding: EdgeInsets.zero,
          ),
          calendarBuilders: CalendarBuilders(
            markerBuilder: (context, day, events) {
              if (events.isEmpty) return null;
              return Positioned(
                bottom: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: events.take(3).map((e) {
                    final color = e.color ?? cs.primary;
                    return Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: color),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        // Day event list
        Expanded(
          child: dayEvents.isEmpty
              ? Center(
                  child: Text(
                    'No events',
                    style: TextStyle(
                        fontSize: 13, color: cs.onSurface.withOpacity(0.35)),
                  ),
                )
              : ListView.separated(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: dayEvents.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _EventTile(event: dayEvents[i]),
                ),
        ),
      ],
    );
  }
}

class _EventTile extends ConsumerWidget {
  final CalendarEvent event;
  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final color = event.color ?? cs.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.title,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface)),
                const SizedBox(height: 2),
                Text(event.timeLabel,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurface.withOpacity(0.5))),
                if (event.location != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.location_on_outlined,
                          size: 11, color: cs.onSurface.withOpacity(0.4)),
                      const SizedBox(width: 3),
                      Flexible(
                        child: LinkifiedText(
                          event.location!,
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withOpacity(0.45)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                if (event.description != null &&
                    event.description!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  LinkifiedText(
                    event.description!,
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurface.withOpacity(0.5)),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (event.attendees.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.attendees.take(3).join(', ') +
                        (event.attendees.length > 3
                            ? ' +${event.attendees.length - 3}'
                            : ''),
                    style: TextStyle(
                        fontSize: 11, color: cs.onSurface.withOpacity(0.4)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline,
                size: 16, color: cs.onSurface.withOpacity(0.3)),
            onPressed: () =>
                ref.read(calendarProvider.notifier).deleteEvent(event.id),
            tooltip: 'Delete event',
          ),
        ],
      ),
    );
  }
}

// ── Chat FAB ──────────────────────────────────────────────────────────────────

class _ChatFab extends StatelessWidget {
  final VoidCallback onOpen;
  const _ChatFab({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FloatingActionButton.small(
      onPressed: onOpen,
      backgroundColor: cs.primary,
      foregroundColor: cs.onPrimary,
      tooltip: 'Chat about your calendar',
      child: const Icon(Icons.chat_outlined, size: 18),
    );
  }
}

// ── Chat panel ────────────────────────────────────────────────────────────────

class _ChatPanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  const _ChatPanel({required this.onClose});

  @override
  ConsumerState<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<_ChatPanel> {
  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    await ref.read(calendarProvider.notifier).sendChatMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final cal = ref.watch(calendarProvider);
    final cs = Theme.of(context).colorScheme;

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: cs.surfaceContainerLow,
      child: SizedBox(
        width: 320,
        height: 420,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_outlined,
                      size: 14, color: cs.primary),
                  const SizedBox(width: 7),
                  const Expanded(
                    child: Text('Calendar chat',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: widget.onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 28, minHeight: 28),
                  ),
                ],
              ),
            ),
            // Messages
            Expanded(
              child: cal.chatMessages.isEmpty
                  ? Center(
                      child: Text(
                        'Ask about your schedule, upcoming events, or get scheduling help.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withOpacity(0.35)),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: cal.chatMessages.length,
                      itemBuilder: (_, i) =>
                          _CalChatBubble(message: cal.chatMessages[i]),
                    ),
            ),
            // Input
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 10),
              decoration: BoxDecoration(
                border: Border(
                    top:
                        BorderSide(color: cs.surfaceContainerHigh)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: AiInputField(
                      controller: _ctrl,
                      hintText: 'Ask about your schedule…',
                      hintStyle: const TextStyle(
                          color: Colors.white24, fontSize: 12),
                      onSend: _send,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      isDense: true,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 6),
                  cal.chatStreaming
                      ? SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: cs.primary))
                      : IconButton.filled(
                          onPressed: _send,
                          icon: const Icon(Icons.arrow_upward, size: 16),
                          style: IconButton.styleFrom(
                            backgroundColor: cs.primary,
                            foregroundColor: cs.onPrimary,
                            minimumSize: const Size(30, 30),
                            padding: EdgeInsets.zero,
                          ),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalChatBubble extends StatelessWidget {
  final Message message;
  const _CalChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = message.role == MessageRole.user;

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          constraints: const BoxConstraints(maxWidth: 240),
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(0.85),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(message.content,
              style: TextStyle(color: cs.onPrimary, fontSize: 13)),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        constraints: const BoxConstraints(maxWidth: 260),
        child: message.isStreaming && message.content.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [1, 2, 3]
                      .map((i) => Container(
                            width: 6,
                            height: 6,
                            margin:
                                const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: cs.onSurface.withOpacity(0.3),
                            ),
                          ))
                      .toList(),
                ),
              )
            : MarkdownBody(
                data: message.content,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface,
                      height: 1.45),
                ),
              ),
      ),
    );
  }
}
