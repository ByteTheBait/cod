import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks the active bottom-navigation tab index so any screen can switch
/// tabs programmatically (e.g. Calendar's "Go to Settings").
class TabIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void set(int index) => state = index;
}
