import 'package:material_ui/material_ui.dart';

class TabletLayout extends InheritedNotifier<ValueNotifier<bool>> {
  const TabletLayout({
    super.key,
    required ValueNotifier<bool> preference,
    required super.child,
  }) : super(notifier: preference);

  static bool activeOf(BuildContext context, {double minWidth = 600}) {
    if (context
            .dependOnInheritedWidgetOfExactType<TabletLayout>()
            ?.notifier
            ?.value !=
        true) {
      return false;
    }
    final size = MediaQuery.sizeOf(context);
    return size.width >= minWidth && size.height >= 480;
  }

  static Widget centered(
    BuildContext context, {
    required double maxWidth,
    required Widget child,
  }) => activeOf(context)
      ? Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: SizedBox(width: double.infinity, child: child),
          ),
        )
      : child;
}

class TabletNavigation extends StatelessWidget {
  const TabletNavigation({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.showDrama,
  });

  final int selected;
  final ValueChanged<int> onSelected;
  final bool showDrama;

  @override
  Widget build(BuildContext context) {
    const destinations = [
      (Icons.home_outlined, Icons.home, '首页'),
      (Icons.movie_outlined, Icons.movie, '短剧'),
      (Icons.local_library, Icons.local_library, '书架'),
      (Icons.person_outline, Icons.person, '我的'),
    ];
    final indexes = [0, if (showDrama) 1, 2, 3];
    return SafeArea(
      right: false,
      child: NavigationRail(
        key: const Key('tablet-navigation'),
        minWidth: 72,
        labelType: NavigationRailLabelType.all,
        scrollable: true,
        selectedIndex: indexes.indexOf(selected).clamp(0, indexes.length - 1),
        onDestinationSelected: (index) => onSelected(indexes[index]),
        destinations: [
          for (final index in indexes)
            NavigationRailDestination(
              icon: Icon(destinations[index].$1),
              selectedIcon: Icon(destinations[index].$2),
              label: Text(destinations[index].$3),
            ),
        ],
      ),
    );
  }
}
