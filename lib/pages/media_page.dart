import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import '../models/camera_storage.dart';
import '../models/media_item.dart';
import '../models/media_sync_state.dart';
import '../state/app_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import '../widgets/media_image.dart';
import 'media_detail_page.dart';
import 'settings_pages.dart';

class MediaPage extends StatefulWidget {
  const MediaPage({
    super.key,
    required this.c,
    required this.onConnect,
    this.isLocal = false,
  });
  final AppController c;
  final VoidCallback onConnect;
  final bool isLocal;
  @override
  State<MediaPage> createState() => MediaPageState();
}

class MediaPageState extends State<MediaPage>
    with SingleTickerProviderStateMixin {
  bool selecting = false;
  final search = TextEditingController();
  bool _scrolling = false;
  Timer? _scrollIdle;
  void _hideSelectionBar() {
    _scrollIdle?.cancel();
    if (!_scrolling && mounted) setState(() => _scrolling = true);
    _scrollIdle = Timer(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _scrolling = false);
    });
  }

  final scroll = ScrollController();
  final _viewportKey = GlobalKey();
  List<MediaItem> _displayed = [];
  Set<String>? _dragBaseline;
  String? _dragAnchor;
  bool _dragSelect = true;
  Offset? _dragPosition;
  late final Ticker _dragTicker;
  Duration _lastDragFrame = Duration.zero;
  bool _dragHitPending = false;
  final Map<String, int> _displayIndex = {};
  int _lastDragEnd = -1;
  int? _pressedPointer;

  // The starting grid tile can be recycled while a finger stays down.
  // Track that pointer independently of the tile's gesture recognizer.
  void _trackPointer(PointerEvent event) {
    if (event.pointer != _pressedPointer) return;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _endDrag();
      _pressedPointer = null;
    } else if (event is PointerMoveEvent && _dragAnchor != null) {
      _moveDrag(event.position);
    }
  }

  void _startDrag(MediaItem item, LongPressStartDetails details) {
    if (c.isSyncPending(item) || _pressedPointer == null) return;
    _endDrag();
    HapticFeedback.lightImpact();
    final ids = widget.isLocal ? c.localSelection : c.selection;
    _dragBaseline = Set.of(ids);
    // Entering selection must always select the tile that opened it, even if
    // its checkbox had already been selected outside multi-select mode.
    _dragSelect = !selecting || !ids.contains(item.id);
    _dragAnchor = item.id;
    _dragPosition = details.globalPosition;
    setState(() {
      selecting = true;
      if (_dragSelect) {
        ids.add(item.id);
      } else {
        ids.remove(item.id);
      }
    });
    _lastDragEnd = _displayIndex[item.id] ?? -1;
    _lastDragFrame = Duration.zero;
    _dragTicker.start();
  }

  void _tickDrag(Duration elapsed) {
    final dt =
        (elapsed - _lastDragFrame).inMicroseconds /
        Duration.microsecondsPerSecond;
    _lastDragFrame = elapsed;
    if (!mounted || !scroll.hasClients || _dragPosition == null) return;
    final box = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final y = box.globalToLocal(_dragPosition!).dy;
    final direction = y < 56
        ? -1
        : y > box.size.height - 110
        ? 1
        : 0;
    if (direction != 0 && dt > 0) {
      final target = (scroll.offset + direction * 440 * dt.clamp(0, .05)).clamp(
        scroll.position.minScrollExtent,
        scroll.position.maxScrollExtent,
      );
      if (target != scroll.offset) {
        _hideSelectionBar();
        scroll.jumpTo(target);
      }
    }
    if (_dragHitPending) return;
    _dragHitPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dragHitPending = false;
      if (mounted && _dragPosition != null) _hitDrag(_dragPosition!);
    });
  }

  void _hitDrag(Offset position) {
    if (_dragAnchor == null) return;
    // Only laid-out tiles participate in hit testing; do not scan every loaded key.
    final result = HitTestResult();
    GestureBinding.instance.hitTestInView(
      result,
      position,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      if (entry.target case RenderMetaData(metaData: final String id)) {
        if (_displayIndex.containsKey(id)) {
          _applyDrag(id);
          return;
        }
      }
    }
  }

  void _moveDrag(Offset position) {
    _dragPosition = position;
    _hideSelectionBar();
    // Pointer events may arrive faster than display frames. One hit test per
    // frame is enough; the initial selection is applied immediately on long press.
  }

  void _applyDrag(String id) {
    final anchor = _displayIndex[_dragAnchor];
    final end = _displayIndex[id];
    if (anchor == null ||
        end == null ||
        _dragBaseline == null ||
        end == _lastDragEnd) {
      return;
    }
    final ids = widget.isLocal ? c.localSelection : c.selection;
    final previousEnd = _lastDragEnd < 0 ? anchor : _lastDragEnd;
    final from = end < previousEnd ? end : previousEnd;
    final to = end > previousEnd ? end : previousEnd;
    final rangeStart = anchor < end ? anchor : end;
    final rangeEnd = anchor > end ? anchor : end;
    var changed = false;
    for (var index = from; index <= to; index++) {
      final item = _displayed[index];
      final inRange = index >= rangeStart && index <= rangeEnd;
      final selected =
          !c.isSyncPending(item) &&
          (inRange ? _dragSelect : _dragBaseline!.contains(item.id));
      if (selected) {
        changed = ids.add(item.id) || changed;
      } else {
        changed = ids.remove(item.id) || changed;
      }
    }
    _lastDragEnd = end;
    // Keep drag updates local so the app's IndexedStack and hidden tabs do not rebuild.
    if (changed) setState(() {});
  }

  void _endDrag() {
    _dragTicker.stop();
    _lastDragEnd = -1;
    _dragAnchor = null;
    _dragBaseline = null;
    _dragPosition = null;
  }

  @override
  void initState() {
    super.initState();
    _dragTicker = createTicker(_tickDrag);
    scroll.addListener(loadNearEnd);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_trackPointer);
  }

  void loadNearEnd() {
    if (!widget.isLocal &&
        c.tab == 2 &&
        scroll.hasClients &&
        scroll.position.extentAfter < 500 &&
        c.hasMoreVisible &&
        !c.loadingMedia) {
      unawaited(c.refreshMedia(more: true));
    }
  }

  @override
  void deactivate() {
    _endDrag();
    _pressedPointer = null;
    super.deactivate();
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_trackPointer);
    _endDrag();
    _dragTicker.dispose();
    _scrollIdle?.cancel();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  AppController get c => widget.c;
  void toggleSelecting() {
    _endDrag();
    setState(() {
      selecting = !selecting;
      (widget.isLocal ? c.localSelection : c.selection).clear();
    });
  }

  Widget _selectionOverlay(Widget child) => IgnorePointer(
    ignoring: _scrolling,
    child: AnimatedSlide(
      duration: const Duration(milliseconds: 120),
      offset: _scrolling ? const Offset(0, .15) : Offset.zero,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _scrolling ? 0 : 1,
        child: child,
      ),
    ),
  );

  void detail(MediaItem m) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => MediaDetailPage(c: c, item: m, isLocal: widget.isLocal),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final local = widget.isLocal;
    if (!local && !c.connected) {
      return LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.photo_camera_outlined,
                    size: 44,
                    color: muted,
                  ),
                  gap(20),
                  heading('还没有连接相机', size: 20),
                  gap(10),
                  const Text(
                    '连接相机后，即可浏览和同步媒体。',
                    style: TextStyle(fontSize: 14),
                  ),
                  gap(10),
                  const Text(
                    '连接相机后会自动加载照片列表；若使用 STA，请在连接页输入相机屏幕显示的 IP。',
                    textAlign: TextAlign.center,
                  ),
                  gap(24),
                  Pill('连接相机', onPressed: widget.onConnect),
                  gap(16),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (local && c.completedCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.photo_library_outlined, size: 44, color: muted),
              gap(20),
              heading('暂无本地媒体', size: 20),
              gap(10),
              const Text(
                '在应用内手工导入、从相机同步或编辑导出的媒体会显示在这里。',
                textAlign: TextAlign.center,
              ),
              gap(16),
              Pill(
                '浏览相机照片',
                icon: Icons.photo_camera_outlined,
                onPressed: c.connected ? () => c.navigate(2) : widget.onConnect,
              ),
              if (c.nikon != null) ...[
                gap(10),
                Pill(
                  '从手机导入',
                  light: true,
                  onPressed: c.importingMedia ? null : () => c.importMedia(),
                ),
              ],
              gap(16),
            ],
          ),
        ),
      );
    }
    final items = local ? c.visibleLocal : c.visible;
    final ids = local ? c.localSelection : c.selection;
    if (!listEquals(_displayed, items)) {
      final extendsCurrent =
          items.length >= _displayed.length &&
          listEquals(_displayed, items.take(_displayed.length).toList());
      if (_dragAnchor != null && !extendsCurrent) _endDrag();
      _displayed = items;
      _displayIndex.clear();
      for (var i = 0; i < items.length; i++) {
        _displayIndex[items[i].id] = i;
      }
    }
    final selectable = items.where((m) => !c.isSyncPending(m)).toList();
    return Listener(
      onPointerDown: (event) => _pressedPointer ??= event.pointer,
      child: Column(
        children: [
          if (selecting)
            Row(
              children: [
                IconButton(
                  tooltip: '退出多选',
                  onPressed: toggleSelecting,
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    '已选择 ${ids.length} 个 · ${formatStorageBytes(items.where((m) => ids.contains(m.id)).fold<int>(0, (sum, m) => sum + m.bytes))}',
                  ),
                ),
                TextButton(
                  onPressed: () => c.selectAllLoaded(isLocal: local),
                  child: Text(
                    selectable.isNotEmpty &&
                            selectable.every((m) => ids.contains(m.id))
                        ? '取消全选'
                        : '全选',
                  ),
                ),
              ],
            ),
          if (MediaQuery.viewInsetsOf(context).bottom == 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Panel(
                padding: 16,
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: paleGreen,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        local
                            ? Icons.folder_outlined
                            : Icons.photo_camera_outlined,
                        color: brandGreen,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          heading(
                            local
                                ? '本地 ${c.completedCount} 个媒体文件'
                                : c.cameraModel,
                            size: 18,
                          ),
                          gap(6),
                          Text(
                            local
                                ? '照片 ${c.local.where((m) => m.referenceAvailable && m.kind == MediaKind.jpg).length} · 视频 ${c.local.where((m) => m.referenceAvailable && m.kind == MediaKind.video).length} · RAW ${c.local.where((m) => m.referenceAvailable && m.kind == MediaKind.raw).length}'
                                : '已连接 · ${c.connectionLabel}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => local
                          ? Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => ColorPage(c: c),
                              ),
                            )
                          : showCameraSettings(context, c),
                      icon: Icon(
                        local
                            ? Icons.palette_outlined
                            : Icons.settings_outlined,
                        size: 22,
                      ),
                      label: Text(
                        local ? '色彩管理' : '设置',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: search,
                    key: ValueKey(local ? 'local-search' : 'camera-search'),
                    onChanged: (value) =>
                        c.setMediaQuery(value, isLocal: local),
                    decoration: InputDecoration(
                      hintText: local ? '搜索本地文件名称' : '搜索已加载的相机照片',
                      prefixIcon: const Icon(Icons.search, size: 21),
                      isDense: true,
                      suffixIcon: search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                search.clear();
                                c.setMediaQuery('', isLocal: local);
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: '排序',
                  icon: const Icon(Icons.sort_rounded),
                  onSelected: (value) => c.setMediaSort(value, isLocal: local),
                  itemBuilder: (_) => ['默认', '最新拍摄', '最早拍摄', '文件名称', '文件大小']
                      .map(
                        (value) => CheckedPopupMenuItem(
                          value: value,
                          checked:
                              value == (local ? c.localSort : c.cameraSort),
                          child: Text(value),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          (local
                                  ? ['全部', '收藏', 'JPG', '视频', 'RAW']
                                  : ['全部', '未同步', '已同步', 'JPG', 'RAW', '视频'])
                              .map((s) {
                                final value = s == '照片' ? 'JPG' : s;
                                final active =
                                    (local ? c.localFilter : c.filter) == value;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: FilterChip(
                                    label: Text(
                                      s,
                                      style: TextStyle(
                                        color: active ? Colors.white : muted,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    selected: active,
                                    selectedColor: brandGreen,
                                    backgroundColor: const Color(0xffeef1f4),
                                    checkmarkColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    side: const BorderSide(
                                      color: Color(0xffe4e5e9),
                                    ),
                                    onSelected: (_) {
                                      if (local) {
                                        c.localFilter = value;
                                        c.localSelection.retainAll(
                                          c.visibleLocal.map((m) => m.id),
                                        );
                                        c.changed();
                                      } else {
                                        c.setFilter(value);
                                      }
                                    },
                                  ),
                                );
                              })
                              .toList(),
                    ),
                  ),
                ),
                if (!local) ...[
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: c.hasMediaFilter
                        ? '筛选已启用 · 选择存储卡或文件夹'
                        : '选择存储卡或文件夹',
                    style: IconButton.styleFrom(
                      backgroundColor: paleGreen,
                      foregroundColor: brandGreen,
                    ),
                    onPressed: () => showFolderPicker(context, c),
                    icon: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Icon(Icons.filter_alt_outlined, size: 23),
                        if (c.hasMediaFilter)
                          Positioned(
                            right: -3,
                            top: -3,
                            child: Semantics(
                              label: '当前已筛选',
                              child: Container(
                                key: const ValueKey('active-filter-dot'),
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: blue,
                                  boxShadow: [
                                    BoxShadow(
                                      color: blue.withValues(alpha: .65),
                                      blurRadius: 5,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    local
                        ? '${items.length} 个文件'
                        : '已加载 ${items.length} / ${c.visibleTotal ?? "统计中"} 个媒体',
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
                ),
                if (!local)
                  TextButton(
                    onPressed: selectable.isEmpty
                        ? null
                        : () => c.selectAllLoaded(),
                    child: Text(
                      selectable.isNotEmpty &&
                              selectable.every((m) => ids.contains(m.id))
                          ? '取消全选'
                          : '全选',
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              key: _viewportKey,
              children: [
                RefreshIndicator(
                  onRefresh: local ? c.refreshLocal : () => c.refreshMedia(),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.depth == 0 &&
                          (n is ScrollStartNotification ||
                              n is ScrollUpdateNotification ||
                              n is OverscrollNotification)) {
                        _hideSelectionBar();
                      }
                      loadNearEnd();
                      return false;
                    },
                    child: CustomScrollView(
                      controller: scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        if (items.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                c.loadingMedia || c.hasMoreVisible
                                    ? '正在查找符合条件的媒体…'
                                    : '没有符合条件的媒体，请调整筛选条件',
                              ),
                            ),
                          ),
                        if (local)
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            sliver: SliverToBoxAdapter(
                              child: heading('本地媒体', size: 20),
                            ),
                          ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          sliver: SliverGrid(
                            delegate: SliverChildBuilderDelegate((context, i) {
                              final item = items[i];
                              return MetaData(
                                metaData: item.id,
                                child: MediaTile(
                                  key: ValueKey(item.id),
                                  controller: c,
                                  item: item,
                                  selected: ids.contains(item.id),
                                  syncState: c.mediaSyncState(item),
                                  showSelection: !local || selecting,
                                  local: local,
                                  onTap: () => selecting
                                      ? c.toggle(item, isLocal: local)
                                      : detail(item),
                                  onSelect: () =>
                                      c.toggle(item, isLocal: local),
                                  onLongPressStart: (details) =>
                                      _startDrag(item, details),

                                  onLongPressEnd: (_) => _endDrag(),
                                ),
                              );
                            }, childCount: items.length),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount:
                                      (MediaQuery.sizeOf(context).width / 200)
                                          .floor()
                                          .clamp(2, 6),
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: local ? .82 : .76,
                                ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.only(
                              top: 16,
                              bottom: 130,
                            ),
                            child: Center(
                              child: c.loadingMedia
                                  ? const CircularProgressIndicator()
                                  : Text(
                                      !local && c.hasMoreVisible
                                          ? '继续上滑加载下一页 · 每页 20 张'
                                          : '已显示全部照片',
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!local)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 36,
                    child: _selectionOverlay(
                      Panel(
                        dark: true,
                        padding: 16,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '已选择 ${ids.length} 个媒体 · ${formatStorageBytes(items.where((m) => ids.contains(m.id)).fold<int>(0, (sum, m) => sum + m.bytes))}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '删除选中的相机文件',
                              onPressed: ids.isEmpty
                                  ? null
                                  : () => cameraDelete(context, c),
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.redAccent,
                              ),
                            ),
                            Expanded(
                              child: Pill(
                                '同步到手机',
                                light: true,
                                subdued: c.syncInProgress,
                                onPressed: c.syncInProgress
                                    ? () => showDialog<void>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('当前有同步任务进行中'),
                                          content: const Text(
                                            '请等待当前任务完成后，再同步新选中的照片。本次选择会为你保留。',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('知道了'),
                                            ),
                                          ],
                                        ),
                                      )
                                    : ids.isEmpty
                                    ? null
                                    : () => c.startSync(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (local && selecting)
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 12,
                    child: _selectionOverlay(
                      Row(
                        children: [
                          Expanded(
                            child: Pill(
                              '分享',
                              onPressed: ids.isEmpty
                                  ? null
                                  : () => c.shareItems(
                                      c.local.where((m) => ids.contains(m.id)),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Pill(
                              '删除',
                              destructive: true,
                              onPressed: ids.isEmpty
                                  ? null
                                  : () async {
                                      final deleting = Set<String>.of(ids);
                                      final deleteSource =
                                          await confirmLocalDeletion(
                                            context,
                                            deleting.length,
                                          );
                                      if (deleteSource != null) {
                                        await c.deleteLocal(
                                          deleting,
                                          deleteSource: deleteSource,
                                        );
                                        if (mounted) {
                                          setState(() => selecting = false);
                                        }
                                      }
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.item,
    this.controller,
    required this.selected,
    required this.syncState,
    required this.showSelection,
    required this.local,
    required this.onTap,
    required this.onSelect,
    this.onLongPress,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
  });
  final MediaItem item;
  final AppController? controller;
  final bool selected, showSelection, local;
  final MediaSyncState syncState;
  bool get synced => syncState == MediaSyncState.synced;
  bool get waiting => syncState == MediaSyncState.queued;
  final VoidCallback onTap, onSelect;
  final VoidCallback? onLongPress;
  bool get disabled => waiting || syncState == MediaSyncState.syncing;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressMoveUpdateCallback? onLongPressMoveUpdate;
  final GestureLongPressEndCallback? onLongPressEnd;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '${item.name} ${syncState.label}',
    enabled: !disabled,
    child: GestureDetector(
      onTap: disabled ? null : onTap,
      onLongPress: disabled ? null : onLongPress,
      onLongPressStart: disabled ? null : onLongPressStart,
      onLongPressMoveUpdate: disabled ? null : onLongPressMoveUpdate,
      onLongPressEnd: disabled ? null : onLongPressEnd,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xffe8ecf0)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _thumbnail(),
                  Positioned(left: 7, top: 7, child: _tag(item.label)),
                  if (local && !showSelection && controller != null)
                    Positioned(
                      right: 2,
                      top: 2,
                      child: IconButton.filledTonal(
                        tooltip: controller!.isFavorite(item) ? '取消收藏' : '收藏照片',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: .9),
                        ),
                        onPressed: () => controller!.toggleFavorite(item),
                        icon: Icon(
                          controller!.isFavorite(item)
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: brandGreen,
                          size: 20,
                        ),
                      ),
                    ),
                  if (!local)
                    Positioned(
                      left: 7,
                      bottom: 7,
                      child: _tag(
                        syncState.label,
                        dark: true,
                        textColor: synced
                            ? const Color(0xff86efac)
                            : syncState == MediaSyncState.failed
                            ? const Color(0xfffca5a5)
                            : null,
                      ),
                    ),
                  if (showSelection)
                    Positioned(
                      right: 1,
                      top: 1,
                      child: Semantics(
                        label: '选择 ${item.name}',
                        button: true,
                        enabled: !disabled,
                        child: GestureDetector(
                          key: ValueKey('media-select-${item.id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: disabled ? null : onSelect,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: disabled
                                    ? const Color(0xff9ca3af)
                                    : selected
                                    ? brandGreen
                                    : Colors.white.withValues(alpha: .92),
                                border: Border.all(
                                  color: selected ? Colors.white : muted,
                                  width: 1.2,
                                ),
                              ),
                              child: selected
                                  ? const Icon(
                                      Icons.check,
                                      size: 17,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${item.date.year}-${item.date.month.toString().padLeft(2, '0')}-${item.date.day.toString().padLeft(2, '0')} · ${item.size}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _thumbnail() {
    if (!disabled || controller == null) {
      return MediaImage(item: item, controller: controller, fit: BoxFit.cover);
    }
    return ListenableBuilder(
      listenable: controller!.transferProgress,
      builder: (context, _) {
        final progress = syncState == MediaSyncState.syncing && item.bytes > 0
            ? (controller!.task!.currentBytes / item.bytes).clamp(0.0, 1.0)
            : 0.0;
        return TweenAnimationBuilder<double>(
          tween: Tween(end: progress),
          duration: const Duration(milliseconds: 100),
          builder: (context, value, _) => Stack(
            fit: StackFit.expand,
            children: [
              ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Colors.grey,
                  BlendMode.saturation,
                ),
                child: Opacity(
                  opacity: .45,
                  child: MediaImage(item: item, controller: controller),
                ),
              ),
              ClipRect(
                clipper: SyncRevealClipper(value),
                child: MediaImage(item: item, controller: controller),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tag(String text, {bool dark = false, Color? textColor}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: dark
          ? muted.withValues(alpha: .85)
          : Colors.white.withValues(alpha: .25),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: textColor ?? (dark ? Colors.white : Colors.black),
      ),
    ),
  );
}

Future<void> cameraDelete(BuildContext context, AppController c) async {
  if (await confirm(context, '删除相机中的媒体', '将删除当前选择的相机文件，是否继续？') &&
      context.mounted) {
    await c.deleteCameraItems(
      c.visible.where((m) => c.selection.contains(m.id)).toList(),
    );
  }
}

class SyncRevealClipper extends CustomClipper<Rect> {
  const SyncRevealClipper(this.progress);
  final double progress;
  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width, size.height * progress.clamp(0.0, 1.0));
  @override
  bool shouldReclip(SyncRevealClipper oldClipper) =>
      progress != oldClipper.progress;
}
