import 'package:flutter/material.dart';

import '../api/model/model.dart';
import '../generated/l10n/zulip_localizations.dart';
import '../model/narrow.dart';
import '../model/recent_dm_conversations.dart';
import '../model/unreads.dart';
import 'action_sheet.dart';
import 'color.dart';
import 'icons.dart';
import 'message_list.dart';
import 'sticky_header.dart';
import 'store.dart';
import 'text.dart';
import 'theme.dart';
import 'unread_count_badge.dart';

class InboxPageBody extends StatefulWidget {
  const InboxPageBody({super.key});

  @override
  State<InboxPageBody> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPageBody> with PerAccountStoreAwareStateMixin<InboxPageBody> {
  Unreads? unreadsModel;
  RecentDmConversationsView? recentDmConversationsModel;

  bool get allDmsCollapsed => _allDmsCollapsed;
  bool _allDmsCollapsed = false;
  set allDmsCollapsed(bool value) {
    setState(() {
      _allDmsCollapsed = value;
    });
  }

  Set<int> get collapsedStreamIds => _collapsedStreamIds;
  final Set<int> _collapsedStreamIds = {};
  void collapseStream(int streamId) {
    setState(() {
      _collapsedStreamIds.add(streamId);
    });
  }
  void uncollapseStream(int streamId) {
    setState(() {
      _collapsedStreamIds.remove(streamId);
    });
  }

  @override
  void onNewStore() {
    final newStore = PerAccountStoreWidget.of(context);
    unreadsModel?.removeListener(_modelChanged);
    unreadsModel = newStore.unreads..addListener(_modelChanged);
    recentDmConversationsModel?.removeListener(_modelChanged);
    recentDmConversationsModel = newStore.recentDmConversationsView
      ..addListener(_modelChanged);
  }

  @override
  void dispose() {
    unreadsModel?.removeListener(_modelChanged);
    recentDmConversationsModel?.removeListener(_modelChanged);
    super.dispose();
  }

  void _modelChanged() {
    setState(() {
      // Much of the state lives in [unreadsModel] and
      // [recentDmConversationsModel].
      // This method was called because one of those just changed.
      //
      // We also update some state that lives locally: we reset a collapsible
      // row's collapsed state when it's cleared of unreads.
      // TODO(perf) handle those updates efficiently
      collapsedStreamIds.removeWhere((streamId) =>
        !unreadsModel!.streams.containsKey(streamId));
      if (unreadsModel!.dms.isEmpty) {
        allDmsCollapsed = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = PerAccountStoreWidget.of(context);
    final subscriptions = store.subscriptions;

    // TODO(#1065) make an incrementally-updated view-model for InboxPage
    final sections = <_InboxSectionData>[];

    // TODO efficiently include DM conversations that aren't recent enough
    //   to appear in recentDmConversationsView, but still have unreads in
    //   unreadsModel.
    final dmItems = <(DmNarrow, int, bool)>[];
    int allDmsCount = 0;
    bool allDmsHasMention = false;
    for (final dmNarrow in recentDmConversationsModel!.sorted) {
      final countInNarrow = unreadsModel!.countInDmNarrow(dmNarrow);
      if (countInNarrow == 0) {
        continue;
      }
      final hasMention = unreadsModel!.dms[dmNarrow]!.any(
        (messageId) => unreadsModel!.mentions.contains(messageId));
      if (hasMention) allDmsHasMention = true;
      dmItems.add((dmNarrow, countInNarrow, hasMention));
      allDmsCount += countInNarrow;
    }
    if (allDmsCount > 0) {
      sections.add(_AllDmsSectionData(allDmsCount, allDmsHasMention, dmItems));
    }

    final sortedUnreadStreams = unreadsModel!.streams.entries
      // Filter out any straggling unreads in unsubscribed streams.
      // There won't normally be any, but it happens with certain infrequent
      // state changes, typically for less than a few hundred milliseconds.
      // See [Unreads].
      //
      // Also, we want to depend on the subscription data for things like
      // choosing the stream icon.
      .where((entry) => subscriptions.containsKey(entry.key))
      .toList()
      ..sort((a, b) {
        final subA = subscriptions[a.key]!;
        final subB = subscriptions[b.key]!;

        // TODO "pin" icon on the stream row? dividers in the list?
        if (subA.pinToTop != subB.pinToTop) {
          return subA.pinToTop ? -1 : 1;
        }

        // TODO(i18n) something like JS's String.prototype.localeCompare
        return subA.name.toLowerCase().compareTo(subB.name.toLowerCase());
      });

    for (final MapEntry(key: streamId, value: topics) in sortedUnreadStreams) {
      final topicItems = <_StreamSectionTopicData>[];
      int countInStream = 0;
      bool streamHasMention = false;
      for (final MapEntry(key: topic, value: messageIds) in topics.entries) {
        if (!store.isTopicVisible(streamId, topic)) continue;
        final countInTopic = messageIds.length;
        final hasMention = messageIds.any((messageId) => unreadsModel!.mentions.contains(messageId));
        if (hasMention) streamHasMention = true;
        topicItems.add(_StreamSectionTopicData(
          topic: topic,
          count: countInTopic,
          hasMention: hasMention,
          lastUnreadId: messageIds.last,
        ));
        countInStream += countInTopic;
      }
      if (countInStream == 0) {
        continue;
      }
      topicItems.sort((a, b) {
        final aLastUnreadId = a.lastUnreadId;
        final bLastUnreadId = b.lastUnreadId;
        return bLastUnreadId.compareTo(aLastUnreadId);
      });
      sections.add(_StreamSectionData(streamId, countInStream, streamHasMention, topicItems));
    }

    if (sections.isEmpty) {
      return const InboxEmptyWidget();
    }

    return SafeArea(
      // Don't pad the bottom here; we want the list content to do that.
      bottom: false,
      child: StickyHeaderListView.builder(
        itemCount: sections.length,
        itemBuilder: (context, index) {
          final section = sections[index];
          switch (section) {
            case _AllDmsSectionData():
              return _AllDmsSection(
                data: section,
                collapsed: allDmsCollapsed,
                pageState: this,
              );
            case _StreamSectionData(:var streamId):
              final collapsed = collapsedStreamIds.contains(streamId);
              return _StreamSection(data: section, collapsed: collapsed, pageState: this);
          }
        }));
  }
}

class InboxEmptyWidget extends StatelessWidget {
  const InboxEmptyWidget({super.key});

  // Splits a message containing text in square brackets into three parts.
  List<String> _splitMessage(String message) {
    final pattern = RegExp(r'(.*?)\[(.*?)\](.*)', dotAll: true);
    final match = pattern.firstMatch(message);

    return match == null
      ? [message, '', '']
      : [
          match.group(1) ?? '',
          match.group(2) ?? '',
          match.group(3) ?? '',
        ];
  }

  @override
  Widget build(BuildContext context) {
    final zulipLocalizations = ZulipLocalizations.of(context);
    final designVariables = DesignVariables.of(context);

    final messageParts = _splitMessage(zulipLocalizations.emptyInboxMessage);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const SizedBox(height: 48),
            Icon(
              ZulipIcons.inbox_done,
              size: 80,
              color: designVariables.foreground.withFadedAlpha(0.3),
            ),
            const SizedBox(height: 16),
            Text.rich(
              TextSpan(
                style: TextStyle(
                  color: designVariables.labelSearchPrompt,
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
                children: [
                  TextSpan(text: messageParts[0]),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        splashFactory: NoSplash.splashFactory
                      ),
                      onPressed: () => Navigator.push(context,
                          MessageListPage.buildRoute(context: context,
                            narrow: const CombinedFeedNarrow())),
                      child: Text(
                        messageParts[1],
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          color: designVariables.link,
                          decoration: TextDecoration.underline,
                          decorationStyle: TextDecorationStyle.solid,
                          decorationThickness: 2.5,
                          decorationColor: designVariables.link,
                          height: 1.5,
                        )
                      ),
                    ),
                  ),
                  TextSpan(text: messageParts[2]),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

sealed class _InboxSectionData {
  const _InboxSectionData();
}

class _AllDmsSectionData extends _InboxSectionData {
  final int count;
  final bool hasMention;
  final List<(DmNarrow, int, bool)> items;

  const _AllDmsSectionData(this.count, this.hasMention, this.items);
}

class _StreamSectionData extends _InboxSectionData {
  final int streamId;
  final int count;
  final bool hasMention;
  final List<_StreamSectionTopicData> items;

  const _StreamSectionData(this.streamId, this.count, this.hasMention, this.items);
}

class _StreamSectionTopicData {
  final TopicName topic;
  final int count;
  final bool hasMention;
  final int lastUnreadId;

  const _StreamSectionTopicData({
    required this.topic,
    required this.count,
    required this.hasMention,
    required this.lastUnreadId,
  });
}

abstract class _HeaderItem extends StatelessWidget {
  final bool collapsed;
  final _InboxPageState pageState;
  final int count;
  final bool hasMention;

  /// A build context within the [_StreamSection] or [_AllDmsSection].
  ///
  /// Used to ensure the [_StreamSection] or [_AllDmsSection] that encloses the
  /// current [_HeaderItem] is visible after being collapsed through this
  /// [_HeaderItem].
  final BuildContext sectionContext;

  const _HeaderItem({
    required this.collapsed,
    required this.pageState,
    required this.count,
    required this.hasMention,
    required this.sectionContext,
  });

  String title(ZulipLocalizations zulipLocalizations);
  IconData get icon;
  Color collapsedIconColor(BuildContext context);
  Color uncollapsedIconColor(BuildContext context);
  Color uncollapsedBackgroundColor(BuildContext context);
  Color? unreadCountBadgeBackgroundColor(BuildContext context);

  Future<void> onCollapseButtonTap() async {
    if (!collapsed) {
      await Scrollable.ensureVisible(
        sectionContext,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    }
  }

  Future<void> onRowTap();

  @override
  Widget build(BuildContext context) {
    final zulipLocalizations = ZulipLocalizations.of(context);
    final designVariables = DesignVariables.of(context);
    return Material(
      color: collapsed
        ? designVariables.background // TODO(design) check if this is the right variable
        : uncollapsedBackgroundColor(context),
      child: InkWell(
        // TODO use onRowTap to handle taps that are not on the collapse button.
        //   Probably we should give the collapse button a 44px or 48px square
        //   touch target:
        //     <https://chat.zulip.org/#narrow/stream/243-mobile-team/topic/flutter.3A.20Mark-as-read/near/1680973>
        //   But that's in tension with the Figma, which gives these header rows
        //   40px min height.
        onTap: onCollapseButtonTap,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Padding(padding: const EdgeInsets.all(10),
            child: Icon(size: 20, color: designVariables.sectionCollapseIcon,
              collapsed ? ZulipIcons.arrow_right : ZulipIcons.arrow_down)),
          Icon(size: 18,
            color: collapsed
              ? collapsedIconColor(context)
              : uncollapsedIconColor(context),
            icon),
          const SizedBox(width: 5),
          Expanded(child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              style: TextStyle(
                fontSize: 17,
                height: (20 / 17),
                // TODO(design) check if this is the right variable
                color: designVariables.labelMenuButton,
              ).merge(weightVariableTextStyle(context, wght: 600)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              title(zulipLocalizations)))),
          const SizedBox(width: 12),
          if (hasMention) const _IconMarker(icon: ZulipIcons.at_sign),
          Padding(padding: const EdgeInsetsDirectional.only(end: 16),
            child: UnreadCountBadge(
              backgroundColor: unreadCountBadgeBackgroundColor(context),
              bold: true,
              count: count)),
        ])));
  }
}

class _AllDmsHeaderItem extends _HeaderItem {
  const _AllDmsHeaderItem({
    required super.collapsed,
    required super.pageState,
    required super.count,
    required super.hasMention,
    required super.sectionContext,
  });

  @override String title(ZulipLocalizations zulipLocalizations) =>
    zulipLocalizations.recentDmConversationsSectionHeader;
  @override IconData get icon => ZulipIcons.user;

  // TODO(design) check if this is the right variable for these
  @override Color collapsedIconColor(context) => DesignVariables.of(context).labelMenuButton;
  @override Color uncollapsedIconColor(context) => DesignVariables.of(context).labelMenuButton;

  @override Color uncollapsedBackgroundColor(context) => DesignVariables.of(context).dmHeaderBg;
  @override Color? unreadCountBadgeBackgroundColor(context) => null;

  @override Future<void> onCollapseButtonTap() async {
    await super.onCollapseButtonTap();
    pageState.allDmsCollapsed = !collapsed;
  }
  @override Future<void> onRowTap() => onCollapseButtonTap(); // TODO open all-DMs narrow?
}

class _AllDmsSection extends StatelessWidget {
  const _AllDmsSection({
    required this.data,
    required this.collapsed,
    required this.pageState,
  });

  final _AllDmsSectionData data;
  final bool collapsed;
  final _InboxPageState pageState;

  @override
  Widget build(BuildContext context) {
    final header = _AllDmsHeaderItem(
      count: data.count,
      hasMention: data.hasMention,
      collapsed: collapsed,
      pageState: pageState,
      sectionContext: context,
    );
    return StickyHeaderItem(
      header: header,
      child: Column(children: [
        header,
        if (!collapsed) ...data.items.map((item) {
          final (narrow, count, hasMention) = item;
          return _DmItem(
            narrow: narrow,
            count: count,
            hasMention: hasMention,
          );
        }),
      ]));
  }
}

class _DmItem extends StatelessWidget {
  const _DmItem({
    required this.narrow,
    required this.count,
    required this.hasMention,
  });

  final DmNarrow narrow;
  final int count;
  final bool hasMention;

  @override
  Widget build(BuildContext context) {
    final store = PerAccountStoreWidget.of(context);
    final selfUser = store.users[store.selfUserId]!;

    final zulipLocalizations = ZulipLocalizations.of(context);
    final designVariables = DesignVariables.of(context);

    final title = switch (narrow.otherRecipientIds) { // TODO dedupe with [RecentDmConversationsItem]
      [] => selfUser.fullName,
      [var otherUserId] =>
        store.users[otherUserId]?.fullName ?? zulipLocalizations.unknownUserName,

      // TODO(i18n): List formatting, like you can do in JavaScript:
      //   new Intl.ListFormat('ja').format(['Chris', 'Greg', 'Alya', 'Shu'])
      //   // 'Chris、Greg、Alya、Shu'
      _ => narrow.otherRecipientIds.map(
        (id) => store.users[id]?.fullName ?? zulipLocalizations.unknownUserName
      ).join(', '),
    };

    return Material(
      color: designVariables.background, // TODO(design) check if this is the right variable
      child: InkWell(
        onTap: () {
          Navigator.push(context,
            MessageListPage.buildRoute(context: context, narrow: narrow));
        },
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 34),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(width: 63),
            Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                style: TextStyle(
                  fontSize: 17,
                  height: (20 / 17),
                  // TODO(design) check if this is the right variable
                  color: designVariables.labelMenuButton,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                title))),
            const SizedBox(width: 12),
            if (hasMention) const  _IconMarker(icon: ZulipIcons.at_sign),
            Padding(padding: const EdgeInsetsDirectional.only(end: 16),
              child: UnreadCountBadge(backgroundColor: null,
                count: count)),
          ]))));
  }
}

class _StreamHeaderItem extends _HeaderItem {
  final Subscription subscription;

  const _StreamHeaderItem({
    required this.subscription,
    required super.collapsed,
    required super.pageState,
    required super.count,
    required super.hasMention,
    required super.sectionContext,
  });

  @override String title(ZulipLocalizations zulipLocalizations) =>
    subscription.name;
  @override IconData get icon => iconDataForStream(subscription);
  @override Color collapsedIconColor(context) =>
    colorSwatchFor(context, subscription).iconOnPlainBackground;
  @override Color uncollapsedIconColor(context) =>
    colorSwatchFor(context, subscription).iconOnBarBackground;
  @override Color uncollapsedBackgroundColor(context) =>
    colorSwatchFor(context, subscription).barBackground;
  @override Color? unreadCountBadgeBackgroundColor(context) =>
    colorSwatchFor(context, subscription).unreadCountBadgeBackground;

  @override Future<void> onCollapseButtonTap() async {
    await super.onCollapseButtonTap();
    if (collapsed) {
      pageState.uncollapseStream(subscription.streamId);
    } else {
      pageState.collapseStream(subscription.streamId);
    }
  }
  @override Future<void> onRowTap() => onCollapseButtonTap(); // TODO open channel narrow
}

class _StreamSection extends StatelessWidget {
  const _StreamSection({
    required this.data,
    required this.collapsed,
    required this.pageState,
  });

  final _StreamSectionData data;
  final bool collapsed;
  final _InboxPageState pageState;

  @override
  Widget build(BuildContext context) {
    final subscription = PerAccountStoreWidget.of(context).subscriptions[data.streamId]!;
    final header = _StreamHeaderItem(
      subscription: subscription,
      count: data.count,
      hasMention: data.hasMention,
      collapsed: collapsed,
      pageState: pageState,
      sectionContext: context,
    );
    return StickyHeaderItem(
      header: header,
      child: Column(children: [
        header,
        if (!collapsed) ...data.items.map((item) {
          return _TopicItem(streamId: data.streamId, data: item);
        }),
      ]));
  }
}

class _TopicItem extends StatelessWidget {
  const _TopicItem({required this.streamId, required this.data});

  final int streamId;
  final _StreamSectionTopicData data;

  @override
  Widget build(BuildContext context) {
    final _StreamSectionTopicData(
      :topic, :count, :hasMention, :lastUnreadId) = data;

    final store = PerAccountStoreWidget.of(context);
    final subscription = store.subscriptions[streamId]!;

    final designVariables = DesignVariables.of(context);
    final visibilityIcon = iconDataForTopicVisibilityPolicy(
      store.topicVisibilityPolicy(streamId, topic));

    return Material(
      color: designVariables.background, // TODO(design) check if this is the right variable
      child: InkWell(
        onTap: () {
          final narrow = TopicNarrow(streamId, topic);
          Navigator.push(context,
            MessageListPage.buildRoute(context: context, narrow: narrow));
        },
        onLongPress: () => showTopicActionSheet(context,
          channelId: streamId,
          topic: topic,
          someMessageIdInTopic: lastUnreadId),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 34),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(width: 63),
            Expanded(child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                style: TextStyle(
                  fontSize: 17,
                  height: (20 / 17),
                  // TODO(design) check if this is the right variable
                  color: designVariables.labelMenuButton,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                topic.displayName))),
            const SizedBox(width: 12),
            if (hasMention) const _IconMarker(icon: ZulipIcons.at_sign),
            // TODO(design) copies the "@" marker color; is there a better color?
            if (visibilityIcon != null) _IconMarker(icon: visibilityIcon),
            Padding(padding: const EdgeInsetsDirectional.only(end: 16),
              child: UnreadCountBadge(
                backgroundColor: colorSwatchFor(context, subscription),
                count: count)),
          ]))));
  }
}

class _IconMarker extends StatelessWidget {
  const _IconMarker({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final designVariables = DesignVariables.of(context);
    // Design for icon markers based on Figma screen:
    //   https://www.figma.com/file/1JTNtYo9memgW7vV6d0ygq/Zulip-Mobile?type=design&node-id=224-16386&mode=design&t=JsNndFQ8fKFH0SjS-0
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 4),
      // This color comes from the Figma screen for the "@" marker, but not
      // the topic visibility markers.
      child: Icon(icon, size: 14, color: designVariables.inboxItemIconMarker));
  }
}
